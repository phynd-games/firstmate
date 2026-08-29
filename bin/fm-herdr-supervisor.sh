#!/usr/bin/env bash
# Herdr-native watcher continuity for a home whose primary harness cannot host one.
#
# WHY THIS EXISTS
# bin/fm-watch.sh is deliberately one-shot: one actionable reason closes one
# watcher cycle. bin/fm-watch-arm.sh starts or attaches to exactly one such
# cycle and returns that reason. Starting the NEXT cycle is a separate job -
# "continuity" - and every existing continuity owner is bound to the primary
# harness PROCESS: Pi's .pi/extensions/fm-primary-pi-watch.ts, Claude's Stop
# auto-arm, Cursor's stop-hook park, OpenCode's TUI plugin, Codex's foreground
# checkpoint (docs/watcher-continuity.md owns those contracts).
#
# A home whose primary harness never loaded its continuity owner therefore has
# NO owner at all. Each arm invocation then yields exactly one cycle and
# supervision ends silently. That is the 2026-08-29 incident: a Pi primary was
# launched with its project root set to the PARENT of the firstmate root, so Pi
# discovered no .pi/extensions/ there, neither primary extension loaded (proved
# by an absent state/.pi-watch-extension-loaded marker), and three hand-started
# arm cycles each delivered one wake and exited with successor=none.
#
# This script adds a continuity owner hosted in a HERDR-TRACKED PANE instead of
# in the harness process, so it survives every harness session transition
# (startup, new, resume, fork, compaction, reload, session idle) and every
# watcher-cycle close.
#
# WHAT IT IS NOT
# It is NOT a second lifecycle authority. It starts nothing but
# bin/fm-watch-arm.sh; the arm layer remains the only thing that starts,
# attaches to, or verifies a watcher, and state/.watch.lock remains the only
# singleton. It never touches the durable wake queue except through the shared
# fm_wake_append escalation path, never acknowledges a wake, never merges,
# tears down, promotes, steers a task, or invokes no-mistakes. It stands down
# whenever a harness-native or away-mode owner is provable, so a home never
# runs two continuity owners.
#
# It uses the plain attach-or-start arm, never `--restart`. A second supervisor
# that somehow raced past the establish lock therefore ATTACHES to the live
# watcher instead of evicting it, so the one-watcher singleton holds even under
# a duplicate arm.
#
# HONESTY
# Health is never inferred from a beacon alone. fm_herdr_supervisor_healthy is
# true only when the durable record, this home, the named Herdr session and its
# canonical socket, the exact workspace/tab/pane, the pane's tracked foreground
# pid, that pid's fm_pid_identity (so a recycled pid cannot pass), and a fresh
# supervisor heartbeat ALL agree. Anything unreadable, ambiguous, or unknown is
# unhealthy, never healthy.
#
# Every failed or ambiguous establish and every exhausted retry writes a durable
# actionable diagnostic to state/.herdr-supervisor-alarm AND appends one
# `check: herdr-supervisor` record to the durable wake queue, so the lapse
# reaches the captain through the channels that already exist rather than a new
# one.
#
# SUPPORTED GUARANTEES AND EXTERNAL PREREQUISITES
# docs/herdr-supervisor.md is the single owner of that list. In short: this
# recovers from watcher exit, arm crash or kill, stale or dead watcher lock,
# stale or missing watcher beacon, primary harness session replacement, and a
# duplicate arm - all inside one live Herdr server. It CANNOT recover across a
# dead Herdr server or host, because its own host pane dies with them; that gap
# is reported, never papered over.
#
# SUBCOMMANDS
#   ensure   idempotently establish or confirm this home's supervisor
#   status   read-only health and ownership report (no mutation)
#   run      the supervision loop; only ever executed inside the Herdr pane
#   retire   stand down and release this home's supervisor
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

RECORD="$STATE/.herdr-supervisor"
# The loop publishes its own process identity to a SEPARATE file. Two writers
# and one file would need one lock, and `ensure` must hold that lock across the
# whole establish - including the wait for the loop to come up - so the loop
# could never take it. Splitting the records removes the inversion instead of
# timing around it: `ensure` and `retire` own the binding record, the loop owns
# the live record, and both are stamped with the same generation so a stale
# pairing can never be read as healthy.
LIVE="$STATE/.herdr-supervisor-live"
LAUNCHER="$STATE/.herdr-supervisor-launch.sh"
RECORD_LOCK="$STATE/.herdr-supervisor.lock"
HEARTBEAT="$STATE/.herdr-supervisor-heartbeat"
ALARM="$STATE/.herdr-supervisor-alarm"
LEDGER="$STATE/.herdr-supervisor.log"
# FM_WATCH_ARM_SCRIPT is the same seam the Pi extension already uses to name the
# arm it launches; honoring it here keeps one spelling for "which arm script"
# and gives the deterministic tests a real arm to drive without a live watcher.
ARM="${FM_WATCH_ARM_SCRIPT:-$SCRIPT_DIR/fm-watch-arm.sh}"

