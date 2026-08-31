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
# tears down, promotes, steers a task, or invokes no-mistakes. It becomes a
# standby whenever a harness-native or away-mode owner is provable, so only one
# active owner can arm a watcher.
#
# It always uses the plain attach-or-start arm. The arm layer owns stale-lock
# self-eviction and stealing, so a duplicate supervisor cannot evict a live
# watcher and the one-watcher singleton holds under duplication.
#
# HONESTY
# Health is never inferred from a beacon alone. fm_herdr_supervisor_healthy is
# true only when the durable record, this home, the named Herdr session and its
# canonical socket, the exact workspace/tab/pane, the pane's tracked foreground
# pid, that pid's fm_pid_identity (so a recycled pid cannot pass), and a fresh
# supervisor heartbeat ALL agree. Anything unreadable, ambiguous, or unknown is
# unhealthy, never healthy.
#
# Every failed or ambiguous establish and every failed arm attempt writes a durable
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
LIVE_LOCK="$STATE/.herdr-supervisor-live.lock"
LAUNCHER="$STATE/.herdr-supervisor-launch.sh"
PENDING="$STATE/.herdr-supervisor-pending-cleanup"
AWAY_AMBIGUOUS="$STATE/.herdr-away-daemon-ambiguous"
HANDOFF_AMBIGUOUS="$STATE/.herdr-supervision-handoff-ambiguous"
QUARANTINE_PREFIX="$STATE/.herdr-supervisor-quarantine"
RECORD_LOCK="$STATE/.herdr-supervisor.lock"
HEARTBEAT="$STATE/.herdr-supervisor-heartbeat"
ALARM="$STATE/.herdr-supervisor-alarm"
ALARM_HISTORY="$STATE/.herdr-supervisor-alarm-history"
RAPID_EPISODE="$STATE/.herdr-supervisor-rapid-episode"
EMERGENCY="$STATE/.herdr-supervisor-emergency"
BLOCKED="$STATE/.herdr-supervisor-blocked"
LEDGER="$STATE/.herdr-supervisor.log"
SUPERVISION_CLAIM="$STATE/.supervision-claim.lock"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"

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
UNKNOWN_ARM_TIMEOUT=${FM_HERDR_SUPERVISOR_UNKNOWN_ARM_TIMEOUT:-20}
UNKNOWN_ARM_RETRY_LIMIT=${FM_HERDR_SUPERVISOR_UNKNOWN_ARM_RETRY_LIMIT:-3}
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
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
SUPERVISOR_LOCK_TRIES=${FM_HERDR_SUPERVISOR_LOCK_TRIES:-100}
WATCH_QUEUE_LOCK_TRIES=${FM_WATCH_ARM_WAKE_QUEUE_LOCK_TRIES:-100}
LEDGER_MAX_BYTES=${FM_HERDR_SUPERVISOR_LEDGER_MAX_BYTES:-262144}
LEDGER_KEEP_LINES=${FM_HERDR_SUPERVISOR_LEDGER_KEEP_LINES:-1000}
case "$WATCHER_STALE_GRACE" in
  ''|*[!0-9]*) WATCHER_STALE_GRACE=300 ;;
esac
case "$WATCH_QUEUE_LOCK_TRIES" in
  ''|*[!0-9]*|0) WATCH_QUEUE_LOCK_TRIES=100 ;;
esac
case "$HERDR_CALL_TIMEOUT" in
  ''|*[!0-9]*|0)
    echo "error: HERDR_CALL_TIMEOUT must be a positive integer" >&2
    exit 2
    ;;
esac

for _fm_hs_int in HEARTBEAT_GRACE READY_TIMEOUT RETRY_LIMIT RETRY_BASE RETRY_MAX \
  IDLE_INTERVAL RAPID_CYCLE_SECONDS RAPID_CYCLE_LIMIT RAPID_CYCLE_FLOOR \
  UNKNOWN_ARM_TIMEOUT SUPERVISOR_LOCK_TRIES LEDGER_MAX_BYTES LEDGER_KEEP_LINES; do
  case "${!_fm_hs_int}" in
    ''|*[!0-9]*) fail_msg="error: $_fm_hs_int must be a non-negative integer" ;;
    *) continue ;;
  esac
  echo "$fail_msg" >&2
  exit 2
done
unset _fm_hs_int
case "$UNKNOWN_ARM_RETRY_LIMIT" in
  ''|*[!0-9]*|0) UNKNOWN_ARM_RETRY_LIMIT=3 ;;
esac

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
  rm -f "$LIVE" 2>/dev/null || return 1
  rm -f "$RECORD" 2>/dev/null || return 1
  [ ! -e "$RECORD" ] && [ ! -e "$LIVE" ]
}

record_set_cleanup_state() {  # <state>
  local cleanup_state=$1 tmp
  [ -f "$RECORD" ] || return 1
  tmp="$RECORD.cleanup.${BASHPID:-$$}"
  awk '!/^cleanup_state=/' "$RECORD" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  printf 'cleanup_state=%s\n' "$cleanup_state" >> "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$RECORD" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
}

record_set_mode() {  # <mode>
  local mode=$1 tmp
  [ -f "$RECORD" ] || return 1
  tmp="$RECORD.mode.${BASHPID:-$$}"
  awk '!/^mode=/' "$RECORD" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  printf 'mode=%s\n' "$mode" >> "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$RECORD" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
}

launcher_clear() {
  rm -f "$LAUNCHER" 2>/dev/null || true
}

supervisor_lock_acquire() {
  local lock=$1 attempt=0
  while ! fm_lock_try_acquire "$lock"; do
    [ "$attempt" -lt "$SUPERVISOR_LOCK_TRIES" ] || return 1
    sleep 0.02
    attempt=$((attempt + 1))
  done
}

pending_get() {  # <key>
  local key=$1 line
  [ -f "$PENDING" ] || return 1
  line=$(grep -m1 "^$key=" "$PENDING" 2>/dev/null) || return 1
  printf '%s' "${line#*=}"
}

