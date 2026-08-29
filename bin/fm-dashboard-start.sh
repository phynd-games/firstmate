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
# rather than starting a second server. A record whose pane is gone, whose
# health does not answer, or whose identity does not match is treated as stale:
# its pane is closed if it still exists, the record is dropped, and startup
# begins again. A port held by something that is not ours is a collision, and
# startup moves to the next candidate port rather than reporting a URL that
# belongs to another process.
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
LOG_MAX_LINES=200

FM_DASHBOARD_PORT=${FM_DASHBOARD_PORT:-8787}
FM_DASHBOARD_PORT_TRIES=${FM_DASHBOARD_PORT_TRIES:-10}
FM_DASHBOARD_READY_TRIES=${FM_DASHBOARD_READY_TRIES:-30}
FM_DASHBOARD_READY_DELAY_MS=${FM_DASHBOARD_READY_DELAY_MS:-200}
FM_DASHBOARD_LOCK_WAIT=${FM_DASHBOARD_LOCK_WAIT:-15}
FM_DASHBOARD_HERDR_TIMEOUT=${FM_DASHBOARD_HERDR_TIMEOUT:-2}
FM_DASHBOARD_HERDR_CLI=${FM_DASHBOARD_HERDR_CLI:-}

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

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"  # fm_lock_try_acquire / fm_lock_release
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"   # fm_backend_herdr_cli, via fm_backend_source
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

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
  printf '%s' "${HERDR_SESSION:-default}"
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
pane_state() {  # <pane-id>
  local out
  if [ -z "$1" ]; then printf 'unknown'; return 0; fi
  if out=$(herdr_cli pane get "$1" 2>/dev/null) \
    && printf '%s' "$out" | jq -e '.result.pane.pane_id // empty' >/dev/null 2>&1; then
    printf 'open'
    return 0
  fi
  if herdr_cli workspace list >/dev/null 2>&1; then
    printf 'gone'
  else
    printf 'unknown'
  fi
  return 0
}

pane_exists() {  # <pane-id>
  [ "$(pane_state "$1")" = open ]
}