RECORD_VERSION=1
# The supervisor's own beacon is independent of state/.last-watcher-beat: only
# the watcher writes that one, and no helper may make a wedged watcher look
# healthy. This beacon answers a different question - is the CONTINUITY OWNER
# alive - and its grace is deliberately tighter than the watcher's 300s because
# the loop refreshes it on every pass.
HEARTBEAT_GRACE=${FM_HERDR_SUPERVISOR_HEARTBEAT_GRACE:-120}
READY_TIMEOUT=${FM_HERDR_SUPERVISOR_READY_TIMEOUT:-20}
RETRY_LIMIT=${FM_HERDR_SUPERVISOR_RETRY_LIMIT:-5}
RETRY_BASE=${FM_HERDR_SUPERVISOR_RETRY_BASE:-2}
RETRY_MAX=${FM_HERDR_SUPERVISOR_RETRY_MAX:-60}
IDLE_INTERVAL=${FM_HERDR_SUPERVISOR_IDLE_INTERVAL:-30}
# A cycle that closes faster than this is "rapid"; a long consecutive run of
# them is thrash, not progress. The response is a floor delay plus one durable
# diagnostic, never stopping supervision - a genuinely busy fleet does produce
# fast cycles, and going blind would be worse than running warm.
RAPID_CYCLE_SECONDS=${FM_HERDR_SUPERVISOR_RAPID_CYCLE_SECONDS:-1}
RAPID_CYCLE_LIMIT=${FM_HERDR_SUPERVISOR_RAPID_CYCLE_LIMIT:-20}
RAPID_CYCLE_FLOOR=${FM_HERDR_SUPERVISOR_RAPID_CYCLE_FLOOR:-5}
# Every Herdr call this script makes is hard-bounded. `ensure` runs inside a
# command substitution on the session-start path, so an adapter call that never
# returns would wedge bootstrap itself - a strictly worse failure than the
# supervision lapse this exists to fix. fm_run_timed kills the whole process
# group, so a hung vendor CLI cannot outlive the bound either.
HERDR_CALL_TIMEOUT=${FM_HERDR_SUPERVISOR_HERDR_TIMEOUT:-15}
LEDGER_MAX_BYTES=${FM_HERDR_SUPERVISOR_LEDGER_MAX_BYTES:-262144}
LEDGER_KEEP_LINES=${FM_HERDR_SUPERVISOR_LEDGER_KEEP_LINES:-1000}

for _fm_hs_int in HEARTBEAT_GRACE READY_TIMEOUT RETRY_LIMIT RETRY_BASE RETRY_MAX \
  IDLE_INTERVAL RAPID_CYCLE_SECONDS RAPID_CYCLE_LIMIT RAPID_CYCLE_FLOOR \
  HERDR_CALL_TIMEOUT LEDGER_MAX_BYTES LEDGER_KEEP_LINES; do
  case "${!_fm_hs_int}" in
    ''|*[!0-9]*) fail_msg="error: $_fm_hs_int must be a non-negative integer" ;;
    *) continue ;;
  esac
  echo "$fail_msg" >&2
  exit 2
done
unset _fm_hs_int

usage() {
  cat <<'EOF'
Usage: fm-herdr-supervisor.sh <command> [options]

Commands:
  ensure [--reason <text>]   Establish or confirm this home's Herdr-hosted watcher
                             continuity owner. Idempotent and safe to repeat.
  status [--verbose]         Print a read-only ownership and health report.
  retire [--reason <text>]   Stand down this home's supervisor and release its pane.
  run --generation <gen>     The supervision loop. Only ever launched inside the
                             Herdr pane by `ensure`; never run it by hand.

Exit codes:
  0  established, already healthy, deliberately deferred, or a clean retire
  1  failed or ambiguous - a durable diagnostic was written and escalated
  2  usage error
EOF
}

# --- durable ledger (observability; fail-open) --------------------------------
# A logging failure must never stall supervision, so every write here is
# best-effort and bounded. This ledger is diagnostic evidence only; it is never
# read as authority for any decision.

ledger_clean_field() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-512
}

ledger_append() {  # <event> <detail>
  local event=$1 detail=$2 size tmp i=0
  while ! fm_lock_try_acquire "$LEDGER.lock"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" \
    "$(ledger_clean_field "$(record_get generation)")" \
    "$(ledger_clean_field "$event")" \
    "$(ledger_clean_field "${BASHPID:-$$}")" \
    "$(ledger_clean_field "$detail")" >> "$LEDGER" 2>/dev/null || true
  size=$(wc -c < "$LEDGER" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$LEDGER_MAX_BYTES" ]; then
        tmp="$LEDGER.tmp.${BASHPID:-$$}"
        tail -n "$LEDGER_KEEP_LINES" "$LEDGER" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$LEDGER" 2>/dev/null
        rm -f "$tmp" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$LEDGER.lock"
}

# --- durable record -----------------------------------------------------------

record_get() {  # <key>
  local key=$1 line
  [ -f "$RECORD" ] || return 1
  line=$(grep -m1 "^$key=" "$RECORD" 2>/dev/null) || return 1
  printf '%s' "${line#*=}"
}

live_get() {  # <key>
  local key=$1 line
  [ -f "$LIVE" ] || return 1
  line=$(grep -m1 "^$key=" "$LIVE" 2>/dev/null) || return 1
  printf '%s' "${line#*=}"
}

# record_put writes the whole record atomically from the caller's staged
# key=value lines on stdin. Partial in-place edits are deliberately impossible:
# a half-updated ownership record is exactly the ambiguity this must never
# publish.
record_put() {
  local tmp
  tmp="$RECORD.tmp.${BASHPID:-$$}"
  cat > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$RECORD" || { rm -f "$tmp" 2>/dev/null; return 1; }
}

record_clear() {
  rm -f "$RECORD" "$LIVE" 2>/dev/null || true
}

launcher_clear() {
  rm -f "$LAUNCHER" 2>/dev/null || true
}

mint_generation() {
  local rand
  rand=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d '[:space:]') || rand=
  [ -n "$rand" ] || rand=$$
  printf '%s.%s' "$(date +%s)" "$rand"
}