pending_put() {  # <generation> <session> <socket> <workspace> <tab> <pane> [socket-identity]
  local generation=$1 session=$2 socket=$3 workspace=$4 tab=$5 pane=$6 socket_identity=${7:-${HS_SOCKET_IDENTITY:-}} tmp
  tmp="$PENDING.tmp.${BASHPID:-$$}"
  if ! {
    printf 'generation=%s\n' "$generation"
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'fm_root=%s\n' "$FM_ROOT"
    printf 'herdr_session=%s\n' "$session"
    printf 'herdr_socket=%s\n' "$socket"
    printf 'herdr_socket_identity=%s\n' "$socket_identity"
    printf 'workspace=%s\n' "$workspace"
    printf 'tab=%s\n' "$tab"
    printf 'pane=%s\n' "$pane"
    printf 'cleanup_state=open\n'
  } > "$tmp" 2>/dev/null || ! chmod 600 "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$PENDING" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

pending_record_create_ids() {  # <workspace> <tab> <pane>
  local workspace=$1 tab=$2 pane=$3 tmp
  [ -f "$PENDING" ] || return 1
  tmp="$PENDING.create-response.${BASHPID:-$$}"
  if ! awk '!/^(workspace|tab|pane|create_state)=/' "$PENDING" > "$tmp" 2>/dev/null \
    || ! {
      printf 'workspace=%s\n' "$workspace"
      printf 'tab=%s\n' "$tab"
      printf 'pane=%s\n' "$pane"
      printf 'create_state=creating\n'
    } >> "$tmp" 2>/dev/null \
    || ! chmod 600 "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$PENDING" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

pending_begin_create() {  # <generation> <session> <socket> <socket-identity> <label> <cwd>
  local generation=$1 session=$2 socket=$3 socket_identity=$4 label=$5 cwd=$6 tmp
  tmp="$PENDING.tmp.${BASHPID:-$$}"
  if ! {
    printf 'generation=%s\n' "$generation"
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'fm_root=%s\n' "$FM_ROOT"
    printf 'herdr_session=%s\n' "$session"
    printf 'herdr_socket=%s\n' "$socket"
    printf 'herdr_socket_identity=%s\n' "$socket_identity"
    printf 'create_label=%s\n' "$label"
    printf 'create_cwd=%s\n' "$cwd"
    printf 'create_state=creating\n'
    printf 'cleanup_state=open\n'
  } > "$tmp" 2>/dev/null || ! chmod 600 "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$PENDING" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

pending_set_cleanup_state() {  # <state>
  local cleanup_state=$1 tmp
  [ -f "$PENDING" ] || return 1
  tmp="$PENDING.cleanup.${BASHPID:-$$}"
  awk '!/^cleanup_state=/' "$PENDING" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  printf 'cleanup_state=%s\n' "$cleanup_state" >> "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$PENDING" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
}

pending_clear() {
  rm -f "$PENDING" 2>/dev/null || return 1
  [ ! -e "$PENDING" ]
}

pending_quarantine() {
  local reason=$1 generation target tmp
  generation=$(pending_get generation || printf unknown)
  case "$generation" in
    ''|*[!A-Za-z0-9._-]*) generation=unknown-${BASHPID:-$$} ;;
  esac
  target="$QUARANTINE_PREFIX.pending.$generation"
  [ ! -e "$target" ] || target="$target.$(date +%s).${BASHPID:-$$}"
  tmp="$target.tmp.${BASHPID:-$$}"
  if ! {
    awk '!/^mode=/' "$PENDING"
    printf 'mode=quarantine\n'
    printf 'quarantine_reason=%s\n' "$(ledger_clean_field "$reason")"
  } > "$tmp" 2>/dev/null || ! chmod 600 "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  rm -f "$PENDING" 2>/dev/null || return 1
  [ ! -e "$PENDING" ]
}

pending_restore_record() {
  local state=${1:-quarantine} generation session socket socket_identity workspace tab pane
  generation=$(pending_get generation || printf unknown)
  session=$(pending_get herdr_session || printf '')
  socket=$(pending_get herdr_socket || printf '')
  socket_identity=$(pending_get herdr_socket_identity || printf '')
  workspace=$(pending_get workspace || printf '')
  tab=$(pending_get tab || printf '')
  pane=$(pending_get pane || printf '')
  {
    printf 'version=%s\n' "$RECORD_VERSION"
    printf 'generation=%s\n' "$generation"
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'fm_root=%s\n' "$FM_ROOT"
    printf 'herdr_session=%s\n' "$session"
    printf 'herdr_socket=%s\n' "$socket"
    printf 'herdr_socket_identity=%s\n' "$socket_identity"
    printf 'workspace=%s\n' "$workspace"
    printf 'tab=%s\n' "$tab"
    printf 'pane=%s\n' "$pane"
    printf 'mode=%s\n' "$state"
    printf 'cleanup_state=%s\n' "$(pending_get cleanup_state || printf open)"
    printf 'established_at=%s\n' "$(date +%s)"
    printf 'establish_reason=pending-cleanup\n'
  } | record_put
}

mint_generation() {
  local rand
  rand=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d '[:space:]') || rand=
  [ -n "$rand" ] || rand=$$
  printf '%s.%s' "$(date +%s)" "$rand"
}

# --- durable alarm and escalation ---------------------------------------------

alarm_write() {  # <reason>
  local reason=$1 tmp="$ALARM.tmp.${BASHPID:-$$}"
  {
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'home=%s\n' "$FM_HOME"
    printf 'generation=%s\n' "$(record_get generation || printf none)"
    printf 'reason=%s\n' "$(ledger_clean_field "$reason")"
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  mv -f "$tmp" "$ALARM" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  cat "$ALARM" >> "$ALARM_HISTORY" 2>/dev/null || return 1
  [ -f "$ALARM" ] && [ -f "$ALARM_HISTORY" ]
}

alarm_clear() {
  rm -f "$ALARM" "$RAPID_EPISODE" 2>/dev/null || return 1
  [ ! -e "$ALARM" ] && [ ! -e "$RAPID_EPISODE" ]
}

rapid_alarm_write() {  # <reason>
  local reason=$1 marker_tmp emergency_status=0
  [ -e "$RAPID_EPISODE" ] || {
    [ -e "$ALARM" ] || alarm_write "$reason" || emergency_status=1
    marker_tmp="$RAPID_EPISODE.tmp.${BASHPID:-$$}"
    if ! printf '%s\n' "$(ledger_clean_field "$reason")" > "$marker_tmp" 2>/dev/null \
      || ! mv -f "$marker_tmp" "$RAPID_EPISODE" 2>/dev/null; then
      rm -f "$marker_tmp" 2>/dev/null || true
      emergency_status=1
    fi
    ledger_append rapid-alarm "$reason"
  }
  if [ "$emergency_status" -ne 0 ]; then
    {
      printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'home=%s\n' "$FM_HOME"
      printf 'reason=%s\n' "$(ledger_clean_field "$reason")"
      printf 'rapid_alarm_persistence=failed\n'
    } >> "$EMERGENCY" 2>/dev/null || true
    printf 'herdr-supervisor: RAPID ALARM PERSISTENCE FAILED - %s\n' "$reason" >&2
    return 1
  fi
  return 0
}

# escalate: one durable diagnostic plus one durable wake, using the queue that
# already exists. It never prompts a harness session this process does not own.
escalate() {  # <reason>
  local reason=$1 status=0 alarm_status=0 queue_status=0
  alarm_write "$reason" || { alarm_status=1; status=1; }
  ledger_append escalated "$reason"
  FM_WAKE_APPEND_LOCK_TRIES=100 FM_RECOVERY_MARKER_LOCK_TRIES=100 fm_wake_append check herdr-supervisor \
    "check: herdr-supervisor - $reason" 2>/dev/null \
    || { queue_status=1; status=1; }
  if [ "$status" -ne 0 ]; then
    {
      printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'home=%s\n' "$FM_HOME"
      printf 'alarm_persistence=%s\n' "$alarm_status"
      printf 'queue_persistence=%s\n' "$queue_status"
      printf 'reason=%s\n' "$(ledger_clean_field "$reason")"
    } >> "$EMERGENCY" 2>/dev/null || true
    printf 'herdr-supervisor: ESCALATION PERSISTENCE FAILED - %s\n' "$reason" >&2
  fi
  return "$status"
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

herdr_workspace_control() {  # <socket> <socket-identity> <list|close> [workspace]
  local socket=$1 socket_identity=$2 operation=$3 helper
  shift 3
  helper=${FM_HERDR_WORKSPACE_CONTROL_HELPER:-$FM_ROOT/bin/backends/herdr-workspace-control.py}
  [ -x "$helper" ] || return 1
  "$helper" "$socket" "$socket_identity" "$operation" "$@"
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
HS_SOCKET_IDENTITY=
herdr_socket_identity() {
  local socket=$1
  case "$(uname -s 2>/dev/null || printf unknown)" in
    Darwin|FreeBSD|NetBSD|OpenBSD) stat -f '%d:%i' "$socket" 2>/dev/null ;;
    *) stat -c '%d:%i' "$socket" 2>/dev/null ;;
  esac
}
herdr_identity() {
  local protocol status sessions
  HS_SESSION=
  HS_SOCKET=
  HS_SOCKET_IDENTITY=
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
  HS_SOCKET_IDENTITY=$(herdr_socket_identity "$HS_SOCKET") || {
    echo "herdr session '$HS_SESSION' socket identity is unavailable" >&2
    return 1
  }
  [ -n "$HS_SOCKET_IDENTITY" ] || {
    echo "herdr session '$HS_SESSION' socket identity is empty" >&2
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
  local session socket socket_identity workspace tab pane loop_pid loop_identity current age mode
  HS_UNHEALTHY_REASON=

  [ -f "$RECORD" ] || { HS_UNHEALTHY_REASON="no supervisor record"; return 1; }
  [ "$(record_get version || printf '')" = "$RECORD_VERSION" ] \
    || { HS_UNHEALTHY_REASON="supervisor record version is not $RECORD_VERSION"; return 1; }
  mode=$(record_get mode || printf '')
  [ "$mode" = active ] \
    || { HS_UNHEALTHY_REASON="supervisor binding is in $mode quarantine"; return 1; }
  [ "$(record_get fm_home || printf '')" = "$FM_HOME" ] \
    || { HS_UNHEALTHY_REASON="supervisor record belongs to another home"; return 1; }
  [ -f "$LIVE" ] \
    || { HS_UNHEALTHY_REASON="supervisor record is not live"; return 1; }
  [ ! -f "$BLOCKED" ] \
    || { HS_UNHEALTHY_REASON="supervisor is blocked on an unresolved arm child"; return 1; }
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
  socket_identity=$(record_get herdr_socket_identity || printf '')
  workspace=$(record_get workspace || printf '')
  tab=$(record_get tab || printf '')
  pane=$(record_get pane || printf '')
  [ -n "$session" ] && [ -n "$socket" ] && [ -n "$socket_identity" ] \
    && [ -n "$workspace" ] && [ -n "$tab" ] && [ -n "$pane" ] \
    || { HS_UNHEALTHY_REASON="supervisor record has an incomplete Herdr binding"; return 1; }

  herdr_identity >/dev/null 2>&1 \
    || { HS_UNHEALTHY_REASON="this home's Herdr session identity is unavailable"; return 1; }
  [ "$HS_SESSION" = "$session" ] \
    || { HS_UNHEALTHY_REASON="Herdr session changed from '$session' to '$HS_SESSION'"; return 1; }
  [ "$HS_SOCKET" = "$socket" ] \
    || { HS_UNHEALTHY_REASON="Herdr server socket changed; the recorded server is gone"; return 1; }
  [ "$HS_SOCKET_IDENTITY" = "$socket_identity" ] \
    || { HS_UNHEALTHY_REASON="Herdr server socket identity changed; the recorded server is gone"; return 1; }

  pane_binding_intact "$session" "$workspace" "$tab" "$pane" \
    || { HS_UNHEALTHY_REASON="Herdr pane $pane no longer matches its recorded tab and workspace"; return 1; }

  current=$(pane_tracked_pid "$session" "$pane" 2>/dev/null || printf '')
  [ "$current" = "$loop_pid" ] \
    || { HS_UNHEALTHY_REASON="Herdr pane $pane tracks pid '${current:-unknown}', not supervisor $loop_pid"; return 1; }

  current=$(fm_pid_identity "$loop_pid" 2>/dev/null || printf '')
  [ "$current" = "$loop_identity" ] \
    || { HS_UNHEALTHY_REASON="supervisor pid $loop_pid identity changed during health check"; return 1; }

  herdr_identity >/dev/null 2>&1 \
    || { HS_UNHEALTHY_REASON="this home's Herdr session identity changed during health check"; return 1; }
  [ "$HS_SESSION" = "$session" ] && [ "$HS_SOCKET" = "$socket" ] \
    && [ "$HS_SOCKET_IDENTITY" = "$socket_identity" ] \
    || { HS_UNHEALTHY_REASON="Herdr server identity changed during health check"; return 1; }

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
  local read_only=${1:-0} away_state away_pid away_owner away_recorded away_current away_key
  HS_DEFER_REASON=
  if fm_supervision_claim_held_by_other "$SUPERVISION_CLAIM"; then
    HS_DEFER_REASON="another continuity owner is completing its ownership claim"
    return 0
  fi
  if fm_supervision_claim_pending "$STATE"; then
    HS_DEFER_REASON="a native away-mode owner is completing its ownership handoff"
    return 0
  fi
  if fm_supervision_claim_pending_expired_live "$STATE"; then
    HS_DEFER_REASON="a native away-mode handoff reservation expired while its owner remains live"
    if [ "$read_only" = 0 ]; then
      local handoff_key
      handoff_key=$(fm_supervision_claim_pending_key "$STATE" 2>/dev/null || printf unknown)
      if [ "$(cat "$HANDOFF_AMBIGUOUS" 2>/dev/null || printf '')" != "$handoff_key" ]; then
        printf '%s\n' "$handoff_key" > "$HANDOFF_AMBIGUOUS" 2>/dev/null || true
        escalate "the native away-mode handoff reservation expired while its launcher remains live; refusing a second continuity owner"
      fi
    fi
    return 0
  fi
  if [ -e "$STATE/.afk" ]; then
    away_state=$(
      # Runtime source path is intentionally unavailable to static analysis.
      # shellcheck disable=SC1091
      . "$SCRIPT_DIR/fm-afk-start.sh" >/dev/null 2>&1
      daemon_lock_state
    )
    case "$away_state" in
      live)
        [ "$read_only" = 1 ] || rm -f "$AWAY_AMBIGUOUS" 2>/dev/null || true
        HS_DEFER_REASON="away mode is active and its daemon owns supervision"
        return 0
        ;;
      ambiguous)
        away_owner=$(
          # Runtime source path is intentionally unavailable to static analysis.
          # shellcheck disable=SC1091
          . "$SCRIPT_DIR/fm-afk-start.sh" >/dev/null 2>&1
          daemon_lock_owner 2>/dev/null || true
        )
        away_pid=$(cat "$away_owner/pid" 2>/dev/null || printf '')
        away_recorded=$(cat "$away_owner/pid-identity" 2>/dev/null || printf '')
        away_current=$(fm_pid_identity "$away_pid" 2>/dev/null || printf '')
        away_key="${away_pid:-unknown}:${away_recorded:-missing}:${away_current:-unknown}"
        if [ "$read_only" = 0 ] && [ "$(cat "$AWAY_AMBIGUOUS" 2>/dev/null || printf '')" != "$away_key" ]; then
          printf '%s\n' "$away_key" > "$AWAY_AMBIGUOUS" 2>/dev/null || true
          escalate "away mode has an ambiguous live daemon lock; refusing a second continuity owner"
        fi
        HS_DEFER_REASON="away mode has an ambiguous live daemon lock; continuity is quarantined"
        return 0
        ;;
      *) [ "$read_only" = 1 ] || rm -f "$AWAY_AMBIGUOUS" 2>/dev/null || true ;;
    esac
  fi
  if fm_pi_extension_owns_supervision "$STATE" "$FM_ROOT" 2>/dev/null; then
    HS_DEFER_REASON="the Pi primary extension owns watcher continuity"
    return 0
  fi
  return 1
}