pane_close() {  # <pane-id>
  [ -n "$1" ] || return 0
  herdr_cli pane close "$1" >/dev/null 2>&1 || return 1
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
  local port=$1
  if command -v curl >/dev/null 2>&1; then
    curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$port/healthz" 2>/dev/null
    return $?
  fi
  python3 - "$port" <<'PY' 2>/dev/null
import sys, urllib.request
try:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("http://127.0.0.1:%s/healthz" % sys.argv[1], timeout=2) as r:
        sys.stdout.write(r.read(8192).decode("utf-8", "replace"))
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

# Adopt the recorded owner when, and only when, every one of its claims still
# holds. Any single failure makes the record stale rather than usable.
record_is_live() {  # -> 0 and sets ADOPTED_PORT
  local home port pane digest health
  ADOPTED_PORT=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  [ "$(record_get schema)" = "$RECORD_SCHEMA" ] || return 1
  home=$(record_get home); [ "$home" = "$FM_HOME" ] || return 1
  port=$(record_get port); case "$port" in ''|*[!0-9]*) return 1 ;; esac
  digest=$(record_get digest); [ -n "$digest" ] || return 1
  pane=$(record_get pane); [ -n "$pane" ] || return 1
  pane_exists "$pane" || return 1
  health=$(probe_health "$port") || return 1
  health_is_ours "$health" "$digest" || return 1
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

start_pane() {  # <port> <digest> -> sets STARTED_WORKSPACE/TAB/PANE
  local port=$1 digest=$2 out ws
  STARTED_WORKSPACE=; STARTED_TAB=; STARTED_PANE=
  # Reuse the session's first workspace when it has one, so a normal firstmate
  # session gains a tab rather than a whole new workspace; create one only when
  # the session is empty.
  out=$(herdr_cli workspace list 2>/dev/null) || return 1
  ws=$(printf '%s' "$out" | jq -r '.result.workspaces[0].workspace_id // empty' 2>/dev/null)
  if [ -z "$ws" ]; then
    out=$(herdr_cli workspace create --cwd "$FM_HOME" --label firstmate-dashboard --no-focus 2>/dev/null) \
      || return 1
    ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
    [ -n "$ws" ] || return 1
  fi
  out=$(herdr_cli tab create --workspace "$ws" --cwd "$FM_HOME" \
    --label firstmate-dashboard --no-focus 2>/dev/null) || return 1
  STARTED_TAB=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  STARTED_PANE=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  [ -n "$STARTED_TAB" ] && [ -n "$STARTED_PANE" ] || return 1
  STARTED_WORKSPACE=$ws
  # `env` carries this home explicitly: the pane inherits the Herdr server's
  # environment, not this shell's, so an inherited FM_HOME cannot be assumed.
  herdr_cli pane run "$STARTED_PANE" \
    env "FM_HOME=$FM_HOME" "$SCRIPT_DIR/fm-dashboard.sh" serve \
    --port "$port" --owner-digest "$digest" >/dev/null 2>&1 || return 1
  return 0
}

await_ready() {  # <port> <digest> <pane>
  local port=$1 digest=$2 pane=$3 tries=$FM_DASHBOARD_READY_TRIES health pane_status
  while [ "$tries" -gt 0 ]; do
    if health=$(probe_health "$port") && health_is_ours "$health" "$digest"; then
      return 0
    fi
    # A pane that has already gone means the server exited; stop polling a
    # process that can never answer instead of burning the whole budget.
    pane_status=$(pane_state "$pane")
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
  local digest token port pane
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  mkdir -p "$STATE" 2>/dev/null || true

  command -v python3 >/dev/null 2>&1 \
    || { blocked "python3 is required to serve the dashboard"; return 1; }
  herdr_ready \
    || { blocked "herdr and jq are required to run the dashboard in a tracked pane"; return 1; }

  if ! fm_lock_try_acquire "$LOCK" >/dev/null 2>&1; then
    # Another start is already running. Wait for it, then report ITS result
    # rather than racing it into a second server.
    local waited=0
    while [ "$waited" -lt "$FM_DASHBOARD_LOCK_WAIT" ]; do
      sleep 1
      waited=$((waited + 1))
      if record_is_live; then
        log_line adopted "a concurrent start published port $ADOPTED_PORT"
        report_url reused "$ADOPTED_PORT"
        return 0
      fi
      fm_lock_try_acquire "$LOCK" >/dev/null 2>&1 && break
    done
    if [ "$waited" -ge "$FM_DASHBOARD_LOCK_WAIT" ]; then
      blocked "another dashboard startup held the lock for ${FM_DASHBOARD_LOCK_WAIT}s without publishing a URL"
      return 1
    fi
  fi
  # From here the lock is held; every exit path must release it.

  if record_is_live; then
    fm_lock_release "$LOCK" >/dev/null 2>&1
    log_line reused "already serving on port $ADOPTED_PORT"
    report_url reused "$ADOPTED_PORT"
    return 0
  fi

  # The record, if any, is stale: reclaim its pane before replacing it so a
  # dead-but-present pane cannot accumulate across restarts. An UNKNOWN pane is
  # not reclaimed and not discarded - starting a second server beside a pane
  # that may still be live is exactly the false claim this command must not
  # make.
  if [ -f "$RECORD" ]; then
    pane=$(record_get pane)
    case "$(pane_state "$pane")" in
      open)
        if ! pane_close "$pane"; then
          fm_lock_release "$LOCK" >/dev/null 2>&1
          blocked "the stale dashboard pane $pane could not be closed"
          return 1
        fi
        log_line reclaimed "closed the stale pane $pane"
        ;;
      gone)
        log_line stale "the recorded owner was gone"
        ;;
      *)
        fm_lock_release "$LOCK" >/dev/null 2>&1
        blocked "herdr could not confirm whether the recorded dashboard pane $pane is still running"
        return 1
        ;;
    esac
    record_drop
  fi

  token=$(mint_token)
  digest=$(digest_of "$token") || {
    fm_lock_release "$LOCK" >/dev/null 2>&1
    blocked "no SHA-256 tool is available to prove dashboard identity"
    return 1
  }

  if ! port=$(pick_port "$digest"); then
    fm_lock_release "$LOCK" >/dev/null 2>&1
    blocked "no free port in $FM_DASHBOARD_PORT_TRIES candidates from $FM_DASHBOARD_PORT"
    return 1
  fi

  if [ -n "$ADOPT_HEALTH_PORT" ]; then
    # Unreachable in practice, because a fresh token cannot match a running
    # server; kept so a future adoption path cannot silently skip readiness.
    fm_lock_release "$LOCK" >/dev/null 2>&1
    log_line adopted "an existing dashboard already owned port $port"
    report_url reused "$port"
    return 0
  fi

  if ! start_pane "$port" "$digest"; then
    [ -n "${STARTED_PANE:-}" ] && pane_close "$STARTED_PANE"
    fm_lock_release "$LOCK" >/dev/null 2>&1
    blocked "herdr could not start the dashboard pane"
    return 1
  fi

  if ! record_write "$(herdr_session)" "$STARTED_WORKSPACE" "$STARTED_TAB" \
    "$STARTED_PANE" "$port" "$token" "$digest"; then
    pane_close "$STARTED_PANE"
    fm_lock_release "$LOCK" >/dev/null 2>&1
    blocked "the dashboard owner record could not be written"
    return 1
  fi

  await_ready "$port" "$digest" "$STARTED_PANE"
  local ready_rc=$?
  if [ "$ready_rc" -ne 0 ]; then
    case "$(pane_state "$STARTED_PANE")" in
      open)
        if ! pane_close "$STARTED_PANE"; then
          fm_lock_release "$LOCK" >/dev/null 2>&1
          blocked "the dashboard was not ready and its pane could not be closed; the owner record was kept"
          return 1
        fi
        record_drop
        ;;
      gone)
        record_drop
        ;;
      *)
        fm_lock_release "$LOCK" >/dev/null 2>&1
        blocked "herdr could not confirm the dashboard pane state after readiness failed; the owner record was kept"
        return 1
        ;;
    esac
    fm_lock_release "$LOCK" >/dev/null 2>&1
    blocked "the dashboard did not become ready on port $port within the readiness budget"
    return 1
  fi

  fm_lock_release "$LOCK" >/dev/null 2>&1
  log_line started "serving on port $port in pane $STARTED_PANE"
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
  local pane
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if [ ! -f "$RECORD" ]; then
    printf 'dashboard: nothing to stop\n'
    return 0
  fi
  pane=$(record_get pane)
  case "$(pane_state "$pane")" in
    open)
      pane_close "$pane" || { blocked "herdr could not close the dashboard pane $pane"; return 1; }
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