# --- durable alarm and escalation ---------------------------------------------

alarm_write() {  # <reason>
  local reason=$1
  {
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'home=%s\n' "$FM_HOME"
    printf 'generation=%s\n' "$(record_get generation || printf none)"
    printf 'reason=%s\n' "$(ledger_clean_field "$reason")"
  } > "$ALARM.tmp.${BASHPID:-$$}" 2>/dev/null || return 0
  mv -f "$ALARM.tmp.${BASHPID:-$$}" "$ALARM" 2>/dev/null || true
}

alarm_clear() {
  rm -f "$ALARM" 2>/dev/null || true
}

# escalate: one durable diagnostic plus one durable wake, using the queue that
# already exists. It never prompts a harness session this process does not own.
escalate() {  # <reason>
  local reason=$1
  alarm_write "$reason"
  ledger_append escalated "$reason"
  fm_wake_append check herdr-supervisor \
    "check: herdr-supervisor - $reason" 2>/dev/null || true
}

# --- Herdr identity -----------------------------------------------------------
# bin/backends/herdr.sh is sourced lazily: `status` on a non-herdr home must not
# pay for it, and a home with no herdr binary must still get a clean report.

BACKEND_LOADED=0
backend_load() {
  [ "$BACKEND_LOADED" -eq 0 ] || return 0
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  BACKEND_LOADED=1
}

HERDR_LOADED=0
herdr_load() {
  [ "$HERDR_LOADED" -eq 0 ] || return 0
  backend_load || return 1
  fm_backend_source herdr >/dev/null 2>&1 || return 1
  HERDR_LOADED=1
}

# hs_herdr: one bounded Herdr call, session-scoped exactly the way
# fm_backend_herdr_cli scopes one (HERDR_SESSION plus a trailing --session), but
# invoked as a real executable so the bound can apply. Never used for anything
# that starts or stops a server.
hs_herdr() {  # <session> <herdr-args...>
  local session=$1
  shift
  fm_run_timed "$HERDR_CALL_TIMEOUT" \
    env "HERDR_SESSION=$session" herdr "$@" --session "$session"
}

# herdr_identity: resolve the named session and its canonical socket, and prove
# they are the same ALREADY-RUNNING server this process can address. Sets
# HS_SESSION and HS_SOCKET. Any ambiguity fails - a supervisor bound to an
# unidentifiable server could never be verified again.
#
# This deliberately never STARTS a server. Two reasons, one safety and one
# honesty. Starting one means backgrounding a long-lived process from inside the
# caller's command substitution, which is exactly what wedged the first version
# of the live smoke; `ensure` runs inside such a substitution on the session-start
# path, so that hazard belongs nowhere near bootstrap. And a home whose Herdr
# server is down has already lost the host this supervisor would live in - a dead
# server is the one boundary this design states it cannot recover across, so the
# right move is a loud, actionable refusal rather than an attempt that can hang.
HS_SESSION=
HS_SOCKET=
herdr_identity() {
  local protocol status sessions
  HS_SESSION=
  HS_SOCKET=
  herdr_load || { echo "herdr backend adapter could not be loaded" >&2; return 1; }
  command -v herdr >/dev/null 2>&1 || { echo "the herdr CLI is not installed" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "jq is not installed and the herdr adapter requires it" >&2; return 1; }
  HS_SESSION=$(fm_backend_herdr_session)
  [ -n "$HS_SESSION" ] || { echo "herdr session identity is empty" >&2; return 1; }

  status=$(hs_herdr "$HS_SESSION" status --json 2>/dev/null) || status=
  [ -n "$status" ] || {
    echo "could not read herdr status for session '$HS_SESSION' within ${HERDR_CALL_TIMEOUT}s" >&2
    return 1
  }
  protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "could not read the herdr client protocol; refusing to use an unverified herdr build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "herdr protocol $protocol is older than the verified minimum $FM_BACKEND_HERDR_MIN_PROTOCOL" >&2
    return 1
  fi
  if [ "$(printf '%s' "$status" | jq -r '.server.running // false' 2>/dev/null)" != true ]; then
    echo "herdr session '$HS_SESSION' has no running server, so there is no pane to host watcher continuity in; start it and rerun" >&2
    return 1
  fi

  sessions=$(hs_herdr "$HS_SESSION" session list --json 2>/dev/null) || sessions=
  [ -n "$sessions" ] || {
    echo "could not list herdr sessions to resolve the socket for '$HS_SESSION' within ${HERDR_CALL_TIMEOUT}s" >&2
    return 1
  }
  HS_SOCKET=$(printf '%s' "$sessions" | jq -er --arg want "$HS_SESSION" '
    [.sessions[]?
      | select(.name == $want and .running == true)
      | select((.socket_path | type) == "string")
      | select((.socket_path | length) > 0)
      | .socket_path]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null) || HS_SOCKET=
  [ -n "$HS_SOCKET" ] || {
    echo "herdr session '$HS_SESSION' has no unambiguous running socket identity" >&2
    return 1
  }
  HS_SOCKET=$(fm_backend_herdr_canonical_socket_path "$HS_SOCKET") || {
    echo "herdr session '$HS_SESSION' reports an unusable socket path" >&2
    return 1
  }
  return 0
}