herdr_blocked_clear() {
  rm -f "$BLOCKED" 2>/dev/null
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
  local session=$1 workspace=$2 expected_socket=${3:-} expected_socket_identity=${4:-}
  [ -n "$workspace" ] || return 0
  [ -n "$expected_socket" ] && [ -n "$expected_socket_identity" ] || return 1
  herdr_identity >/dev/null 2>&1 || return 1
  [ "$HS_SESSION" = "$session" ] && [ "$HS_SOCKET" = "$expected_socket" ] \
    && [ "$HS_SOCKET_IDENTITY" = "$expected_socket_identity" ] || return 1
  if herdr_workspace_control "$expected_socket" "$expected_socket_identity" close "$workspace" >/dev/null 2>&1; then
    ledger_append rollback "closed workspace $workspace after a failed establish"
    return 0
  fi
  ledger_append rollback-failed "could not close workspace $workspace after a failed establish"
  return 1
}

cleanup_establish_failure() {  # <session> <workspace> <detail>
  local session=$1 workspace=$2 detail=$3 pending_workspace pending_socket pending_socket_identity
  pending_workspace=$(pending_get workspace || printf '')
  pending_socket=$(pending_get herdr_socket || printf '')
  pending_socket_identity=$(pending_get herdr_socket_identity || printf '')
  [ -n "$workspace" ] || workspace=$pending_workspace
  if ! rollback_workspace "$session" "$workspace" "$pending_socket" "$pending_socket_identity"; then
    pending_restore_record quarantine || true
    escalate "$detail; exact workspace $workspace could not be closed and the supervisor binding was retained"
    return 1
  fi
  if ! pending_set_cleanup_state closed; then
    record_set_mode quarantine || true
    escalate "$detail; exact workspace closure was not durably recorded"
    return 1
  fi
  record_set_cleanup_state closed || true
  if ! record_clear; then
    record_set_mode quarantine || pending_restore_record quarantine || true
    escalate "$detail; exact workspace $workspace closed but supervisor binding cleanup failed"
    return 1
  fi
  pending_clear || {
    escalate "$detail; exact workspace $workspace closed but pending cleanup evidence could not be cleared"
    return 1
  }
  launcher_clear
}

quarantine_recorded_binding_locked() {
  local reason=$1 generation target tmp loop_pid loop_identity current i=0
  generation=$(record_get generation || printf unknown)
  case "$generation" in
    ''|*[!A-Za-z0-9._-]*) generation=unknown-${BASHPID:-$$} ;;
  esac
  target="$QUARANTINE_PREFIX.$generation"
  tmp="$target.tmp.${BASHPID:-$$}"
  if ! {
    awk '!/^mode=/' "$RECORD"
    printf 'mode=quarantine\n'
    printf 'quarantine_reason=%s\n' "$(ledger_clean_field "$reason")"
  } > "$tmp" 2>/dev/null || ! chmod 600 "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  loop_pid=$(live_get loop_pid || printf '')
  loop_identity=$(live_get loop_identity || printf '')
  if [ -n "$loop_pid" ] && fm_pid_alive "$loop_pid"; then
    [ -n "$loop_identity" ] || {
      record_set_mode quarantine || true
      ledger_append quarantine "could not terminate the old supervisor because its process identity is unknown"
      return 1
    }
    current=$(fm_pid_identity "$loop_pid" 2>/dev/null || printf '')
    [ "$current" = "$loop_identity" ] || {
      record_set_mode quarantine || true
      ledger_append quarantine "could not terminate the old supervisor because its process identity changed"
      return 1
    }
    kill -TERM "$loop_pid" 2>/dev/null || {
      record_set_mode quarantine || true
      ledger_append quarantine "could not signal the old supervisor for quarantine"
      return 1
    }
    while [ "$i" -lt 20 ] && fm_pid_alive "$loop_pid"; do
      current=$(fm_pid_identity "$loop_pid" 2>/dev/null || printf '')
      [ "$current" = "$loop_identity" ] || {
        record_set_mode quarantine || true
        ledger_append quarantine "old supervisor identity changed during quarantine"
        return 1
      }
      sleep 0.05
      i=$((i + 1))
    done
    if fm_pid_alive "$loop_pid"; then
      record_set_mode quarantine || true
      ledger_append quarantine "old supervisor did not terminate during quarantine"
      return 1
    fi
  fi
  record_clear || return 1
  launcher_clear
  rm -f "$HEARTBEAT" 2>/dev/null || true
  ledger_append quarantined "$reason resource=$target"
}

recorded_herdr_identity_matches() {
  local session socket socket_identity
  session=$(record_get herdr_session || printf '')
  socket=$(record_get herdr_socket || printf '')
  socket_identity=$(record_get herdr_socket_identity || printf '')
  [ -n "$session" ] && [ -n "$socket" ] && [ -n "$socket_identity" ] || return 1
  herdr_identity || return 1
  [ "$HS_SESSION" = "$session" ] && [ "$HS_SOCKET" = "$socket" ] \
    && [ "$HS_SOCKET_IDENTITY" = "$socket_identity" ]
}

