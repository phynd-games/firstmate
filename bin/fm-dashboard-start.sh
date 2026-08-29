#!/usr/bin/env bash
# fm-dashboard-start.sh - idempotent, identity-safe dashboard startup.
#
# Brings up the read-only control-plane dashboard (bin/fm-dashboard.sh) as a
# tracked Herdr pane and prints its verified localhost URL, so a firstmate
# session opens with the dashboard already reachable.
#
# NOT A CONTROL PLANE. This starts one local read-only viewer and nothing else.
# It never spawns, steers, merges, or tears down fleet work, and it is never a
# second control or merge authority.
#
# HERDR OWNS THE PROCESS. The server runs inside a Herdr pane created here and
# reclaimed by closing that pane. There is no tmux path and no detached
# background process: nothing is launched with `&`, nohup, or disown, so the
# process is always attributable to a pane Herdr tracks.
#
# NO FALSE URL. `FIRSTMATE_DASHBOARD_URL=` is printed only after this command
# has proven, in order: the owner record, that the listener is bound on
# 127.0.0.1, the exact port, that the pane still exists, and that the process
# answering that port is THIS dashboard for THIS home. Anything unproven prints
# `DASHBOARD_BLOCKED: <reason>` and no URL at all.
#
# IDENTITY. Startup mints a random owner token, keeps it in the 0600 owner
# record, and passes only its SHA-256 digest to the server, which republishes
# that digest on /healthz. A health answer counts as ours only when its schema,
# home, and owner digest all match. That is what separates "our dashboard" from
# "some other local process happens to hold this port", which a bare port check
# cannot tell apart.
#
# IDEMPOTENT AND RESTART-SAFE. Repeated starts, including rapid concurrent
# ones, converge on one pane: a per-home lock serializes them, and a start that
# cannot take the lock waits, re-reads the winner's record, and reports that URL
# rather than starting a second server. A record whose exact pane is gone is
# stale: the record is dropped, and startup begins
# again. A health timeout or identity mismatch is preserved and blocks
# replacement. An unknown or mismatched pane identity is preserved and blocks
# replacement. A port held by something that is not ours is a collision, and
# startup moves to the next candidate port
# rather than reporting a URL that belongs to another process.
#
# BOUNDED. Lock wait, readiness polling, port candidates, and every Herdr call
# are bounded, so a dead Herdr server or a wedged listener ends in a durable
# diagnostic instead of an unobservable loop. Nothing here retries forever and
# nothing claims recovery it did not prove.
#
# Usage:
#   fm-dashboard-start.sh ensure    start or adopt, then print the proven URL
#   fm-dashboard-start.sh status    report the current owner, changing nothing
#   fm-dashboard-start.sh stop      close the pane this home owns
#
# Durable records, all under this home's state directory:
#   .dashboard-owner       the owner record (mode 0600; holds the owner token)
#   .dashboard-start.log   bounded diagnostics, one line per attempt outcome
#   .dashboard-start.lock  the per-home startup lock
#   .dashboard-startup     in-flight startup identity journal
#   .dashboard-quarantine  durable quarantine for unresolved startup identity
#
# Tuning:
#   FM_DASHBOARD_PORT             first candidate port (default 8787)
#   FM_DASHBOARD_PORT_TRIES       candidate ports to try (default 10)
#   FM_DASHBOARD_READY_TRIES      readiness polls before giving up (default 30)
#   FM_DASHBOARD_READY_DELAY_MS   delay between readiness polls (default 200)
#   FM_DASHBOARD_LOCK_WAIT        seconds to wait for the startup lock (default 15)
#   FM_DASHBOARD_HERDR_TIMEOUT    seconds allowed for each Herdr call (default 2)
#   FM_DASHBOARD_HERDR_CLI        command prefix replacing the Herdr call (tests
#                                 and the guarded lab smoke only; it is how the
#                                 smoke routes every call through
#                                 bin/fm-herdr-lab.sh instead of the live session)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

RECORD_SCHEMA=fm-dashboard-owner.v1
HEALTH_SCHEMA=fm-dashboard-health.v1
RECORD="$STATE/.dashboard-owner"
LOG="$STATE/.dashboard-start.log"
LOCK="$STATE/.dashboard-start.lock"
QUARANTINE="$STATE/.dashboard-quarantine"
JOURNAL="$STATE/.dashboard-startup"
LOG_MAX_LINES=200

FM_DASHBOARD_PORT=${FM_DASHBOARD_PORT:-8787}
FM_DASHBOARD_PORT_TRIES=${FM_DASHBOARD_PORT_TRIES:-10}
FM_DASHBOARD_READY_TRIES=${FM_DASHBOARD_READY_TRIES:-30}
FM_DASHBOARD_READY_DELAY_MS=${FM_DASHBOARD_READY_DELAY_MS:-200}
FM_DASHBOARD_LOCK_WAIT=${FM_DASHBOARD_LOCK_WAIT:-15}
FM_DASHBOARD_HERDR_TIMEOUT=${FM_DASHBOARD_HERDR_TIMEOUT:-2}
FM_DASHBOARD_HERDR_CLI=${FM_DASHBOARD_HERDR_CLI:-}
STARTUP_TRANSACTION_ACTIVE=0
STARTUP_TRANSACTION_REASON=
STARTUP_TRANSACTION_PORT=
STARTUP_TRANSACTION_DIGEST=
START_CLEANUP_STATUS=clean
STARTED_LABEL=
STARTED_WORKSPACE_LABEL=
STARTED_TAB_LABEL=
STARTED_PANE_PARENT_WORKSPACE=
STARTED_PANE_PARENT_TAB=
STARTED_STAGE=