# pane_tracked_pid: the pid Herdr itself tracks as the pane's foreground
# process. Read from Herdr, never guessed from a process table scan, so the
# answer is bound to the exact pane rather than to a command-line pattern that
# would also match a sibling home.
pane_tracked_pid() {  # <session> <pane>
  local session=$1 pane=$2 info pid
  info=$(hs_herdr "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  pid=$(printf '%s' "$info" | jq -r --arg p "$pane" '
    select(.result.process_info.pane_id == $p)
    | .result.process_info.shell_pid // empty
  ' 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$pid"
}

# pane_binding_intact: the recorded workspace/tab/pane triple must still agree
# with Herdr's own view. An unreadable or contradictory answer is unknown, and
# unknown is never treated as present.
pane_binding_intact() {  # <session> <workspace> <tab> <pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 out
  out=$(hs_herdr "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e \
    --arg pane "$pane" --arg tab "$tab" --arg ws "$workspace" '
      .result.pane.pane_id == $pane
      and .result.pane.tab_id == $tab
      and .result.pane.workspace_id == $ws
    ' >/dev/null 2>&1
}

# --- health -------------------------------------------------------------------

HS_UNHEALTHY_REASON=
supervisor_healthy() {
  local session socket workspace tab pane loop_pid loop_identity current age
  HS_UNHEALTHY_REASON=

  [ -f "$RECORD" ] || { HS_UNHEALTHY_REASON="no supervisor record"; return 1; }
  [ "$(record_get version || printf '')" = "$RECORD_VERSION" ] \
    || { HS_UNHEALTHY_REASON="supervisor record version is not $RECORD_VERSION"; return 1; }
  [ "$(record_get fm_home || printf '')" = "$FM_HOME" ] \
    || { HS_UNHEALTHY_REASON="supervisor record belongs to another home"; return 1; }
  [ -f "$LIVE" ] \
    || { HS_UNHEALTHY_REASON="supervisor record is not live"; return 1; }
  [ "$(live_get generation || printf '')" = "$(record_get generation || printf '')" ] \
    || { HS_UNHEALTHY_REASON="the live supervisor belongs to a superseded generation"; return 1; }

  age=$(fm_path_age "$HEARTBEAT")
  [ "$age" -lt "$HEARTBEAT_GRACE" ] \
    || { HS_UNHEALTHY_REASON="supervisor heartbeat is ${age}s old (grace ${HEARTBEAT_GRACE}s)"; return 1; }

  loop_pid=$(live_get loop_pid || printf '')
  loop_identity=$(live_get loop_identity || printf '')
  fm_pid_alive "$loop_pid" \
    || { HS_UNHEALTHY_REASON="recorded supervisor process $loop_pid is gone"; return 1; }
  [ -n "$loop_identity" ] \
    || { HS_UNHEALTHY_REASON="supervisor record carries no process identity"; return 1; }
  current=$(fm_pid_identity "$loop_pid" 2>/dev/null || printf '')
  [ "$current" = "$loop_identity" ] \
    || { HS_UNHEALTHY_REASON="pid $loop_pid was recycled and is not this supervisor"; return 1; }

  # Only now is the Herdr side worth the round trips: a dead process already
  # settles it, and every check below costs a socket call.
  session=$(record_get herdr_session || printf '')
  socket=$(record_get herdr_socket || printf '')
  workspace=$(record_get workspace || printf '')
  tab=$(record_get tab || printf '')
  pane=$(record_get pane || printf '')
  [ -n "$session" ] && [ -n "$socket" ] && [ -n "$workspace" ] && [ -n "$tab" ] && [ -n "$pane" ] \
    || { HS_UNHEALTHY_REASON="supervisor record has an incomplete Herdr binding"; return 1; }

  herdr_identity >/dev/null 2>&1 \
    || { HS_UNHEALTHY_REASON="this home's Herdr session identity is unavailable"; return 1; }
  [ "$HS_SESSION" = "$session" ] \
    || { HS_UNHEALTHY_REASON="Herdr session changed from '$session' to '$HS_SESSION'"; return 1; }
  [ "$HS_SOCKET" = "$socket" ] \
    || { HS_UNHEALTHY_REASON="Herdr server socket changed; the recorded server is gone"; return 1; }

  pane_binding_intact "$session" "$workspace" "$tab" "$pane" \
    || { HS_UNHEALTHY_REASON="Herdr pane $pane no longer matches its recorded tab and workspace"; return 1; }

  current=$(pane_tracked_pid "$session" "$pane" 2>/dev/null || printf '')
  [ "$current" = "$loop_pid" ] \
    || { HS_UNHEALTHY_REASON="Herdr pane $pane tracks pid '${current:-unknown}', not supervisor $loop_pid"; return 1; }

  return 0
}

# --- eligibility --------------------------------------------------------------
# The one rule that keeps a home from ever running two continuity owners.

hs_config_preference() {
  local file="$CONFIG/herdr-supervisor" value
  [ -f "$file" ] || { printf auto; return 0; }
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$value" in
    ''|auto) printf auto ;;
    on) printf on ;;
    off) printf off ;;
    *) printf auto ;;
  esac
}

# harness_owner_provable: true when some OTHER continuity owner provably holds
# this home right now. Only positive, durable evidence counts; the absence of
# evidence is never read as the presence of an owner.
harness_owner_provable() {
  HS_DEFER_REASON=
  if [ -e "$STATE/.afk" ]; then
    HS_DEFER_REASON="away mode is active and its daemon owns supervision"
    return 0
  fi
  if fm_pi_extension_owns_supervision "$STATE" "$FM_ROOT" 2>/dev/null; then
    HS_DEFER_REASON="the Pi primary extension owns watcher continuity"
    return 0
  fi
  return 1
}