recorded_workspace_matches() {
  local session workspace tab pane
  session=$(record_get herdr_session || printf '')
  workspace=$(record_get workspace || printf '')
  tab=$(record_get tab || printf '')
  pane=$(record_get pane || printf '')
  [ -n "$session" ] \
    && [ -n "$workspace" ] && [ -n "$tab" ] && [ -n "$pane" ] || return 1
  pane_binding_intact "$session" "$workspace" "$tab" "$pane" || return 1
}

recorded_workspace_absent() {
  local session socket socket_identity workspace out
  session=$(record_get herdr_session || printf '')
  socket=$(record_get herdr_socket || printf '')
  socket_identity=$(record_get herdr_socket_identity || printf '')
  workspace=$(record_get workspace || printf '')
  [ -n "$session" ] && [ -n "$socket" ] && [ -n "$socket_identity" ] \
    && [ -n "$workspace" ] || return 1
  out=$(herdr_workspace_control "$socket" "$socket_identity" list 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg workspace "$workspace" \
    '[.result.workspaces[]? | select(.workspace_id == $workspace)] | length == 0' \
    >/dev/null 2>&1
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
  local reason=$1 generation out workspace tab pane cmd deadline pid detail label

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
    printf 'herdr_socket_identity=%s\n' "$HS_SOCKET_IDENTITY"
    printf 'mode=active\n'
    printf 'cleanup_state=open\n'
    printf 'established_at=%s\n' "$(date +%s)"
    printf 'establish_reason=%s\n' "$(ledger_clean_field "$reason")"
  } | record_put || {
    escalate "the supervisor record could not be written under $STATE"
    echo "herdr-supervisor: FAILED - the supervisor record could not be written" >&2
    return 1
  }
  ledger_append establish-begin "$reason"

  label="$(supervisor_label)-$generation"
  pending_begin_create "$generation" "$HS_SESSION" "$HS_SOCKET" "$HS_SOCKET_IDENTITY" "$label" "$FM_ROOT" || {
    record_clear || true
    escalate "the supervisor's exact create intent could not be persisted before workspace creation"
    echo "herdr-supervisor: FAILED - the supervisor create intent could not be persisted" >&2
    return 1
  }

  out=$(hs_herdr "$HS_SESSION" workspace create \
    --cwd "$FM_ROOT" --label "$label" --no-focus 2>/dev/null) || out=
  workspace=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$workspace" ] || [ -z "$tab" ] || [ -z "$pane" ]; then
    detail="Herdr returned an incomplete workspace-create response (workspace='${workspace:-none}' tab='${tab:-none}' pane='${pane:-none}'), so no supervisor pane could be created"
    detail="$detail; the pending create intent remains for exact-label reconciliation"
    pending_record_create_ids "${workspace:-}" "${tab:-}" "${pane:-}" || \
      detail="$detail; returned resource ids could not be persisted"
    record_clear || true
    escalate "$detail"
    echo "herdr-supervisor: FAILED - Herdr returned an incomplete workspace-create response" >&2
    return 1
  fi

  pending_put "$generation" "$HS_SESSION" "$HS_SOCKET" "$workspace" "$tab" "$pane" || {
    detail="the exact Herdr workspace binding could not be persisted for cleanup"
    if rollback_workspace "$HS_SESSION" "$workspace" "$HS_SOCKET" "$HS_SOCKET_IDENTITY"; then
      record_set_cleanup_state closed || true
      record_clear || record_set_mode quarantine || true
    else
      {
        printf 'version=%s\n' "$RECORD_VERSION"
        printf 'generation=%s\n' "$generation"
        printf 'fm_home=%s\n' "$FM_HOME"
        printf 'fm_root=%s\n' "$FM_ROOT"
        printf 'herdr_session=%s\n' "$HS_SESSION"
        printf 'herdr_socket=%s\n' "$HS_SOCKET"
        printf 'herdr_socket_identity=%s\n' "$HS_SOCKET_IDENTITY"
        printf 'workspace=%s\n' "$workspace"
        printf 'tab=%s\n' "$tab"
        printf 'pane=%s\n' "$pane"
        printf 'mode=quarantine\n'
        printf 'cleanup_state=open\n'
        printf 'established_at=%s\n' "$(date +%s)"
        printf 'establish_reason=pending-cleanup\n'
      } | record_put || true
    fi
    escalate "$detail; workspace $workspace may remain and was not replaced"
    echo "herdr-supervisor: FAILED - $detail" >&2
    return 1
  }

  {
    printf 'version=%s\n' "$RECORD_VERSION"
    printf 'generation=%s\n' "$generation"
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'fm_root=%s\n' "$FM_ROOT"
    printf 'herdr_session=%s\n' "$HS_SESSION"
    printf 'herdr_socket=%s\n' "$HS_SOCKET"
    printf 'herdr_socket_identity=%s\n' "$HS_SOCKET_IDENTITY"
    printf 'workspace=%s\n' "$workspace"
    printf 'tab=%s\n' "$tab"
    printf 'pane=%s\n' "$pane"
    printf 'mode=active\n'
    printf 'cleanup_state=open\n'
    printf 'established_at=%s\n' "$(date +%s)"
    printf 'establish_reason=%s\n' "$(ledger_clean_field "$reason")"
  } | record_put || {
    detail="the supervisor record could not be updated after its Herdr pane was created"
    cleanup_establish_failure "$HS_SESSION" "$workspace" "$detail" || {
      echo "herdr-supervisor: FAILED - $detail; cleanup was retained for retry" >&2
      return 1
    }
    escalate "$detail"
    echo "herdr-supervisor: FAILED - the supervisor record could not be updated" >&2
    return 1
  }
  pending_clear || true

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
    [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ] || printf 'export FM_PROC_ROOT_OVERRIDE=%s\n' "$(shell_quote "$FM_PROC_ROOT_OVERRIDE")"
    [ -z "${FM_GUARD_GRACE:-}" ] || printf 'export FM_GUARD_GRACE=%s\n' "$(shell_quote "$FM_GUARD_GRACE")"
    [ -z "${FM_WATCHER_STALE_GRACE:-}" ] || printf 'export FM_WATCHER_STALE_GRACE=%s\n' "$(shell_quote "$FM_WATCHER_STALE_GRACE")"
    [ -z "${FM_ARM_CONFIRM_TIMEOUT:-}" ] || printf 'export FM_ARM_CONFIRM_TIMEOUT=%s\n' "$(shell_quote "$FM_ARM_CONFIRM_TIMEOUT")"
    printf 'export FM_WATCH_ARM_WAKE_QUEUE_LOCK_TRIES=%s\n' "$WATCH_QUEUE_LOCK_TRIES"
    printf 'export FM_WAKE_QUEUE_LOCK_TRIES=%s\n' "$WATCH_QUEUE_LOCK_TRIES"
    printf 'export FM_WAKE_APPEND_LOCK_TRIES=%s\n' "$WATCH_QUEUE_LOCK_TRIES"
    printf 'export FM_WAKE_QUEUED_KEYS_LOCK_TRIES=%s\n' "$WATCH_QUEUE_LOCK_TRIES"
    printf 'export FM_RECOVERY_MARKER_LOCK_TRIES=100\n'
    [ -z "${FM_SIGNAL_GRACE:-}" ] || printf 'export FM_SIGNAL_GRACE=%s\n' "$(shell_quote "$FM_SIGNAL_GRACE")"
    [ -z "${FM_POLL:-}" ] || printf 'export FM_POLL=%s\n' "$(shell_quote "$FM_POLL")"
    [ -z "${FM_CHECK_INTERVAL:-}" ] || printf 'export FM_CHECK_INTERVAL=%s\n' "$(shell_quote "$FM_CHECK_INTERVAL")"
    [ -z "${FM_HEARTBEAT:-}" ] || printf 'export FM_HEARTBEAT=%s\n' "$(shell_quote "$FM_HEARTBEAT")"
    printf 'export FM_HERDR_SUPERVISOR_HEARTBEAT_GRACE=%s\n' "$HEARTBEAT_GRACE"
    printf 'export FM_HERDR_SUPERVISOR_READY_TIMEOUT=%s\n' "$READY_TIMEOUT"
    printf 'export FM_HERDR_SUPERVISOR_UNKNOWN_ARM_TIMEOUT=%s\n' "$UNKNOWN_ARM_TIMEOUT"
    printf 'export FM_HERDR_SUPERVISOR_UNKNOWN_ARM_RETRY_LIMIT=%s\n' "$UNKNOWN_ARM_RETRY_LIMIT"
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
    detail="the supervisor launcher script could not be written to $LAUNCHER"
    cleanup_establish_failure "$HS_SESSION" "$workspace" "$detail" || {
      echo "herdr-supervisor: FAILED - $detail; cleanup was retained for retry" >&2
      return 1
    }
    escalate "$detail"
    echo "herdr-supervisor: FAILED - the supervisor launcher script could not be written" >&2
    return 1
  fi
  cmd="exec bash $(shell_quote "$LAUNCHER")"
  if ! hs_herdr "$HS_SESSION" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    detail="the supervisor loop could not be started in Herdr pane $pane"
    cleanup_establish_failure "$HS_SESSION" "$workspace" "$detail" || {
      echo "herdr-supervisor: FAILED - $detail; cleanup was retained for retry" >&2
      return 1
    }
    escalate "$detail"
    echo "herdr-supervisor: FAILED - the supervisor loop could not be started in pane $pane" >&2
    return 1
  fi

  deadline=$(( $(date +%s) + READY_TIMEOUT + 1 ))
  while :; do
    if [ "$(record_get generation || printf '')" = "$generation" ] && supervisor_healthy; then
      ledger_append established "generation=$generation pane=$pane workspace=$workspace"
      pid=$(live_get loop_pid || printf '')
      echo "herdr-supervisor: started generation=$generation pane=$pane pid=$pid"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 0.5
  done

  detail="the supervisor loop did not confirm within ${READY_TIMEOUT}s (${HS_UNHEALTHY_REASON:-no reason recorded})"
  cleanup_establish_failure "$HS_SESSION" "$workspace" "$detail" || {
    echo "herdr-supervisor: FAILED - $detail; cleanup was retained for retry" >&2
    return 1
  }
  escalate "$detail"
  echo "herdr-supervisor: FAILED - $detail" >&2
  return 1
}