STARTUP_PATH_REASON=
STARTUP_HOME_REAL=$(cd "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")
startup_path_safe() {  # <path>
  local path=$1 anchor parent resolved
  STARTUP_PATH_REASON=
  [ -L "$path" ] && { STARTUP_PATH_REASON='the path is a symlink'; return 1; }
  anchor=$path
  while [ ! -e "$anchor" ] && [ ! -L "$anchor" ]; do
    case "$anchor" in ''|/) STARTUP_PATH_REASON='the path could not be resolved'; return 1 ;; esac
    parent=${anchor%/*}
    [ -n "$parent" ] || parent=/
    anchor=$parent
  done
  [ ! -L "$anchor" ] || { STARTUP_PATH_REASON='an ancestor is a symlink'; return 1; }
  if [ -e "$anchor" ] && [ ! -d "$anchor" ]; then
    parent=${anchor%/*}
    [ -n "$parent" ] || parent=/
    anchor=$parent
  fi
  [ -d "$anchor" ] || { STARTUP_PATH_REASON='the containing path is not a directory'; return 1; }
  resolved=$(cd "$anchor" 2>/dev/null && pwd -P) || {
    STARTUP_PATH_REASON='the containing path could not be resolved'; return 1; }
  case "$resolved" in
    "$STARTUP_HOME_REAL"|"$STARTUP_HOME_REAL"/*) return 0 ;;
    *) STARTUP_PATH_REASON='resolves outside this home'; return 1 ;;
  esac
}

startup_state_boundary_safe() {
  startup_path_safe "$STATE" || return 1
  startup_path_safe "$RECORD" || return 1
  startup_path_safe "$LOG" || return 1
  startup_path_safe "$LOCK" || return 1
  startup_path_safe "$QUARANTINE" || return 1
  startup_path_safe "$JOURNAL" || return 1
  return 0
}

if ! startup_state_boundary_safe; then
  printf 'DASHBOARD_BLOCKED: unsafe dashboard state boundary: %s\n' "$STARTUP_PATH_REASON"
  exit 1
fi

validate_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) printf 'fm-dashboard-start: %s must be a positive integer\n' "$1" >&2; exit 2 ;;
  esac
}
validate_bound FM_DASHBOARD_PORT "$FM_DASHBOARD_PORT"
validate_bound FM_DASHBOARD_PORT_TRIES "$FM_DASHBOARD_PORT_TRIES"
validate_bound FM_DASHBOARD_READY_TRIES "$FM_DASHBOARD_READY_TRIES"
validate_bound FM_DASHBOARD_READY_DELAY_MS "$FM_DASHBOARD_READY_DELAY_MS"
validate_bound FM_DASHBOARD_LOCK_WAIT "$FM_DASHBOARD_LOCK_WAIT"
validate_bound FM_DASHBOARD_HERDR_TIMEOUT "$FM_DASHBOARD_HERDR_TIMEOUT"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"   # fm_backend_herdr_cli, via fm_backend_source
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DASHBOARD_LOCK_HELD=0
dashboard_lock_try_acquire() {
  local pid current
  DASHBOARD_LOCK_HELD=0
  [ ! -L "$LOCK" ] || return 1
  if ! mkdir -m 700 "$LOCK" 2>/dev/null; then
    [ -d "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
    [ ! -L "$LOCK/pid" ] || return 1
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null && return 1
    rm -f -- "$LOCK/pid" 2>/dev/null || return 1
    rmdir "$LOCK" 2>/dev/null || return 1
    return 1
  fi
  [ ! -L "$LOCK/pid" ] || {
    rmdir "$LOCK" 2>/dev/null || true
    return 1
  }
  current=${BASHPID:-$$}
  printf '%s\n' "$current" > "$LOCK/pid" 2>/dev/null || {
    rm -f -- "$LOCK/pid" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
    return 1
  }
  chmod 600 "$LOCK/pid" 2>/dev/null || {
    rm -f -- "$LOCK/pid" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
    return 1
  }
  DASHBOARD_LOCK_HELD=1
  return 0
}

dashboard_lock_release() {
  local pid current
  [ "$DASHBOARD_LOCK_HELD" -eq 1 ] || return 0
  [ -d "$LOCK" ] && [ ! -L "$LOCK" ] && [ ! -L "$LOCK/pid" ] || return 0
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  current=${BASHPID:-$$}
  [ "$pid" = "$current" ] || return 0
  rm -f -- "$LOCK/pid" 2>/dev/null || return 1
  rmdir "$LOCK" 2>/dev/null || return 1
  DASHBOARD_LOCK_HELD=0
  return 0
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

now_epoch() { date +%s; }

log_line() {  # <outcome> <detail>
  local tmp
  startup_state_boundary_safe || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG" 2>/dev/null || return 0
  # Bounded: the diagnostics survive restarts without growing without limit.
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_LINES" ]; then
    tmp="$LOG.trim.$$"
    if tail -n "$LOG_MAX_LINES" "$LOG" > "$tmp" 2>/dev/null; then
      mv -f -- "$tmp" "$LOG" 2>/dev/null || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
  fi
}

blocked() {  # <reason>
  log_line blocked "$1"
  printf 'DASHBOARD_BLOCKED: %s\n' "$1"
  return 1
}

# --- herdr -----------------------------------------------------------------

herdr_session() {
  printf '%s' "${HERDR_SESSION_OVERRIDE:-${HERDR_SESSION:-default}}"
}

herdr_cli() {  # <herdr-args...>
  if [ -n "$FM_DASHBOARD_HERDR_CLI" ]; then
    # Deliberate word splitting: this is a configured command prefix, which is
    # how the guarded lab smoke routes every call through fm-herdr-lab.sh.
    # shellcheck disable=SC2086
    fm_run_timed "$FM_DASHBOARD_HERDR_TIMEOUT" $FM_DASHBOARD_HERDR_CLI "$@"
  else
    herdr_ready || return 1
    fm_run_timed "$FM_DASHBOARD_HERDR_TIMEOUT" env \
      FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$FM_ROOT}" \
      bash -c '
        . "$1"
        fm_backend_source herdr || exit 1
        shift
        session=$1
        shift
        fm_backend_herdr_cli "$session" "$@"
      ' dashboard-herdr-call "$SCRIPT_DIR/fm-backend.sh" "$(herdr_session)" "$@"
  fi
}

# Sourcing the backend is what defines fm_backend_herdr_cli, so every path that
# talks to Herdr must go through this, not just startup. status and stop reach
# Herdr too, and a silently missing CLI there would look exactly like a pane
# that had gone away.
herdr_ready() {
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$FM_DASHBOARD_HERDR_CLI" ] && return 0
  command -v herdr >/dev/null 2>&1 || return 1
  fm_backend_source herdr >/dev/null 2>&1 || return 1
  return 0
}

# open | gone | unknown. The distinction matters: a failing pane read is
# evidence the pane is gone ONLY when Herdr itself is still answering.
# Otherwise it is evidence of nothing, and treating it as "gone" would drop a
# record whose server is still live and still holding its port.
pane_state() {  # <pane-id> <session> <workspace> <tab>
  local pane=$1 session=${2:-$(herdr_session)} workspace=${3:-} tab=${4:-} out
  if [ -z "$pane" ] || [ -z "$session" ] || [ -z "$workspace" ] || [ -z "$tab" ]; then
    printf 'unknown'
    return 0
  fi
  if out=$(HERDR_SESSION_OVERRIDE="$session" herdr_cli pane get "$pane" 2>/dev/null); then
    if printf '%s' "$out" | jq -e --arg pane "$pane" --arg workspace "$workspace" --arg tab "$tab" '
      .result.pane.pane_id == $pane
      and .result.pane.workspace_id == $workspace
      and .result.pane.tab_id == $tab
    ' >/dev/null 2>&1; then
      printf 'open'
    else
      printf 'unknown'
    fi
    return 0
  fi
  if HERDR_SESSION_OVERRIDE="$session" herdr_cli workspace list >/dev/null 2>&1; then
    printf 'gone'
  else
    printf 'unknown'
  fi
  return 0
}

pane_exists() {  # <session> <workspace> <tab> <pane-id>
  [ "$(pane_state "$4" "$1" "$2" "$3")" = open ]
}

pane_close() {  # <session> <workspace> <tab> <pane-id>
  local session=$1 workspace=$2 tab=$3 pane=$4
  [ -n "$pane" ] || return 1
  [ "$(pane_state "$pane" "$session" "$workspace" "$tab")" = open ] || return 1
  HERDR_SESSION_OVERRIDE="$session" herdr_cli pane close "$pane" >/dev/null 2>&1 || return 1
  [ "$(pane_state "$pane" "$session" "$workspace" "$tab")" = gone ] || return 1
  return 0
}

# --- identity --------------------------------------------------------------

mint_token() {
  local raw
  raw=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ -n "$raw" ] || raw=$(date +%s%N)$$
  printf '%s' "$raw"
}

digest_of() {  # <token>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

# --- probes ----------------------------------------------------------------
# The health probe is what turns "a port answers" into "our dashboard for this
# home answers", so it is the only thing allowed to authorize printing a URL.

probe_health() {  # <port> -> health JSON on stdout
  local port=$1 body
  if command -v curl >/dev/null 2>&1; then
    body=$(set -o pipefail; curl --noproxy '*' -fsS --max-time 2 --max-filesize 8192 \
      "http://127.0.0.1:$port/healthz" 2>/dev/null | head -c 8193) || return 1
    [ "${#body}" -le 8192 ] || return 1
    printf '%s' "$body"
    return 0
  fi
  python3 - "$port" <<'PY' 2>/dev/null
import sys, urllib.request
try:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("http://127.0.0.1:%s/healthz" % sys.argv[1], timeout=2) as r:
        body = r.read(8193)
        if len(body) > 8192:
            sys.exit(1)
        sys.stdout.write(body.decode("utf-8", "replace"))
except Exception:
    sys.exit(1)
PY
}

health_is_ours() {  # <health-json> <digest>
  printf '%s' "$1" | jq -e \
    --arg schema "$HEALTH_SCHEMA" --arg home "$FM_HOME" --arg digest "$2" '
    .schema == $schema and .home == $home and .owner == $digest and .ready == true
  ' >/dev/null 2>&1
}

port_bindable() {  # <port> - true when 127.0.0.1:<port> is free to bind
  python3 - "$1" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
try:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

sleep_ms() {  # <milliseconds>
  perl -e 'select undef, undef, undef, $ARGV[0] / 1000' "$1" 2>/dev/null || sleep 1
}

# --- owner record ----------------------------------------------------------

record_get() {  # <key>
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | head -1
}

record_write() {  # <session> <workspace> <tab> <pane> <port> <token> <digest>
  local tmp
  startup_state_boundary_safe || return 1
  mkdir -p "$STATE" || return 1
  tmp=$(umask 077; mktemp "$STATE/.dashboard-owner.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$RECORD_SCHEMA"
    printf 'home=%s\n' "$FM_HOME"
    printf 'session=%s\n' "$1"
    printf 'workspace=%s\n' "$2"
    printf 'tab=%s\n' "$3"
    printf 'pane=%s\n' "$4"
    printf 'port=%s\n' "$5"
    printf 'token=%s\n' "$6"
    printf 'digest=%s\n' "$7"
    printf 'url=http://127.0.0.1:%s/\n' "$5"
    printf 'started=%s\n' "$(now_epoch)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

record_drop() { rm -f -- "$RECORD"; }

startup_journal_get() {  # <key>
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || return 1
  sed -n "s/^$1=//p" "$JOURNAL" 2>/dev/null | head -1
}

startup_journal_write() {
  local tmp
  startup_state_boundary_safe || return 1
  tmp=$(umask 077; mktemp "$STATE/.dashboard-startup.XXXXXX") || return 1
  {
    printf 'schema=fm-dashboard-startup.v1\n'
    printf 'label=%s\n' "${STARTED_LABEL:-}"
    printf 'workspace_label=%s\n' "${STARTED_WORKSPACE_LABEL:-}"
    printf 'tab_label=%s\n' "${STARTED_TAB_LABEL:-}"
    printf 'pane_parent_workspace=%s\n' "${STARTED_PANE_PARENT_WORKSPACE:-}"
    printf 'pane_parent_tab=%s\n' "${STARTED_PANE_PARENT_TAB:-}"
    printf 'stage=%s\n' "${STARTED_STAGE:-}"
    printf 'session=%s\n' "${STARTED_SESSION:-}"
    printf 'workspace=%s\n' "${STARTED_WORKSPACE:-}"
    printf 'workspace_id_state=%s\n' "$( [ -n "${STARTED_WORKSPACE:-}" ] && printf known || printf unknown )"
    printf 'tab=%s\n' "${STARTED_TAB:-}"
    printf 'tab_id_state=%s\n' "$( [ -n "${STARTED_TAB:-}" ] && printf known || printf unknown )"
    printf 'pane=%s\n' "${STARTED_PANE:-}"
    printf 'pane_id_state=%s\n' "$( [ -n "${STARTED_PANE:-}" ] && printf known || printf unknown )"
    printf 'port=%s\n' "${STARTUP_TRANSACTION_PORT:-}"
    printf 'digest=%s\n' "${STARTUP_TRANSACTION_DIGEST:-}"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$JOURNAL" || { rm -f -- "$tmp"; return 1; }
}

startup_journal_load() {
  [ -f "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || return 0
  [ -n "${STARTED_LABEL:-}" ] || STARTED_LABEL=$(startup_journal_get label)
  [ -n "${STARTED_WORKSPACE_LABEL:-}" ] || STARTED_WORKSPACE_LABEL=$(startup_journal_get workspace_label)
  [ -n "${STARTED_TAB_LABEL:-}" ] || STARTED_TAB_LABEL=$(startup_journal_get tab_label)
  [ -n "${STARTED_PANE_PARENT_WORKSPACE:-}" ] || STARTED_PANE_PARENT_WORKSPACE=$(startup_journal_get pane_parent_workspace)
  [ -n "${STARTED_PANE_PARENT_TAB:-}" ] || STARTED_PANE_PARENT_TAB=$(startup_journal_get pane_parent_tab)
  [ -n "${STARTED_STAGE:-}" ] || STARTED_STAGE=$(startup_journal_get stage)
  [ -n "${STARTED_SESSION:-}" ] || STARTED_SESSION=$(startup_journal_get session)
  [ -n "${STARTED_WORKSPACE:-}" ] || STARTED_WORKSPACE=$(startup_journal_get workspace)
  [ -n "${STARTED_TAB:-}" ] || STARTED_TAB=$(startup_journal_get tab)
  [ -n "${STARTED_PANE:-}" ] || STARTED_PANE=$(startup_journal_get pane)
}

startup_journal_drop() { rm -f -- "$JOURNAL"; }

quarantine_write() {  # <reason> <session> <workspace> <tab> <pane> <port> <digest>
  local tmp
  startup_state_boundary_safe || return 1
  tmp=$(umask 077; mktemp "$STATE/.dashboard-quarantine.XXXXXX") || return 1
  {
    printf 'schema=fm-dashboard-quarantine.v1\n'
    printf 'reason=%s\n' "$1"
    printf 'label=%s\n' "${STARTED_LABEL:-}"
    printf 'workspace_label=%s\n' "${STARTED_WORKSPACE_LABEL:-}"
    printf 'tab_label=%s\n' "${STARTED_TAB_LABEL:-}"
    printf 'pane_parent_workspace=%s\n' "${STARTED_PANE_PARENT_WORKSPACE:-}"
    printf 'pane_parent_tab=%s\n' "${STARTED_PANE_PARENT_TAB:-}"
    printf 'stage=%s\n' "${STARTED_STAGE:-}"
    printf 'session=%s\n' "$2"
    printf 'workspace=%s\n' "${3:-unknown}"
    printf 'workspace_id_state=%s\n' "$( [ -n "$3" ] && printf known || printf unknown )"
    printf 'tab=%s\n' "${4:-unknown}"
    printf 'tab_id_state=%s\n' "$( [ -n "$4" ] && printf known || printf unknown )"
    printf 'pane=%s\n' "${5:-unknown}"
    printf 'pane_id_state=%s\n' "$( [ -n "$5" ] && printf known || printf unknown )"
    printf 'port=%s\n' "$6"
    printf 'digest=%s\n' "$7"
    printf 'created=%s\n' "$(now_epoch)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$QUARANTINE" || { rm -f -- "$tmp"; return 1; }
}

cleanup_started() {  # <reason> <port> <digest>
  local reason=$1 port=$2 digest=$3 state
  START_CLEANUP_STATUS=clean
  startup_journal_load
  if [ -z "${STARTED_PANE:-}" ]; then
    if quarantine_write "$reason" "${STARTED_SESSION:-}" "${STARTED_WORKSPACE:-}" \
      "${STARTED_TAB:-}" "" "$port" "$digest"; then
      START_CLEANUP_STATUS=quarantined
      startup_journal_drop
    else
      START_CLEANUP_STATUS=quarantine-failed
    fi
    return 1
  fi
  state=$(pane_state "$STARTED_PANE" "${STARTED_SESSION:-}" \
    "${STARTED_WORKSPACE:-}" "${STARTED_TAB:-}")
  case "$state" in
    gone) startup_journal_drop; return 0 ;;
    open)
      pane_close "${STARTED_SESSION:-}" "${STARTED_WORKSPACE:-}" \
        "${STARTED_TAB:-}" "$STARTED_PANE" && { startup_journal_drop; return 0; }
      ;;
  esac
  if quarantine_write "$reason" "${STARTED_SESSION:-}" "${STARTED_WORKSPACE:-}" \
    "${STARTED_TAB:-}" "$STARTED_PANE" "$port" "$digest"; then
    START_CLEANUP_STATUS=quarantined
    startup_journal_drop
  else
    START_CLEANUP_STATUS=quarantine-failed
  fi
  return 1
}

startup_transaction_arm() {
  STARTUP_TRANSACTION_ACTIVE=1
  STARTUP_TRANSACTION_REASON=$1
  STARTUP_TRANSACTION_PORT=$2
  STARTUP_TRANSACTION_DIGEST=$3
}

startup_transaction_disarm() {
  STARTUP_TRANSACTION_ACTIVE=0
}

quarantine_started() {  # <reason> <port> <digest>
  startup_journal_load
  START_CLEANUP_STATUS=clean
  if quarantine_write "$1" "${STARTED_SESSION:-}" "${STARTED_WORKSPACE:-}" \
    "${STARTED_TAB:-}" "${STARTED_PANE:-}" "$2" "$3"; then
    START_CLEANUP_STATUS=quarantined
    startup_journal_drop
  else
    START_CLEANUP_STATUS=quarantine-failed
  fi
}

startup_transaction_exit() {
  local status
  if [ "$STARTUP_TRANSACTION_ACTIVE" -ne 1 ]; then
    dashboard_lock_release >/dev/null 2>&1 || true
    return 0
  fi
  STARTUP_TRANSACTION_ACTIVE=0
  quarantine_started "$STARTUP_TRANSACTION_REASON" "$STARTUP_TRANSACTION_PORT" \
    "$STARTUP_TRANSACTION_DIGEST"
  status=$START_CLEANUP_STATUS
  if [ "$status" = quarantined ]; then
    log_line blocked "startup interrupted; cleanup quarantined at $QUARANTINE"
  elif [ "$status" = quarantine-failed ]; then
    log_line blocked "startup interrupted; cleanup could not be durably quarantined"
  else
    log_line blocked "startup interrupted before ownership was published"
  fi
  dashboard_lock_release >/dev/null 2>&1 || true
}

startup_transaction_signal() {
  trap - INT TERM
  startup_transaction_exit
  if [ "$START_CLEANUP_STATUS" = quarantined ]; then
    printf 'DASHBOARD_BLOCKED: startup was interrupted; cleanup was quarantined at %s\n' "$QUARANTINE"
  elif [ "$START_CLEANUP_STATUS" = quarantine-failed ]; then
    printf 'DASHBOARD_BLOCKED: startup was interrupted; cleanup could not be durably quarantined\n'
  else
    printf 'DASHBOARD_BLOCKED: startup was interrupted before ownership was published\n'
  fi
  exit 1
}

trap startup_transaction_exit EXIT
trap startup_transaction_signal INT TERM

# Adopt the recorded owner when, and only when, every one of its claims still
# holds. An unknown identity is retained rather than treated as stale.
record_is_live() {  # -> 0 and sets ADOPTED_PORT
  local home session workspace tab port pane digest health
  ADOPTED_PORT=
  RECORD_PROBE_STATE=invalid
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  [ "$(record_get schema)" = "$RECORD_SCHEMA" ] || return 1
  home=$(record_get home); [ "$home" = "$FM_HOME" ] || return 1
  session=$(record_get session); [ -n "$session" ] || return 1
  workspace=$(record_get workspace); [ -n "$workspace" ] || return 1
  tab=$(record_get tab); [ -n "$tab" ] || return 1
  port=$(record_get port); case "$port" in ''|*[!0-9]*) return 1 ;; esac
  digest=$(record_get digest); [ -n "$digest" ] || return 1
  pane=$(record_get pane); [ -n "$pane" ] || return 1
  RECORD_PROBE_STATE=$(pane_state "$pane" "$session" "$workspace" "$tab")
  case "$RECORD_PROBE_STATE" in
    gone) return 1 ;;
    open) ;;
    *) return 1 ;;
  esac
  health=$(probe_health "$port") || { RECORD_PROBE_STATE=unknown; return 1; }
  health_is_ours "$health" "$digest" || { RECORD_PROBE_STATE=unknown; return 1; }
  [ "$(pane_state "$pane" "$session" "$workspace" "$tab")" = open ] \
    || { RECORD_PROBE_STATE=unknown; return 1; }
  RECORD_PROBE_STATE=live
  ADOPTED_PORT=$port
  return 0
}

# --- startup ---------------------------------------------------------------

# Choose a port this home can actually own. A port that answers as ours is
# adopted; a port that answers as anything else is a collision and is skipped
# rather than claimed.
ADOPT_HEALTH_PORT=
pick_port() {  # <digest> -> prints the chosen port
  local digest=$1 port=$FM_DASHBOARD_PORT tries=$FM_DASHBOARD_PORT_TRIES health
  ADOPT_HEALTH_PORT=
  while [ "$tries" -gt 0 ]; do
    if health=$(probe_health "$port"); then
      if health_is_ours "$health" "$digest"; then
        ADOPT_HEALTH_PORT=$port
        printf '%s' "$port"
        return 0
      fi
      log_line collision "port $port is held by another listener"
    elif port_bindable "$port"; then
      printf '%s' "$port"
      return 0
    else
      log_line collision "port $port is held by a non-http listener"
    fi
    port=$((port + 1))
    tries=$((tries - 1))
  done
  return 1
}

recover_workspace() {  # <label>
  local label=$1 out
  out=$(herdr_cli workspace list 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er --arg label "$label" '
    [.result.workspaces[]? | select(.label == $label) | .workspace_id]
    | select(length == 1) | .[0]'
}

recover_tab() {  # <workspace> <label>
  local workspace=$1 label=$2 out
  out=$(herdr_cli tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er --arg label "$label" '
    [.result.tabs[]? | select(.label == $label) | .tab_id]
    | select(length == 1) | .[0]'
}

recover_pane() {  # <workspace> <tab>
  local workspace=$1 tab=$2 out
  out=$(herdr_cli pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er --arg tab "$tab" '
    [.result.panes[]? | select(.tab_id == $tab) | .pane_id]
    | select(length == 1) | .[0]'
}

start_pane() {  # <port> <digest> -> sets STARTED_WORKSPACE/TAB/PANE
  local port=$1 digest=$2 out ws label
  label="firstmate-dashboard-$digest"
  STARTED_SESSION=$(herdr_session)
  STARTED_LABEL=$label
  STARTED_WORKSPACE_LABEL=$label
  STARTED_TAB_LABEL=$label
  STARTED_PANE_PARENT_WORKSPACE=
  STARTED_PANE_PARENT_TAB=
  STARTED_STAGE=workspace-list
  STARTED_WORKSPACE=; STARTED_TAB=; STARTED_PANE=
  startup_journal_write || return 1
  # Reuse the session's first workspace when it has one, so a normal firstmate
  # session gains a tab rather than a whole new workspace; create one only when
  # the session is empty.
  out=$(herdr_cli workspace list 2>/dev/null) || return 1
  ws=$(printf '%s' "$out" | jq -r '.result.workspaces[0].workspace_id // empty' 2>/dev/null)
  if [ -z "$ws" ]; then
    STARTED_STAGE=workspace-create
    startup_journal_write || return 1
    out=$(herdr_cli workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null) || :
    ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
    [ -n "$ws" ] || ws=$(recover_workspace "$label") || return 1
  fi
  STARTED_WORKSPACE=$ws
  STARTED_STAGE=tab-create
  STARTED_PANE_PARENT_WORKSPACE=$ws
  startup_journal_write || return 1
  out=$(herdr_cli tab create --workspace "$ws" --cwd "$FM_HOME" \
    --label "$label" --no-focus 2>/dev/null) || :
  STARTED_TAB=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  STARTED_PANE=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  STARTED_PANE_PARENT_TAB=${STARTED_TAB:-}
  STARTED_STAGE=tab-response
  startup_journal_write || return 1
  [ -n "$STARTED_TAB" ] || STARTED_TAB=$(recover_tab "$ws" "$label") || return 1
  STARTED_PANE_PARENT_TAB=$STARTED_TAB
  STARTED_STAGE=pane-response
  startup_journal_write || return 1
  [ -n "$STARTED_PANE" ] || STARTED_PANE=$(recover_pane "$ws" "$STARTED_TAB") || return 1
  STARTED_STAGE=pane-run
  startup_journal_write || return 1
  # `env` carries this home explicitly: the pane inherits the Herdr server's
  # environment, not this shell's, so an inherited FM_HOME cannot be assumed.
  herdr_cli pane run "$STARTED_PANE" \
    env "FM_HOME=$FM_HOME" "$SCRIPT_DIR/fm-dashboard.sh" serve \
    --port "$port" --owner-digest "$digest" >/dev/null 2>&1 || return 1
  return 0
}

await_ready() {  # <port> <digest> <session> <workspace> <tab> <pane>
  local port=$1 digest=$2 session=$3 workspace=$4 tab=$5 pane=$6
  local tries=$FM_DASHBOARD_READY_TRIES health pane_status
  while [ "$tries" -gt 0 ]; do
    if health=$(probe_health "$port") && health_is_ours "$health" "$digest" \
      && [ "$(pane_state "$pane" "$session" "$workspace" "$tab")" = open ]; then
      return 0
    fi
    # A pane that has already gone means the server exited; stop polling a
    # process that can never answer instead of burning the whole budget.
    pane_status=$(pane_state "$pane" "$session" "$workspace" "$tab")
    case "$pane_status" in
      open) ;;
      gone) return 1 ;;
      *) return 2 ;;
    esac
    sleep_ms "$FM_DASHBOARD_READY_DELAY_MS"
    tries=$((tries - 1))
  done
  return 1
}

# The human line names which of the two outcomes happened, because "I started
# it" and "it was already running" are different facts to a reader, and the
# machine-readable URL line is byte-identical either way.
report_url() {  # <started|reused> <port>
  case "$1" in
    started) printf 'dashboard: started on 127.0.0.1 (read-only)\n' ;;
    *) printf 'dashboard: already running on 127.0.0.1 (read-only)\n' ;;
  esac
  printf 'FIRSTMATE_DASHBOARD_URL=http://127.0.0.1:%s/\n' "$2"
}

command_ensure() {
  local digest token port pane session workspace tab
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  startup_state_boundary_safe \
    || { blocked "unsafe dashboard state boundary: $STARTUP_PATH_REASON"; return 1; }
  mkdir -p "$STATE" 2>/dev/null \
    || { blocked "the dashboard state directory could not be created"; return 1; }
  startup_state_boundary_safe \
    || { blocked "unsafe dashboard state boundary: $STARTUP_PATH_REASON"; return 1; }

  command -v python3 >/dev/null 2>&1 \
    || { blocked "python3 is required to serve the dashboard"; return 1; }
  herdr_ready \
    || { blocked "herdr and jq are required to run the dashboard in a tracked pane"; return 1; }

  if ! dashboard_lock_try_acquire >/dev/null 2>&1; then
    # Another start is already running. Wait for it, then report ITS result
    # rather than racing it into a second server.
    local waited=0 lock_acquired=0
    while [ "$waited" -lt "$FM_DASHBOARD_LOCK_WAIT" ]; do
      sleep 1
      waited=$((waited + 1))
      if record_is_live; then
        log_line adopted "a concurrent start published port $ADOPTED_PORT"
        report_url reused "$ADOPTED_PORT"
        return 0
      fi
      if dashboard_lock_try_acquire >/dev/null 2>&1; then
        lock_acquired=1
        break
      fi
    done
    if [ "$lock_acquired" -ne 1 ]; then
      blocked "another dashboard startup held the lock for ${FM_DASHBOARD_LOCK_WAIT}s without publishing a URL"
      return 1
    fi
  fi
  # From here the lock is held; every exit path must release it.

  if [ -e "$QUARANTINE" ] || [ -e "$JOURNAL" ]; then
    dashboard_lock_release >/dev/null 2>&1
    blocked "dashboard startup has unresolved ownership; inspect $QUARANTINE or $JOURNAL before retrying"
    return 1
  fi

  if record_is_live; then
    dashboard_lock_release >/dev/null 2>&1
    log_line reused "already serving on port $ADOPTED_PORT"
    report_url reused "$ADOPTED_PORT"
    return 0
  fi

  if [ -f "$RECORD" ]; then
    case "$RECORD_PROBE_STATE" in
      gone)
        pane=$(record_get pane)
        log_line stale "the recorded pane $pane was gone"
        record_drop
        ;;
      *)
        dashboard_lock_release >/dev/null 2>&1
        blocked "the recorded dashboard owner could not be re-proven; its ownership record was kept"
        return 1
        ;;
    esac
  fi

  token=$(mint_token)
  digest=$(digest_of "$token") || {
    dashboard_lock_release >/dev/null 2>&1
    blocked "no SHA-256 tool is available to prove dashboard identity"
    return 1
  }

  if ! port=$(pick_port "$digest"); then
    dashboard_lock_release >/dev/null 2>&1
    blocked "no free port in $FM_DASHBOARD_PORT_TRIES candidates from $FM_DASHBOARD_PORT"
    return 1
  fi

  if [ -n "$ADOPT_HEALTH_PORT" ]; then
    # Unreachable in practice, because a fresh token cannot match a running
    # server; kept so a future adoption path cannot silently skip readiness.
    dashboard_lock_release >/dev/null 2>&1
    log_line adopted "an existing dashboard already owned port $port"
    report_url reused "$port"
    return 0
  fi

  startup_transaction_arm "dashboard launch was not fully published" "$port" "$digest"
  if ! start_pane "$port" "$digest"; then
    cleanup_started "herdr could not start the dashboard pane" "$port" "$digest" || true
    startup_transaction_disarm
    dashboard_lock_release >/dev/null 2>&1
    if [ "$START_CLEANUP_STATUS" = quarantined ]; then
      blocked "herdr could not start the dashboard pane; cleanup was quarantined at $QUARANTINE"
    elif [ "$START_CLEANUP_STATUS" = quarantine-failed ]; then
      blocked "herdr could not start the dashboard pane; cleanup could not be durably quarantined"
    else
      blocked "herdr could not start the dashboard pane"
    fi
    return 1
  fi

  if ! record_write "$STARTED_SESSION" "$STARTED_WORKSPACE" "$STARTED_TAB" \
    "$STARTED_PANE" "$port" "$token" "$digest"; then
    cleanup_started "the dashboard owner record could not be written" "$port" "$digest" || true
    startup_transaction_disarm
    dashboard_lock_release >/dev/null 2>&1
    if [ "$START_CLEANUP_STATUS" = quarantined ]; then
      blocked "the dashboard owner record could not be written; cleanup was quarantined at $QUARANTINE"
    elif [ "$START_CLEANUP_STATUS" = quarantine-failed ]; then
      blocked "the dashboard owner record could not be written; cleanup could not be durably quarantined"
    else
      blocked "the dashboard owner record could not be written"
    fi
    return 1
  fi

  startup_transaction_disarm
  startup_journal_drop

  await_ready "$port" "$digest" "$STARTED_SESSION" "$STARTED_WORKSPACE" \
    "$STARTED_TAB" "$STARTED_PANE"
  local ready_rc=$?
  if [ "$ready_rc" -ne 0 ]; then
    case "$(pane_state "$STARTED_PANE" "$STARTED_SESSION" \
      "$STARTED_WORKSPACE" "$STARTED_TAB")" in
      open)
        dashboard_lock_release >/dev/null 2>&1
        blocked "the dashboard was not ready and its pane is still open; the owner record was kept"
        return 1
        ;;
      gone)
        record_drop
        ;;
      *)
        dashboard_lock_release >/dev/null 2>&1
        blocked "herdr could not confirm the dashboard pane state after readiness failed; the owner record was kept"
        return 1
        ;;
    esac
    dashboard_lock_release >/dev/null 2>&1
    blocked "the dashboard did not become ready on port $port within the readiness budget"
    return 1
  fi

  dashboard_lock_release >/dev/null 2>&1
  log_line started "serving on port $port in pane $STARTED_PANE"
  if ! record_is_live || [ "$ADOPTED_PORT" != "$port" ]; then
    blocked "the dashboard owner could not be re-proven immediately before URL publication"
    return 1
  fi
  report_url started "$port"
  return 0
}

command_status() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if [ -L "$RECORD" ]; then
    printf 'DASHBOARD_BLOCKED: the dashboard owner record is a symlink and was not read\n'
    return 1
  fi
  if [ ! -f "$RECORD" ]; then
    printf 'dashboard: no owner recorded for this home\n'
    return 0
  fi
  printf 'dashboard: recorded owner\n'
  # -E: BSD sed has no BRE alternation, so the portable form is ERE.
  # The owner token is deliberately not among the printed keys.
  sed -nE 's/^(schema|home|session|workspace|tab|pane|port|url|started)=/  \1: /p' "$RECORD"
  if record_is_live; then
    printf '  live: yes\n'
    printf 'FIRSTMATE_DASHBOARD_URL=http://127.0.0.1:%s/\n' "$ADOPTED_PORT"
  else
    printf '  live: no - the recorded owner could not be proven\n'
  fi
  return 0
}

command_stop() {
  local pane session workspace tab
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if [ -L "$RECORD" ]; then
    blocked "the dashboard owner record is a symlink and was not read"
    return 1
  fi
  if [ -e "$JOURNAL" ]; then
    blocked "dashboard startup has unresolved ownership; the owner record was kept"
    return 1
  fi
  if [ ! -f "$RECORD" ]; then
    printf 'dashboard: nothing to stop\n'
    return 0
  fi
  if ! record_is_live; then
    blocked "the recorded dashboard owner could not be fully proven; the owner record was kept"
    return 1
  fi
  session=$(record_get session)
  workspace=$(record_get workspace)
  tab=$(record_get tab)
  pane=$(record_get pane)
  case "$(pane_state "$pane" "$session" "$workspace" "$tab")" in
    open)
      pane_close "$session" "$workspace" "$tab" "$pane" \
        || { blocked "herdr could not close the dashboard pane $pane"; return 1; }
      log_line stopped "closed pane $pane"
      printf 'dashboard: stopped\n'
      ;;
    gone)
      log_line stopped "the recorded pane was already gone"
      printf 'dashboard: the recorded pane was already gone\n'
      ;;
    *)
      # Dropping the record here would orphan a server that may still be
      # holding its port, with nothing left pointing at it.
      blocked "herdr could not confirm whether the dashboard pane $pane is still running; the record was kept"
      return 1
      ;;
  esac
  record_drop
  return 0
}

case "${1-}" in
  ensure) shift; command_ensure "$@" ;;
  status) shift; command_status "$@" ;;
  stop) shift; command_stop "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