HS_DEFER_REASON=
HS_INELIGIBLE_REASON=
supervisor_eligible() {
  local preference model backend
  HS_INELIGIBLE_REASON=
  preference=$(hs_config_preference)
  if [ "$preference" = off ]; then
    HS_INELIGIBLE_REASON="config/herdr-supervisor is off"
    return 1
  fi

  backend_load || {
    HS_INELIGIBLE_REASON="the runtime-backend library is unavailable"
    return 1
  }
  backend=$(fm_backend_name 2>/dev/null || printf '')
  if [ "$backend" != herdr ]; then
    HS_INELIGIBLE_REASON="this home's runtime backend is '${backend:-unknown}', not herdr"
    return 1
  fi
  herdr_load || {
    HS_INELIGIBLE_REASON="the herdr backend adapter is unavailable"
    return 1
  }

  if [ "$preference" = auto ]; then
    # Default scope is exactly the failure this was built for: a harness whose
    # continuity owner lives in a project-local extension that may silently not
    # be loaded. Any other harness needs a deliberate `on`, because its owner's
    # presence is not provable from durable state and guessing would risk the
    # duplicate owner this whole design avoids.
    model=$(fm_supervision_model 2>/dev/null || printf persistent)
    if [ "$model" != extension ]; then
      HS_INELIGIBLE_REASON="supervision model '$model' owns continuity in the harness; set config/herdr-supervisor to 'on' to host it in Herdr anyway"
      return 1
    fi
  fi
  return 0
}

# --- establish ----------------------------------------------------------------

# rollback_workspace closes ONLY the exact workspace this establish just
# created, identified by the id its own create response returned. It never
# resolves a workspace by label and never touches a parent, sibling, task, or
# captain pane.
rollback_workspace() {  # <session> <workspace>
  local session=$1 workspace=$2
  [ -n "$workspace" ] || return 0
  hs_herdr "$session" workspace close "$workspace" >/dev/null 2>&1 || true
  ledger_append rollback "closed workspace $workspace after a failed establish"
}