# --- commands -----------------------------------------------------------------

retire_binding_locked() {  # <reason> [signal-owner]
  local reason=$1 signal_owner=${2:-1}
  local session workspace tab pane loop_pid loop_identity current cleanup_state workspace_absent=0 i=0
  session=$(record_get herdr_session || printf '')
  workspace=$(record_get workspace || printf '')
  tab=$(record_get tab || printf '')
  pane=$(record_get pane || printf '')
  loop_pid=$(live_get loop_pid || printf '')
  loop_identity=$(live_get loop_identity || printf '')

  if [ -n "$workspace" ] && ! recorded_herdr_identity_matches; then
    quarantine_recorded_binding_locked "recorded Herdr session or socket is not the current server for $reason" \
      || ledger_append quarantine "could not retain the old binding after Herdr identity changed for $reason"
    return 1
  fi
  if [ -n "$workspace" ] && ! recorded_workspace_matches; then
    record_set_mode quarantine || true
    ledger_append quarantine "could not prove the recorded Herdr pane and process still own $workspace for $reason"
    return 1
  fi
  record_set_mode retiring || return 1

  if [ "$signal_owner" -eq 1 ] && [ -n "$loop_pid" ] \
    && [ "$loop_pid" != "${BASHPID:-$$}" ] && fm_pid_alive "$loop_pid"; then
    if [ -z "$loop_identity" ]; then
      record_set_mode quarantine || true
      ledger_append quarantine "could not terminate the old supervisor because its process identity is unknown"
      return 1
    fi
    current=$(fm_pid_identity "$loop_pid" 2>/dev/null || printf '')
    if [ "$current" = "$loop_identity" ]; then
      kill -TERM "$loop_pid" 2>/dev/null || {
        record_set_mode quarantine || true
        ledger_append quarantine "could not signal the old supervisor for $reason"
        return 1
      }
      while [ "$i" -lt 100 ] && fm_pid_alive "$loop_pid"; do
        current=$(fm_pid_identity "$loop_pid" 2>/dev/null || printf '')
        [ "$current" = "$loop_identity" ] || {
          record_set_mode quarantine || true
          ledger_append quarantine "old supervisor identity changed during $reason"
          return 1
        }
        sleep 0.05
        i=$((i + 1))
      done
      if fm_pid_alive "$loop_pid"; then
        current=$(fm_pid_identity "$loop_pid" 2>/dev/null || printf '')
        [ "$current" = "$loop_identity" ] || {
          record_set_mode quarantine || true
          ledger_append quarantine "old supervisor identity changed before forced termination for $reason"
          return 1
        }
        kill -KILL "$loop_pid" 2>/dev/null || true
        i=0
        while [ "$i" -lt 20 ] && fm_pid_alive "$loop_pid"; do
          sleep 0.05
          i=$((i + 1))
        done
        if fm_pid_alive "$loop_pid"; then
          record_set_mode quarantine || true
          ledger_append quarantine "old supervisor did not terminate after bounded forced termination for $reason"
          return 1
        fi
      fi
    else
      record_set_mode quarantine || true
      ledger_append quarantine "could not terminate the old supervisor because its process identity changed"
      return 1
    fi
  fi

  cleanup_state=$(record_get cleanup_state || printf open)
  if [ -n "$workspace" ] && [ "$cleanup_state" != closed ]; then
    pending_put "$(record_get generation || printf unknown)" "$session" \
      "$(record_get herdr_socket || printf '')" "$workspace" "$tab" "$pane" || {
      record_set_mode quarantine || true
      ledger_append quarantine "could not persist exact workspace cleanup for $reason"
      return 1
    }
  fi
  if [ -n "$workspace" ] && [ "$cleanup_state" != closed ] \
    && { ! recorded_herdr_identity_matches || ! recorded_workspace_matches; }; then
    if recorded_herdr_identity_matches && recorded_workspace_absent; then
      workspace_absent=1
    else
      record_set_mode quarantine || true
      ledger_append quarantine "could not prove the recorded Herdr binding immediately before closing $workspace for $reason"
      return 1
    fi
  fi
  if [ -n "$workspace" ] && [ "$cleanup_state" != closed ] && [ -n "$session" ] \
    && [ "$workspace_absent" -eq 0 ] \
    && herdr_workspace_control "$(record_get herdr_socket || printf '')" \
      "$(record_get herdr_socket_identity || printf '')" close "$workspace" >/dev/null 2>&1; then
    :
  elif [ -n "$workspace" ] && [ "$cleanup_state" != closed ] \
    && recorded_herdr_identity_matches && recorded_workspace_absent; then
    workspace_absent=1
  elif [ -n "$workspace" ]; then
    record_set_mode quarantine || true
    ledger_append quarantine "could not close exact workspace $workspace for $reason"
    return 1
  fi
  if ! pending_set_cleanup_state closed; then
    record_set_mode quarantine || true
    ledger_append quarantine "could not record closure of exact workspace ${workspace:-none} for $reason"
    return 1
  fi
  record_set_cleanup_state closed || {
    record_set_mode quarantine || true
    ledger_append quarantine "could not record closure of exact workspace ${workspace:-none} for $reason"
    return 1
  }
  if ! record_clear; then
    record_set_mode quarantine || true
    ledger_append quarantine "could not clear binding after closing exact workspace ${workspace:-none} for $reason"
    return 1
  fi
  pending_clear || true
  ledger_append retired "$reason"
  rm -f "$HEARTBEAT" 2>/dev/null || true
  launcher_clear
  return 0
}

reconcile_previous_locked() {
  local old_generation rc
  [ -f "$RECORD" ] || return 0
  old_generation=$(record_get generation || printf unknown)
  ledger_append replace-required "retiring unhealthy generation=$old_generation before replacement"
  if ! recorded_herdr_identity_matches || ! recorded_workspace_matches; then
    quarantine_recorded_binding_locked "the prior Herdr binding could not be proven safe to close while replacing generation=$old_generation" \
      || {
        escalate "generation $old_generation could not be quarantined before replacement"
        return 1
      }
    return 0
  fi
  retire_binding_locked "replacing unhealthy generation=$old_generation" 1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    escalate "the previous supervisor generation $old_generation is quarantined because its exact Herdr workspace could not be retired; retry cleanup before replacement"
    return 1
  fi
  [ ! -f "$RECORD" ] || {
    escalate "the previous supervisor generation $old_generation could not be cleared before replacement"
    return 1
  }
  return 0
}

reconcile_pending_locked() {
  local state generation workspace session socket socket_identity record_mode record_generation record_workspace record_cleanup_state create_state
  [ -f "$PENDING" ] || return 0
  state=$(pending_get cleanup_state || printf open)
  generation=$(pending_get generation || printf '')
  workspace=$(pending_get workspace || printf '')
  session=$(pending_get herdr_session || printf '')
  socket=$(pending_get herdr_socket || printf '')
  socket_identity=$(pending_get herdr_socket_identity || printf '')
  create_state=$(pending_get create_state || printf '')
  record_mode=$(record_get mode || printf '')
  record_generation=$(record_get generation || printf '')
  record_workspace=$(record_get workspace || printf '')
  record_cleanup_state=$(record_get cleanup_state || printf open)
  if [ "$create_state" = creating ]; then
    pending_quarantine "incomplete Herdr create response has no exact cleanup authorization" || return 1
    escalate "incomplete or ambiguous Herdr create was quarantined without cleanup because its response did not return an exact workspace identity" || true
    return 0
  fi
  if [ "$record_mode" = active ] \
    && [ "$(record_get generation || printf '')" = "$generation" ] \
    && [ "$(record_get workspace || printf '')" = "$workspace" ]; then
    pending_clear
    return $?
  fi
  if [ "$state" = closed ] || [ "$record_cleanup_state" = closed ]; then
    if [ -f "$RECORD" ] \
      && { [ "$record_generation" != "$generation" ] \
        || { [ -n "$record_workspace" ] && [ "$record_workspace" != "$workspace" ]; }; }; then
      pending_clear
      return $?
    fi
    record_clear || return 1
    pending_clear
    return $?
  fi
  [ -n "$session" ] && [ -n "$socket" ] && [ -n "$socket_identity" ] \
    && [ -n "$workspace" ] || return 1
  herdr_identity || return 1
  [ "$HS_SESSION" = "$session" ] && [ "$HS_SOCKET" = "$socket" ] \
    && [ "$HS_SOCKET_IDENTITY" = "$socket_identity" ] || return 1
  if ! rollback_workspace "$session" "$workspace" "$socket" "$socket_identity"; then
    pending_restore_record quarantine || true
    return 1
  fi
  pending_set_cleanup_state closed || return 1
  if [ -f "$RECORD" ] && [ "$record_generation" = "$generation" ]; then
    if [ -n "$record_workspace" ] && [ "$record_workspace" != "$workspace" ]; then
      pending_clear
      return $?
    fi
    record_set_cleanup_state closed || return 1
    record_clear || {
      record_set_mode quarantine || pending_restore_record quarantine || true
      return 1
    }
  fi
  pending_clear
}

cmd_ensure() {  # <reason>
  local reason=$1 rc preference blocked_reason
  preference=$(hs_config_preference)
  if ! supervisor_eligible; then
    if [ "$preference" = off ] && [ -f "$PENDING" ]; then
      if ! supervisor_lock_acquire "$RECORD_LOCK"; then
        escalate "config/herdr-supervisor is off, but the pending Herdr cleanup record lock could not be acquired"
        return 1
      fi
      reconcile_pending_locked
      rc=$?
      fm_lock_release "$RECORD_LOCK"
      if [ "$rc" -ne 0 ]; then
        escalate "config/herdr-supervisor is off, but the pending Herdr cleanup record could not be reconciled"
        return "$rc"
      fi
    fi
    if [ "$preference" = off ] && [ -f "$RECORD" ]; then
      if ! supervisor_lock_acquire "$RECORD_LOCK"; then
        escalate "the supervisor record lock could not be acquired within its bounded retry window"
        return 1
      fi
      retire_binding_locked "config/herdr-supervisor changed to off" 1
      rc=$?
      if [ "$rc" -ne 0 ]; then
        escalate "config/herdr-supervisor is off, but the exact supervisor workspace could not be retired"
      fi
      fm_lock_release "$RECORD_LOCK"
      [ "$rc" -eq 0 ] || return "$rc"
      [ ! -f "$RECORD" ] || {
        escalate "config/herdr-supervisor is off, but its supervisor record remains"
        return 1
      }
    fi
    echo "herdr-supervisor: not eligible - $HS_INELIGIBLE_REASON"
    return 0
  fi
  if ! fm_supervision_claim_acquire "$SUPERVISION_CLAIM" "$SUPERVISOR_LOCK_TRIES"; then
    escalate "the continuity ownership claim could not be acquired within its bounded retry window"
    return 1
  fi
  if ! fm_supervision_claim_pending_reclaim "$STATE"; then
    fm_lock_release "$SUPERVISION_CLAIM"
    escalate "the expired away-mode ownership handoff could not be reconciled"
    return 1
  fi
  if fm_supervision_claim_pending_expired_live "$STATE"; then
    fm_lock_release "$SUPERVISION_CLAIM"
    escalate "the native away-mode handoff reservation expired while its launcher remains live; refusing a second continuity owner"
    return 1
  fi
  if [ -f "$BLOCKED" ]; then
    blocked_reason=$(sed -n 's/^reason=//p' "$BLOCKED" 2>/dev/null | head -n 1)
    escalate "discarding stale unresolved arm record; its child may still be live (${blocked_reason:-no reason recorded})"
    if ! herdr_blocked_clear; then
      fm_lock_release "$SUPERVISION_CLAIM"
      escalate "the stale Herdr unresolved arm record could not be cleared"
      return 1
    fi
  fi
  if harness_owner_provable; then
    fm_lock_release "$SUPERVISION_CLAIM"
    echo "herdr-supervisor: deferred - $HS_DEFER_REASON"
    return 0
  fi
  if ! fm_supervision_needed "$STATE"; then
    fm_lock_release "$SUPERVISION_CLAIM"
    echo "herdr-supervisor: not needed - this home has no in-flight work, event source, or relay poll"
    return 0
  fi

  if ! supervisor_lock_acquire "$RECORD_LOCK"; then
    fm_lock_release "$SUPERVISION_CLAIM"
    escalate "the supervisor record lock could not be acquired within its bounded retry window"
    return 1
  fi
  if ! reconcile_pending_locked; then
    fm_lock_release "$RECORD_LOCK"
    fm_lock_release "$SUPERVISION_CLAIM"
    escalate "pending Herdr supervisor cleanup could not be reconciled; replacement is blocked"
    return 1
  fi
  if supervisor_healthy; then
    fm_lock_release "$RECORD_LOCK"
    fm_lock_release "$SUPERVISION_CLAIM"
    echo "herdr-supervisor: unchanged generation=$(record_get generation) pane=$(record_get pane) pid=$(live_get loop_pid)"
    return 0
  fi
  ledger_append establish-required "${HS_UNHEALTHY_REASON:-unknown}"
  if ! reconcile_previous_locked; then
    fm_lock_release "$RECORD_LOCK"
    fm_lock_release "$SUPERVISION_CLAIM"
    return 1
  fi
  establish "$reason (${HS_UNHEALTHY_REASON:-no prior record})"
  rc=$?
  fm_lock_release "$RECORD_LOCK"
  fm_lock_release "$SUPERVISION_CLAIM"
  return "$rc"
}

cmd_retire() {  # <reason>
  local reason=$1 rc
  if ! supervisor_lock_acquire "$RECORD_LOCK"; then
    escalate "the supervisor record lock could not be acquired within its bounded retry window"
    return 1
  fi
  if [ -f "$PENDING" ] && ! reconcile_pending_locked; then
    fm_lock_release "$RECORD_LOCK"
    escalate "pending Herdr supervisor cleanup could not be reconciled for retire"
    return 1
  fi
  if [ ! -f "$RECORD" ]; then
    fm_lock_release "$RECORD_LOCK"
    echo "herdr-supervisor: nothing to retire"
    return 0
  fi
  retire_binding_locked "$reason" 1
  rc=$?
  fm_lock_release "$RECORD_LOCK"
  if [ "$rc" -ne 0 ]; then
    escalate "the exact supervisor workspace could not be retired for: $reason"
    echo "herdr-supervisor: FAILED - could not retire the exact supervisor workspace" >&2
    return "$rc"
  fi
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
  if harness_owner_provable 1; then
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
LOOP_ARM_PID=
LOOP_ARM_IDENTITY=
LOOP_CLAIM_HELD=0
loop_release_claim() {
  if [ "$LOOP_CLAIM_HELD" -eq 1 ]; then
    fm_lock_release "$SUPERVISION_CLAIM" || return 1
    LOOP_CLAIM_HELD=0
  fi
}
loop_owns_generation() {
  [ "$(record_get generation 2>/dev/null || printf '')" = "$LOOP_GENERATION" ]
}

# Retract this loop's own liveness claim on the way out. Only ever removes a
# live record this generation published, so a successor that already replaced it
# is never disturbed.
loop_release_live() {
  supervisor_lock_acquire "$LIVE_LOCK" || return 1
  if [ "$(live_get generation 2>/dev/null || printf '')" = "$LOOP_GENERATION" ]; then
    rm -f "$LIVE" 2>/dev/null || true
  fi
  fm_lock_release "$LIVE_LOCK"
}

loop_abandon_unresolved_arm() {
  local reason pid identity arm_out
  pid=${LOOP_ARM_PID:-unknown}
  identity=${LOOP_ARM_IDENTITY:-unknown}
  arm_out=${LOOP_ARM_OUT:-}
  reason="the arm identity remained unknown after $UNKNOWN_ARM_RETRY_LIMIT bounded termination attempts; abandoning child pid=$pid identity=$identity while retaining generation=$LOOP_GENERATION"
  escalate "$reason"
  ledger_append arm-abandoned "pid=$pid identity=$identity"
  herdr_blocked_clear || true
  LOOP_ARM_PID=
  LOOP_ARM_IDENTITY=
  LOOP_ARM_UNRESOLVED=0
  LOOP_ARM_UNRESOLVED_NEXT=0
  LOOP_ARM_UNRESOLVED_ATTEMPTS=0
  [ -z "$arm_out" ] || rm -f "$arm_out" 2>/dev/null || true
  LOOP_ARM_OUT=
  failures=0
  rapid=0
}

# loop_publish_live writes ONLY the live record, so it never contends with the
# establish lock the caller is still holding while it waits for this.
loop_publish_live() {  # <pane-pid>
  local pid=$1 identity tmp
  supervisor_lock_acquire "$LIVE_LOCK" || return 1
  identity=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
  if [ -z "$identity" ] || ! loop_owns_generation; then
    fm_lock_release "$LIVE_LOCK"
    return 1
  fi
  tmp="$LIVE.tmp.$pid"
  {
    printf 'generation=%s\n' "$LOOP_GENERATION"
    printf 'loop_pid=%s\n' "$pid"
    printf 'loop_identity=%s\n' "$identity"
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$LIVE_LOCK"
    return 1
  }
  if ! mv -f "$tmp" "$LIVE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$LIVE_LOCK"
    return 1
  fi
  if ! loop_owns_generation; then
    rm -f "$LIVE" 2>/dev/null || true
    fm_lock_release "$LIVE_LOCK"
    return 1
  fi
  fm_lock_release "$LIVE_LOCK"
  return 0
}

loop_arm_matches() {
  local pid=${LOOP_ARM_PID:-} current process_state
  [ -n "$pid" ] && fm_pid_alive "$pid" || return 1
  process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  case "$process_state" in Z*) return 1 ;; esac
  current=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
  [ -n "$LOOP_ARM_IDENTITY" ] || return 2
  [ -n "$current" ] && [ "$current" = "$LOOP_ARM_IDENTITY" ] || return 2
  return 0
}