supervisor_label() {
  printf '%s-supervisor' "$(fm_backend_herdr_workspace_label)"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

establish() {  # <reason>
  local reason=$1 generation out workspace tab pane cmd deadline pid detail

  herdr_identity || {
    detail="Herdr identity could not be established: $(herdr_identity 2>&1 >/dev/null | head -1)"
    escalate "$detail"
    echo "herdr-supervisor: FAILED - $detail" >&2
    return 1
  }

  generation=$(mint_generation)
  # The pending record is published BEFORE anything is created, so a crash
  # between create and verify leaves evidence naming the generation that was in
  # flight rather than a silent orphan.
  {
    printf 'version=%s\n' "$RECORD_VERSION"
    printf 'generation=%s\n' "$generation"
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'fm_root=%s\n' "$FM_ROOT"
    printf 'herdr_session=%s\n' "$HS_SESSION"
    printf 'herdr_socket=%s\n' "$HS_SOCKET"
    printf 'established_at=%s\n' "$(date +%s)"
    printf 'establish_reason=%s\n' "$(ledger_clean_field "$reason")"
  } | record_put || {
    escalate "the supervisor record could not be written under $STATE"
    echo "herdr-supervisor: FAILED - the supervisor record could not be written" >&2
    return 1
  }
  ledger_append establish-begin "$reason"

  out=$(hs_herdr "$HS_SESSION" workspace create \
    --cwd "$FM_ROOT" --label "$(supervisor_label)" --no-focus 2>/dev/null) || out=
  workspace=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$workspace" ] || [ -z "$tab" ] || [ -z "$pane" ]; then
    # An incomplete response grants no cleanup authority, matching the
    # presentation path's rule that an ambiguous response authorizes no
    # mutation. A partially identified workspace is therefore left alone rather
    # than closed on a guess - but the alarm names it, so an orphan is a thing
    # someone can go and look at instead of a silent leak.
    record_clear
    detail="Herdr returned an incomplete workspace-create response (workspace='${workspace:-none}' tab='${tab:-none}' pane='${pane:-none}'), so no supervisor pane could be created"
    if [ -n "$workspace" ]; then
      detail="$detail; workspace $workspace may exist and was deliberately NOT closed because the response was too ambiguous to prove it is ours - inspect and remove it by hand if it is an orphan"
    fi
    escalate "$detail"
    echo "herdr-supervisor: FAILED - Herdr returned an incomplete workspace-create response" >&2
    return 1
  fi

  {
    printf 'version=%s\n' "$RECORD_VERSION"
    printf 'generation=%s\n' "$generation"
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'fm_root=%s\n' "$FM_ROOT"
    printf 'herdr_session=%s\n' "$HS_SESSION"
    printf 'herdr_socket=%s\n' "$HS_SOCKET"
    printf 'workspace=%s\n' "$workspace"
    printf 'tab=%s\n' "$tab"
    printf 'pane=%s\n' "$pane"
    printf 'established_at=%s\n' "$(date +%s)"
    printf 'establish_reason=%s\n' "$(ledger_clean_field "$reason")"
  } | record_put || {
    rollback_workspace "$HS_SESSION" "$workspace"
    record_clear
    escalate "the supervisor record could not be updated after its Herdr pane was created"
    echo "herdr-supervisor: FAILED - the supervisor record could not be updated" >&2
    return 1
  }

  # `exec` so the pane's tracked foreground process IS the loop: Herdr's own
  # process-info then answers "is the supervisor alive" directly, and the pane
  # dies with the loop instead of lingering as a bare shell that would look
  # like a healthy host.
  # `herdr pane run` types the command into the pane's shell, so it is subject to
  # that terminal's line-length limit - a limit a long FM_HOME easily exceeds. A
  # truncated command line is the worst kind of failure here: the CLI reports
  # success, the pane silently runs a mangled command, and the only symptom is a
  # loop that never confirms. So the command stays SHORT and constant, and
  # everything it needs goes into a launcher script instead.
  #
  # The pane shell's environment comes from Herdr rather than from this process,
  # so the launcher must carry every value the loop needs explicitly, including
  # the tuning this home resolved - otherwise the loop would silently run on
  # defaults while `ensure` used the configured values.
  if ! {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by bin/fm-herdr-supervisor.sh for generation %s.\n' "$generation"
    printf '# Rewritten on every establish and removed on retire; never edit by hand.\n'
    printf 'export FM_HOME=%s\n' "$(shell_quote "$FM_HOME")"
    printf 'export FM_ROOT_OVERRIDE=%s\n' "$(shell_quote "$FM_ROOT")"
    printf 'export FM_STATE_OVERRIDE=%s\n' "$(shell_quote "$STATE")"
    printf 'export FM_CONFIG_OVERRIDE=%s\n' "$(shell_quote "$CONFIG")"
    printf 'export FM_WATCH_ARM_SCRIPT=%s\n' "$(shell_quote "$ARM")"
    printf 'export FM_HERDR_SUPERVISOR_HEARTBEAT_GRACE=%s\n' "$HEARTBEAT_GRACE"
    printf 'export FM_HERDR_SUPERVISOR_RETRY_LIMIT=%s\n' "$RETRY_LIMIT"
    printf 'export FM_HERDR_SUPERVISOR_RETRY_BASE=%s\n' "$RETRY_BASE"
    printf 'export FM_HERDR_SUPERVISOR_RETRY_MAX=%s\n' "$RETRY_MAX"
    printf 'export FM_HERDR_SUPERVISOR_IDLE_INTERVAL=%s\n' "$IDLE_INTERVAL"
    printf 'export FM_HERDR_SUPERVISOR_RAPID_CYCLE_SECONDS=%s\n' "$RAPID_CYCLE_SECONDS"
    printf 'export FM_HERDR_SUPERVISOR_RAPID_CYCLE_LIMIT=%s\n' "$RAPID_CYCLE_LIMIT"
    printf 'export FM_HERDR_SUPERVISOR_RAPID_CYCLE_FLOOR=%s\n' "$RAPID_CYCLE_FLOOR"
    printf 'export FM_HERDR_SUPERVISOR_HERDR_TIMEOUT=%s\n' "$HERDR_CALL_TIMEOUT"
    printf 'export FM_HERDR_SUPERVISOR_LEDGER_MAX_BYTES=%s\n' "$LEDGER_MAX_BYTES"
    printf 'export FM_HERDR_SUPERVISOR_LEDGER_KEEP_LINES=%s\n' "$LEDGER_KEEP_LINES"
    printf 'exec bash %s run --generation %s\n' \
      "$(shell_quote "$SCRIPT_DIR/fm-herdr-supervisor.sh")" "$(shell_quote "$generation")"
  } > "$LAUNCHER" 2>/dev/null || ! chmod 700 "$LAUNCHER" 2>/dev/null; then
    rollback_workspace "$HS_SESSION" "$workspace"
    record_clear
    escalate "the supervisor launcher script could not be written to $LAUNCHER"
    echo "herdr-supervisor: FAILED - the supervisor launcher script could not be written" >&2
    return 1
  fi
  cmd="exec bash $(shell_quote "$LAUNCHER")"
  if ! hs_herdr "$HS_SESSION" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    rollback_workspace "$HS_SESSION" "$workspace"
    record_clear
    escalate "the supervisor loop could not be started in Herdr pane $pane"
    echo "herdr-supervisor: FAILED - the supervisor loop could not be started in pane $pane" >&2
    return 1
  fi

  deadline=$(( $(date +%s) + READY_TIMEOUT + 1 ))
  while :; do
    if [ "$(record_get generation || printf '')" = "$generation" ] && supervisor_healthy; then
      alarm_clear
      ledger_append established "generation=$generation pane=$pane workspace=$workspace"
      pid=$(live_get loop_pid || printf '')
      echo "herdr-supervisor: started generation=$generation pane=$pane pid=$pid"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 0.5
  done

  detail="the supervisor loop did not confirm within ${READY_TIMEOUT}s (${HS_UNHEALTHY_REASON:-no reason recorded})"
  rollback_workspace "$HS_SESSION" "$workspace"
  record_clear
  escalate "$detail"
  echo "herdr-supervisor: FAILED - $detail" >&2
  return 1
}

# --- commands -----------------------------------------------------------------

cmd_ensure() {  # <reason>
  local reason=$1 rc
  if ! supervisor_eligible; then
    echo "herdr-supervisor: not eligible - $HS_INELIGIBLE_REASON"
    return 0
  fi
  if harness_owner_provable; then
    # A live foreign owner means this home already has continuity. Retiring any
    # supervisor we still hold is the point: two owners is the failure mode.
    if [ -f "$RECORD" ]; then
      cmd_retire "deferring to $HS_DEFER_REASON" >/dev/null 2>&1 || true
    fi
    echo "herdr-supervisor: deferred - $HS_DEFER_REASON"
    return 0
  fi
  if ! fm_supervision_needed "$STATE"; then
    echo "herdr-supervisor: not needed - this home has no in-flight work, event source, or relay poll"
    return 0
  fi

  fm_lock_acquire_wait "$RECORD_LOCK"
  if supervisor_healthy; then
    fm_lock_release "$RECORD_LOCK"
    alarm_clear
    echo "herdr-supervisor: unchanged generation=$(record_get generation) pane=$(record_get pane) pid=$(live_get loop_pid)"
    return 0
  fi
  ledger_append establish-required "${HS_UNHEALTHY_REASON:-unknown}"
  establish "$reason (${HS_UNHEALTHY_REASON:-no prior record})"
  rc=$?
  fm_lock_release "$RECORD_LOCK"
  return "$rc"
}

cmd_retire() {  # <reason>
  local reason=$1 session workspace pane loop_pid loop_identity current
  fm_lock_acquire_wait "$RECORD_LOCK"
  if [ ! -f "$RECORD" ]; then
    fm_lock_release "$RECORD_LOCK"
    echo "herdr-supervisor: nothing to retire"
    return 0
  fi
  session=$(record_get herdr_session || printf '')
  workspace=$(record_get workspace || printf '')
  pane=$(record_get pane || printf '')
  loop_pid=$(live_get loop_pid || printf '')
  loop_identity=$(live_get loop_identity || printf '')

  # Clearing the record first is what actually retires the generation: the loop
  # re-reads it every pass and exits when its own generation is gone, so this
  # never has to signal a process whose identity it cannot prove.
  record_clear
  ledger_append retired "$reason"

  if [ -n "$loop_pid" ] && [ -n "$loop_identity" ] && fm_pid_alive "$loop_pid"; then
    current=$(fm_pid_identity "$loop_pid" 2>/dev/null || printf '')
    if [ "$current" = "$loop_identity" ]; then
      kill -TERM "$loop_pid" 2>/dev/null || true
    fi
  fi
  if [ -n "$session" ] && [ -n "$workspace" ] && [ -n "$pane" ]; then
    herdr_load >/dev/null 2>&1 \
      && hs_herdr "$session" workspace close "$workspace" >/dev/null 2>&1 || true
  fi
  rm -f "$HEARTBEAT" 2>/dev/null || true
  launcher_clear
  fm_lock_release "$RECORD_LOCK"
  echo "herdr-supervisor: retired - $reason"
  return 0
}

cmd_status() {  # <verbose>
  local verbose=$1 preference
  preference=$(hs_config_preference)
  printf 'home: %s\n' "$FM_HOME"
  printf 'preference: %s\n' "$preference"
  if supervisor_eligible; then
    printf 'eligible: yes\n'
  else
    printf 'eligible: no (%s)\n' "$HS_INELIGIBLE_REASON"
  fi
  if harness_owner_provable; then
    printf 'other-owner: yes (%s)\n' "$HS_DEFER_REASON"
  else
    printf 'other-owner: no\n'
  fi
  if fm_supervision_needed "$STATE"; then
    printf 'supervision-needed: yes\n'
  else
    printf 'supervision-needed: no\n'
  fi
  if supervisor_healthy; then
    printf 'supervisor: healthy generation=%s pane=%s pid=%s\n' \
      "$(record_get generation)" "$(record_get pane)" "$(live_get loop_pid)"
  else
    printf 'supervisor: unhealthy (%s)\n' "$HS_UNHEALTHY_REASON"
  fi
  if [ -f "$ALARM" ]; then
    printf 'alarm: pending\n'
    sed 's/^/  /' "$ALARM"
  else
    printf 'alarm: none\n'
  fi
  if [ "$verbose" = 1 ] && [ -f "$LEDGER" ]; then
    printf 'recent:\n'
    tail -n 20 "$LEDGER" | sed 's/^/  /'
  fi
  return 0
}

# --- the loop -----------------------------------------------------------------

LOOP_GENERATION=
loop_owns_generation() {
  [ "$(record_get generation 2>/dev/null || printf '')" = "$LOOP_GENERATION" ]
}

# Retract this loop's own liveness claim on the way out. Only ever removes a
# live record this generation published, so a successor that already replaced it
# is never disturbed.
loop_release_live() {
  [ "$(live_get generation 2>/dev/null || printf '')" = "$LOOP_GENERATION" ] || return 0
  rm -f "$LIVE" 2>/dev/null || true
}

# loop_publish_live writes ONLY the live record, so it never contends with the
# establish lock the caller is still holding while it waits for this.
loop_publish_live() {  # <pane-pid>
  local pid=$1 identity tmp
  identity=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
  [ -n "$identity" ] || return 1
  loop_owns_generation || return 1
  tmp="$LIVE.tmp.$pid"
  {
    printf 'generation=%s\n' "$LOOP_GENERATION"
    printf 'loop_pid=%s\n' "$pid"
    printf 'loop_identity=%s\n' "$identity"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$LIVE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  # The binding may have been retired or superseded between the check above and
  # the publish; drop the live record rather than leave one claiming a dead
  # generation.
  if ! loop_owns_generation; then
    rm -f "$LIVE" 2>/dev/null || true
    return 1
  fi
  return 0
}

backoff_delay() {  # <attempt>
  local attempt=$1 delay=$RETRY_BASE i=1
  while [ "$i" -lt "$attempt" ]; do
    delay=$((delay * 2))
    [ "$delay" -lt "$RETRY_MAX" ] || { delay=$RETRY_MAX; break; }
    i=$((i + 1))
  done
  printf '%s' "$delay"
}

arm_output_reason() {  # <file>
  grep -m1 -E '^(signal:|stale:|check:|heartbeat($|:))' "$1" 2>/dev/null || true
}

cmd_run() {
  local self out rc reason failures=0 rapid=0 started ended elapsed delay
  local LOOP_ARM_OUT

  self=${BASHPID:-$$}
  if ! loop_owns_generation; then
    # A superseded or retired generation must never arm. This is the duplicate
    # arm guard: only the generation the record names may run.
    echo "herdr-supervisor: generation $LOOP_GENERATION is not current; standing down" >&2
    exit 0
  fi
  if ! loop_publish_live "$self"; then
    escalate "the supervisor loop could not publish its own process identity for generation $LOOP_GENERATION"
    echo "herdr-supervisor: FAILED - could not publish supervisor identity" >&2
    exit 1
  fi
  : > "$HEARTBEAT" 2>/dev/null || true
  ledger_append loop-start "pid=$self"

  # A retire, a supersession, or an operator closing the pane must end this
  # cleanly rather than leaving a record claiming a process that is going away.
  LOOP_ARM_OUT=
  trap 'ledger_append loop-signal "terminated"; [ -z "$LOOP_ARM_OUT" ] || rm -f "$LOOP_ARM_OUT"; loop_release_live; exit 0' HUP TERM INT

  while :; do
    if ! loop_owns_generation; then
      ledger_append loop-exit "generation superseded or retired"
      loop_release_live
      exit 0
    fi
    if harness_owner_provable; then
      ledger_append loop-exit "stood down: $HS_DEFER_REASON"
      loop_release_live
      exit 0
    fi

    : > "$HEARTBEAT" 2>/dev/null || true

    if ! fm_supervision_needed "$STATE"; then
      # Idle, not finished: work can arrive at any time and re-establishing on
      # every quiet stretch would only add failure modes.
      sleep "$IDLE_INTERVAL"
      continue
    fi

    out=$(mktemp "$STATE/.herdr-supervisor-arm.XXXXXX") || {
      escalate "the supervisor loop could not create a temporary file under $STATE"
      exit 1
    }
    LOOP_ARM_OUT=$out
    started=$(date +%s)
    # Plain attach-or-start, never --restart: a watcher that is already healthy
    # must be followed, not evicted, so the singleton survives a duplicate arm.
    "$ARM" >"$out" 2>&1
    rc=$?
    ended=$(date +%s)
    elapsed=$((ended - started))
    reason=$(arm_output_reason "$out")

    if [ "$rc" -eq 0 ] && [ -n "$reason" ]; then
      # The watcher already appended this wake to the durable queue before it
      # exited, so nothing is lost by re-arming immediately; delivery to the
      # model is the drain's job, not this loop's.
      failures=0
      ledger_append cycle "rc=0 elapsed=${elapsed}s $(ledger_clean_field "$reason")"
      alarm_clear
      rm -f "$out" 2>/dev/null || true
      LOOP_ARM_OUT=
      if [ "$elapsed" -le "$RAPID_CYCLE_SECONDS" ]; then
        rapid=$((rapid + 1))
        if [ "$rapid" -ge "$RAPID_CYCLE_LIMIT" ]; then
          escalate "watcher cycles have been closing within ${RAPID_CYCLE_SECONDS}s for $rapid consecutive cycles; supervision continues on a ${RAPID_CYCLE_FLOOR}s floor while this is investigated"
          rapid=0
          sleep "$RAPID_CYCLE_FLOOR"
        fi
      else
        rapid=0
      fi
      continue
    fi

    rapid=0
    failures=$((failures + 1))
    ledger_append cycle-failed "rc=$rc elapsed=${elapsed}s attempt=$failures $(ledger_clean_field "$(head -c 400 "$out" 2>/dev/null | tr '\n' ' ')")"
    rm -f "$out" 2>/dev/null || true
    LOOP_ARM_OUT=

    if [ "$failures" -gt "$RETRY_LIMIT" ]; then
      escalate "the watcher arm failed $RETRY_LIMIT consecutive times in Herdr pane $(record_get pane || printf unknown); supervision is DOWN for $FM_HOME and needs a captain decision"
      ledger_append loop-exit "retry bound exhausted"
      loop_release_live
      exit 1
    fi
    delay=$(backoff_delay "$failures")
    sleep "$delay"
  done
}

# --- argument parsing ---------------------------------------------------------

COMMAND=${1:-}
[ "$#" -eq 0 ] || shift
REASON="requested"
VERBOSE=0
GENERATION=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason)
      [ "$#" -gt 1 ] || { echo "error: --reason requires a value" >&2; exit 2; }
      REASON=$2
      shift 2
      ;;
    --generation)
      [ "$#" -gt 1 ] || { echo "error: --generation requires a value" >&2; exit 2; }
      GENERATION=$2
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$COMMAND" in
  ensure) cmd_ensure "$REASON" ;;
  status) cmd_status "$VERBOSE" ;;
  retire) cmd_retire "$REASON" ;;
  run)
    case "$GENERATION" in
      ''|*[!A-Za-z0-9._-]*) echo "error: run requires a valid --generation" >&2; exit 2 ;;
    esac
    LOOP_GENERATION=$GENERATION
    herdr_load >/dev/null 2>&1 || true
    cmd_run
    ;;
  ''|-h|--help) usage; [ -n "$COMMAND" ] ;;
  *) echo "error: unknown command: $COMMAND" >&2; usage >&2; exit 2 ;;
esac