loop_capture_arm_identity() {
  local pid=${LOOP_ARM_PID:-} i=0 candidate previous=
  LOOP_ARM_IDENTITY=
  while [ "$i" -lt 20 ] && fm_pid_alive "$pid"; do
    candidate=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
    # On macOS, a script launched through an /usr/bin/env shebang briefly
    # reports the env trampoline as its command before execing bash. Do not
    # publish that transient identity: it would make the real arm look
    # recycled as soon as the trampoline completes.
    case "$candidate" in
      *'     /usr/bin/env bash '*)
        previous=
        sleep 0.05
        i=$((i + 1))
        continue
        ;;
    esac
    if [ -n "$candidate" ] && [ "$candidate" = "$previous" ]; then
      LOOP_ARM_IDENTITY=$candidate
      return 0
    fi
    previous=$candidate
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

loop_wait_unknown_arm() {
  local pid=${LOOP_ARM_PID:-} process_state deadline
  [ -n "$pid" ] || return 0
  deadline=$(( $(date +%s) + UNKNOWN_ARM_TIMEOUT + 1 ))
  while :; do
    process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ -n "$process_state" ] || break
    case "$process_state" in Z*) break ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    : > "$HEARTBEAT" 2>/dev/null || true
    sleep 0.5
  done
  wait "$pid" 2>/dev/null || true
}

loop_stop_arm() {
  local pid=${LOOP_ARM_PID:-} current process_state i=0
  [ -n "$pid" ] || return 0
  if [ -n "$LOOP_ARM_IDENTITY" ] && ! loop_arm_matches; then
    i=0
    while [ "$i" -lt 20 ] && fm_pid_alive "$pid"; do
      current=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
      [ -n "$current" ] && break
      sleep 0.05
      i=$((i + 1))
    done
  fi
  if loop_arm_matches; then
    kill -TERM "$pid" 2>/dev/null || true
    while loop_arm_matches && [ "$i" -lt 20 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    if loop_arm_matches; then
      current=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
      if [ -n "$LOOP_ARM_IDENTITY" ] && [ "$current" = "$LOOP_ARM_IDENTITY" ]; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
  fi
  process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$process_state" ] || [[ "$process_state" == Z* ]] || ! fm_pid_alive "$pid"; then
    wait "$pid" 2>/dev/null || true
  elif [ -n "$LOOP_ARM_IDENTITY" ]; then
    current=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
    if [ "$current" != "$LOOP_ARM_IDENTITY" ]; then
      LOOP_ARM_UNRESOLVED=1
      LOOP_ARM_UNRESOLVED_NEXT=$(( $(date +%s) + UNKNOWN_ARM_TIMEOUT + 1 ))
      return 1
    fi
    i=0
    while [ "$i" -lt 20 ] && fm_pid_alive "$pid"; do
      current=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
      if [ "$current" != "$LOOP_ARM_IDENTITY" ]; then
        LOOP_ARM_UNRESOLVED=1
        LOOP_ARM_UNRESOLVED_NEXT=$(( $(date +%s) + UNKNOWN_ARM_TIMEOUT + 1 ))
        return 1
      fi
      sleep 0.05
      i=$((i + 1))
    done
    if fm_pid_alive "$pid"; then
      LOOP_ARM_UNRESOLVED=1
      LOOP_ARM_UNRESOLVED_NEXT=$(( $(date +%s) + UNKNOWN_ARM_TIMEOUT + 1 ))
      return 1
    fi
    wait "$pid" 2>/dev/null || true
  else
    if ! loop_wait_unknown_arm; then
      LOOP_ARM_UNRESOLVED=1
      LOOP_ARM_UNRESOLVED_NEXT=$(( $(date +%s) + UNKNOWN_ARM_TIMEOUT + 1 ))
      return 1
    fi
  fi
  LOOP_ARM_PID=
  LOOP_ARM_IDENTITY=
  LOOP_ARM_UNRESOLVED=0
  LOOP_ARM_UNRESOLVED_NEXT=0
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

watcher_stale_lock_verified() {
  local lockdir pid age beat lock_home lock_path lock_identity current_identity
  lockdir="$STATE/.watch.lock"
  beat="$STATE/.last-watcher-beat"
  [ -e "$lockdir" ] || return 1
  pid=$(cat "$lockdir/pid" 2>/dev/null || printf '')
  fm_pid_alive "$pid" || return 1
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || printf '')
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || printf '')
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || printf '')
  [ "$lock_home" = "$FM_HOME" ] && [ "$lock_path" = "$FM_ROOT/bin/fm-watch.sh" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null || printf '')
  if [ "$current_identity" != "$lock_identity" ]; then
    [ -n "$current_identity" ] || return 1
    return 0
  else
    fm_watcher_lock_matches_pid "$STATE" "$FM_ROOT/bin/fm-watch.sh" "$pid" "$FM_HOME" || return 1
  fi
  [ -e "$beat" ] || return 0
  age=$(fm_path_age "$beat")
  case "$age" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$age" -ge "$WATCHER_STALE_GRACE" ]; then
    return 0
  fi
  return 1
}

loop_launch_verified() {  # <pid>
  local self=$1 session socket socket_identity workspace tab pane tracked
  [ -f "$RECORD" ] || return 1
  [ "$(record_get generation || printf '')" = "$LOOP_GENERATION" ] || return 1
  [ "$(record_get mode || printf '')" = active ] || return 1
  [ "$(record_get fm_home || printf '')" = "$FM_HOME" ] || return 1
  session=$(record_get herdr_session || printf '')
  socket=$(record_get herdr_socket || printf '')
  socket_identity=$(record_get herdr_socket_identity || printf '')
  workspace=$(record_get workspace || printf '')
  tab=$(record_get tab || printf '')
  pane=$(record_get pane || printf '')
  [ -n "$session" ] && [ -n "$socket" ] && [ -n "$socket_identity" ] && [ -n "$workspace" ] \
    && [ -n "$tab" ] && [ -n "$pane" ] || return 1
  herdr_identity || return 1
  [ "$HS_SESSION" = "$session" ] && [ "$HS_SOCKET" = "$socket" ] \
    && [ "$HS_SOCKET_IDENTITY" = "$socket_identity" ] || return 1
  pane_binding_intact "$session" "$workspace" "$tab" "$pane" || return 1
  tracked=$(pane_tracked_pid "$session" "$pane" 2>/dev/null || printf '')
  [ "$tracked" = "$self" ]
}

loop_launch_wait() {  # <pid>
  local self=$1 deadline
  deadline=$(( $(date +%s) + READY_TIMEOUT + 1 ))
  while ! loop_launch_verified "$self"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

cmd_run() {
  local self out rc reason failures=0 rapid=0 started ended elapsed delay process_state arm_match
  local previous_reason='' stable_cycles=0 floor_delay=0
  local LOOP_ARM_OUT
  local LOOP_ARM_UNRESOLVED=0 LOOP_ARM_UNRESOLVED_NEXT=0
  local LOOP_ARM_UNRESOLVED_ATTEMPTS=0

  self=${BASHPID:-$$}
  if ! loop_owns_generation; then
    echo "herdr-supervisor: generation $LOOP_GENERATION is not current; standing down" >&2
    exit 0
  fi
  if ! loop_launch_wait "$self"; then
    escalate "the supervisor run was not launched by its recorded Herdr pane and process"
    echo "herdr-supervisor: FAILED - run requires its recorded Herdr pane and process" >&2
    exit 1
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
  trap 'if loop_stop_arm; then [ "$LOOP_CLAIM_HELD" -eq 1 ] && fm_lock_release "$SUPERVISION_CLAIM"; LOOP_CLAIM_HELD=0; ledger_append loop-signal "terminated"; [ -z "$LOOP_ARM_OUT" ] || rm -f "$LOOP_ARM_OUT"; loop_release_live; exit 0; else escalate "the arm child could not be terminated with a verified identity; retaining supervisor ownership"; fi' HUP TERM INT

  while :; do
    if ! loop_owns_generation; then
      loop_release_claim || true
      ledger_append loop-exit "generation superseded or retired"
      loop_release_live
      exit 0
    fi
    if [ "$LOOP_ARM_UNRESOLVED" -eq 1 ]; then
      process_state=$(ps -o stat= -p "${LOOP_ARM_PID:-}" 2>/dev/null | tr -d '[:space:]')
      if [ -z "$process_state" ] || [[ "$process_state" == Z* ]]; then
        wait "${LOOP_ARM_PID:-}" 2>/dev/null || true
        LOOP_ARM_PID=
        LOOP_ARM_IDENTITY=
        LOOP_ARM_UNRESOLVED=0
        LOOP_ARM_UNRESOLVED_ATTEMPTS=0
        [ -z "$LOOP_ARM_OUT" ] || rm -f "$LOOP_ARM_OUT" 2>/dev/null || true
        LOOP_ARM_OUT=
        LOOP_ARM_UNRESOLVED_NEXT=0
        herdr_blocked_clear || true
        loop_release_claim || true
      else
        if [ "$(date +%s)" -ge "$LOOP_ARM_UNRESOLVED_NEXT" ]; then
          LOOP_ARM_UNRESOLVED_ATTEMPTS=$((LOOP_ARM_UNRESOLVED_ATTEMPTS + 1))
          if [ "$LOOP_ARM_UNRESOLVED_ATTEMPTS" -ge "$UNKNOWN_ARM_RETRY_LIMIT" ]; then
            loop_abandon_unresolved_arm
            continue
          fi
          if [ "$(hs_config_preference)" = off ]; then
            escalate "config/herdr-supervisor is off but the arm identity remains unknown; retaining the child and supervisor binding"
          elif harness_owner_provable; then
            ledger_append handoff "another continuity owner is provable while the arm identity remains unknown; retaining the child until bounded cleanup"
          else
            escalate "the arm identity remains unknown after its bounded wait; retaining the child until bounded cleanup"
          fi
          if loop_stop_arm; then
            [ -z "$LOOP_ARM_OUT" ] || rm -f "$LOOP_ARM_OUT" 2>/dev/null || true
            LOOP_ARM_OUT=
            LOOP_ARM_UNRESOLVED_ATTEMPTS=0
            herdr_blocked_clear || true
            loop_release_claim || true
          else
            LOOP_ARM_UNRESOLVED_NEXT=$(( $(date +%s) + UNKNOWN_ARM_TIMEOUT + 1 ))
          fi
        fi
        : > "$HEARTBEAT" 2>/dev/null || true
        sleep 0.5
      fi
      continue
    fi
    if [ "$(hs_config_preference)" = off ]; then
      if cmd_retire "config/herdr-supervisor changed to off"; then
        loop_release_live
        exit 0
      fi
      sleep "$IDLE_INTERVAL"
      continue
    fi
    if harness_owner_provable; then
      : > "$HEARTBEAT" 2>/dev/null || true
      sleep "$IDLE_INTERVAL"
      continue
    fi

    if [ "$(record_get mode || printf '')" != active ]; then
      : > "$HEARTBEAT" 2>/dev/null || true
      sleep "$IDLE_INTERVAL"
      continue
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
    if [ "$LOOP_CLAIM_HELD" -eq 1 ] && ! fm_lock_owned_by_current "$SUPERVISION_CLAIM"; then
      LOOP_CLAIM_HELD=0
    fi
    if [ "$LOOP_CLAIM_HELD" -eq 0 ]; then
      if ! fm_supervision_claim_acquire "$SUPERVISION_CLAIM" "$SUPERVISOR_LOCK_TRIES"; then
        escalate "the continuity ownership claim could not be acquired before arming"
        sleep "$IDLE_INTERVAL"
        continue
      fi
      LOOP_CLAIM_HELD=1
    fi
    if harness_owner_provable; then
      rm -f "$out" 2>/dev/null || true
      LOOP_ARM_OUT=
      fm_lock_release "$SUPERVISION_CLAIM"
      LOOP_CLAIM_HELD=0
      sleep "$IDLE_INTERVAL"
      continue
    fi
    started=$(date +%s)
    # A healthy watcher is followed; only a verified stale holder is replaced.
    if watcher_stale_lock_verified; then
      ledger_append watcher-restart "replacing identity-verified watcher with stale beacon"
    fi
    "$ARM" >"$out" 2>&1 &
    LOOP_ARM_PID=$!
    LOOP_ARM_UNRESOLVED_ATTEMPTS=0
    herdr_blocked_clear || true
    if loop_capture_arm_identity; then
      arm_match=0
      while loop_arm_matches; do
        : > "$HEARTBEAT" 2>/dev/null || true
        if [ "$(hs_config_preference)" = off ]; then
          loop_stop_arm || continue 2
          loop_release_claim || continue 2
          rm -f "$out" 2>/dev/null || true
          LOOP_ARM_OUT=
          if cmd_retire "config/herdr-supervisor changed to off while arming"; then
            loop_release_live
            exit 0
          fi
          sleep "$IDLE_INTERVAL"
          continue 2
        fi
        if harness_owner_provable; then
          loop_stop_arm || continue 2
          loop_release_claim || continue 2
          rm -f "$out" 2>/dev/null || true
          LOOP_ARM_OUT=
          ledger_append handoff "another continuity owner became provable while arming; retaining standby supervisor binding"
          sleep "$IDLE_INTERVAL"
          continue 2
        fi
        : > "$HEARTBEAT" 2>/dev/null || true
        sleep 0.5
      done
      arm_match=$?
    else
      arm_match=2
      escalate "the foreground watcher arm process identity became unknown or changed; retaining the child without signaling a recycled pid"
    fi
    if [ "$arm_match" -eq 2 ]; then
      if ! loop_stop_arm; then
        LOOP_ARM_UNRESOLVED=1
        LOOP_ARM_UNRESOLVED_ATTEMPTS=1
        if [ "$LOOP_ARM_UNRESOLVED_ATTEMPTS" -ge "$UNKNOWN_ARM_RETRY_LIMIT" ]; then
          loop_abandon_unresolved_arm
          continue
        fi
        LOOP_ARM_UNRESOLVED_NEXT=$(( $(date +%s) + UNKNOWN_ARM_TIMEOUT + 1 ))
        continue
      fi
      rc=125
    else
      wait "$LOOP_ARM_PID" 2>/dev/null
      rc=$?
    fi
    loop_release_claim || {
      escalate "the continuity ownership claim could not be released after the arm ended; retaining ownership"
      sleep "$IDLE_INTERVAL"
      continue
    }
    LOOP_ARM_PID=
    LOOP_ARM_IDENTITY=
    : > "$HEARTBEAT" 2>/dev/null || true
    ended=$(date +%s)
    elapsed=$((ended - started))
    reason=$(arm_output_reason "$out")

    if [ "$(hs_config_preference)" = off ]; then
      rm -f "$out" 2>/dev/null || true
      LOOP_ARM_OUT=
      if cmd_retire "config/herdr-supervisor changed to off after arming"; then
        loop_release_live
        exit 0
      fi
      sleep "$IDLE_INTERVAL"
      continue
    fi

    if [ "$rc" -eq 0 ] && [ -n "$reason" ]; then
      # The watcher already appended this wake to the durable queue before it
      # exited, so nothing is lost by re-arming immediately; delivery to the
      # model is the drain's job, not this loop's.
      failures=0
      ledger_append cycle "rc=0 elapsed=${elapsed}s $(ledger_clean_field "$reason")"
      rm -f "$out" 2>/dev/null || true
      LOOP_ARM_OUT=
      floor_delay=0
      if [ "$elapsed" -le "$RAPID_CYCLE_SECONDS" ]; then
        rapid=$((rapid + 1))
        stable_cycles=0
        [ "$previous_reason" = "$reason" ] && floor_delay=1
        if [ "$rapid" -ge "$RAPID_CYCLE_LIMIT" ]; then
          rapid_alarm_write "watcher cycles have been closing within ${RAPID_CYCLE_SECONDS}s for $rapid consecutive cycles; supervision continues on a ${RAPID_CYCLE_FLOOR}s floor while this is investigated" || true
          floor_delay=1
        fi
      else
        rapid=0
        stable_cycles=$((stable_cycles + 1))
        if [ "$stable_cycles" -ge 3 ]; then
          alarm_clear || true
        fi
      fi
      previous_reason=$reason
      if [ "$floor_delay" -eq 1 ]; then
        sleep "$RAPID_CYCLE_FLOOR"
      fi
      continue
    fi

    rapid=0
    previous_reason=
    stable_cycles=0
    floor_delay=0
    failures=$((failures + 1))
    ledger_append cycle-failed "rc=$rc elapsed=${elapsed}s attempt=$failures $(ledger_clean_field "$(head -c 400 "$out" 2>/dev/null | tr '\n' ' ')")"
    escalate "watcher arm attempt $failures failed in Herdr pane $(record_get pane || printf unknown) (rc=$rc elapsed=${elapsed}s ${reason:-no actionable reason}); bounded recovery will continue"
    rm -f "$out" 2>/dev/null || true
    LOOP_ARM_OUT=

    if [ "$failures" -ge "$RETRY_LIMIT" ]; then
      escalate "the watcher arm failed $failures consecutive times in Herdr pane $(record_get pane || printf unknown); the retry bound was reached, the continuity owner remains active, and another bounded recovery round will continue"
      ledger_append retry-bound "reached after $failures failures; continuity owner remains active"
      failures=0
      delay=$RETRY_MAX
      [ "$delay" -gt 0 ] || delay=1
      sleep "$delay"
      continue
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
