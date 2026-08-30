#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background), or - for a Claude
# primary - inside the Stop asyncRewake hook's foreground process tree
# (bin/fm-claude-stop-autoarm.sh), where the harness owns the process group and
# the hook's exit-2 rewake is the notification. Run it as its own standalone
# background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - a live+fresh successor holds the lock;
#                                                          this arm attaches and follows it
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - cycle ended without an actionable reason
#                                                        - a clean cycle ended with no wake and no
#                                                          verified healthy successor
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it waits the child and propagates the wake
# reason; on attached it stays live across identity-matched successors. A cycle
# that ends with no reason line and no healthy successor is resolved against the
# watcher's identity-bound delivery record: a matching record reports that wake
# and exits 0, and only a cycle that delivered nothing is the typed nonzero
# failure. Neither is ever a clean empty completion. On FAILED it exits non-zero
# so the failure is loud. A live cycle already present means re-arm attaches - do
# not start a second watcher.
#
# Every observed watcher cycle appends one tab-separated lifecycle record to
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/watcher identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, and successor disposition. The separate
# state/.watch-triage.log remains exclusively the watcher's absorbed-wake debug
# log and is never written here.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or attach if a verified live peer
# wins the singleton while the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
# Git Bash/MSYS pays a much higher fork cost while the watcher completes its
# required pre-lock migration, so its bounded default covers that cold start.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) ARM_CONFIRM_DEFAULT=30 ;;
  *) ARM_CONFIRM_DEFAULT=10 ;;
esac
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-$ARM_CONFIRM_DEFAULT}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
CYCLE_LOG_LOCK="$STATE/.watch-cycle-exits.lock"
CYCLE_LOG_MAX_BYTES=${FM_WATCH_CYCLE_LOG_MAX_BYTES:-262144}
CYCLE_LOG_KEEP_LINES=${FM_WATCH_CYCLE_LOG_KEEP_LINES:-1000}
ARM_PID=${BASHPID:-$$}
case "$CYCLE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) CYCLE_LOG_MAX_BYTES=262144 ;; esac
case "$CYCLE_LOG_KEEP_LINES" in ''|*[!0-9]*|0) CYCLE_LOG_KEEP_LINES=1000 ;; esac

# The lifecycle ledger is diagnostic evidence, not a supervision dependency.
# Writes are bounded and best-effort so an observability failure cannot stall an
# otherwise healthy watcher cycle.
cycle_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-512
}

lock_snapshot() {
  local pid identity
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  printf 'pid:%s|identity:%s' "$(cycle_clean_field "${pid:-none}")" "$(cycle_clean_field "${identity:-none}")"
}

WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
ARM_BLOCKED="$STATE/.watch-arm-blocked"

ARM_CLAIM_HELD=0
if [ "${FM_WATCH_ARM_CLAIM_REQUIRED:-0}" = 1 ]; then
  if ! fm_supervision_claim_acquire "$STATE/.supervision-claim.lock" "${FM_WATCH_ARM_CLAIM_TRIES:-100}"; then
    echo "watcher: FAILED - Pi arm could not acquire the shared continuity claim" >&2
    exit 125
  fi
  ARM_CLAIM_HELD=1
fi

arm_release_claim() {
  if [ "$ARM_CLAIM_HELD" -eq 1 ]; then
    fm_lock_release "$STATE/.supervision-claim.lock" || true
    ARM_CLAIM_HELD=0
  fi
}

arm_blocked_write() {
  local reason=$1 tmp
  tmp=$(mktemp "$ARM_BLOCKED.tmp.XXXXXX") || return 1
  if ! {
    printf 'pid=%s\nidentity=%s\nat=%s\nreason=%s\n' \
      "$ARM_PID" "${child_identity:-unknown}" "$(date +%s)" "$reason"
  } > "$tmp" 2>/dev/null || ! chmod 0600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$ARM_BLOCKED" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

arm_blocked_clear() {
  rm -f "$ARM_BLOCKED" 2>/dev/null || true
}

cycle_active=0
cycle_watcher_pid=none
cycle_watcher_identity=none
cycle_origin=unknown
cycle_started_at=0
cycle_lock_before='pid:none|identity:none'

cycle_begin() {
  cycle_watcher_pid=$1
  cycle_origin=$2
  cycle_watcher_identity=$3
  cycle_started_at=$(date +%s)
  cycle_lock_before=$(lock_snapshot)
  cycle_active=1
}

cycle_refresh_lock_before() {
  [ "$cycle_active" -eq 1 ] || return 0
  if [ "$HEALTHY_PID" = "$cycle_watcher_pid" ] && [ -n "$HEALTHY_IDENTITY" ]; then
    cycle_watcher_identity=$HEALTHY_IDENTITY
  fi
  cycle_lock_before=$(lock_snapshot)
}

cycle_signal_name() {
  local rc=$1 signal_number
  case "$rc" in
    ''|*[!0-9]*) printf 'unknown'; return ;;
  esac
  [ "$rc" -gt 128 ] || { printf 'none'; return; }
  signal_number=$((rc - 128))
  kill -l "$signal_number" 2>/dev/null || printf '%s' "$signal_number"
}

cycle_log_append() {
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after size tmp raw i
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)

  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\tsuccessor=%s\n' \
    "$ARM_PID" \
    "$(cycle_clean_field "$cycle_watcher_pid")" \
    "$(cycle_clean_field "$cycle_origin")" \
    "$cycle_started_at" \
    "$ended_at" \
    "$(cycle_clean_field "$exit_code")" \
    "$(cycle_clean_field "$signal")" \
    "$(cycle_clean_field "$reason")" \
    "$beacon_age" \
    "$(cycle_clean_field "$cycle_lock_before")" \
    "$(cycle_clean_field "$lock_after")" \
    "$(cycle_clean_field "$successor")" >> "$CYCLE_LOG" 2>/dev/null || true

  size=$(wc -c < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$CYCLE_LOG_MAX_BYTES" ]; then
        tmp="$CYCLE_LOG.tmp.$ARM_PID"
        raw="$tmp.raw"
        tail -n "$CYCLE_LOG_KEEP_LINES" "$CYCLE_LOG" 2>/dev/null \
          | tail -c "$CYCLE_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^arm_pid=/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$CYCLE_LOG_LOCK"
  cycle_active=0
}

# A persistent adapter passes the arm pid that just closed. Once this new arm
# verifies its watcher, update that predecessor's final record in place so the
# one-record-per-cycle ledger captures the actual successor outcome without an
# extra synthetic lifecycle row.
cycle_mark_predecessor_successor() {
  local successor=$1 predecessor=${FM_WATCH_PREDECESSOR_ARM_PID:-} i tmp
  case "$predecessor" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  tmp="$CYCLE_LOG.link.$ARM_PID"
  awk -v target="arm_pid=$predecessor" -v replacement="successor=$(cycle_clean_field "$successor")" '
    {
      lines[NR] = $0
      count = split($0, fields, "\t")
      if (fields[1] == target) {
        for (i = 1; i <= count; i += 1) {
          if (fields[i] == "successor=none") last = NR
        }
      }
    }
    END {
      for (i = 1; i <= NR; i += 1) {
        if (i == last) sub(/\tsuccessor=none$/, "\t" replacement, lines[i])
        print lines[i]
      }
    }
  ' "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$CYCLE_LOG_LOCK"
}

restart_recorded_watcher_lock() {
  local lock_home lock_path lock_pid lock_identity current_identity expected_pid expected_identity reclaim final_pid final_identity final_current_identity rc=0
  expected_pid=${FM_WATCH_RESTART_EXPECTED_PID:-}
  expected_identity=${FM_WATCH_RESTART_EXPECTED_IDENTITY:-}
  reclaim=${FM_WATCH_RESTART_RECLAIM:-auto}
  fm_lock_try_acquire "$WATCH_LOCK.steal" || return 1
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  if [ ! -e "$WATCH_LOCK" ] && [ ! -L "$WATCH_LOCK" ]; then
    rc=0
  elif [ "$lock_home" != "$FM_HOME" ] || [ "$lock_path" != "$WATCH" ] \
    || { [ -z "$lock_identity" ] && fm_pid_alive "$lock_pid"; }; then
    rc=1
  elif [ -n "$expected_pid" ] && {
    [ "$lock_pid" != "$expected_pid" ] || [ "$lock_identity" != "$expected_identity" ];
  }; then
    rc=3
  else
    current_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null || printf '')
    if [ -n "$expected_pid" ] && [ "$lock_pid" != "$expected_pid" ]; then
      rc=3
    elif [ -n "$expected_pid" ] && [ "$lock_identity" != "$expected_identity" ]; then
      rc=3
    elif [ "$reclaim" = auto ]; then
      if fm_pid_alive "$lock_pid"; then
        [ -n "$current_identity" ] || rc=1
        [ "$current_identity" = "$lock_identity" ] && reclaim=0 || reclaim=1
      else
        reclaim=0
      fi
    fi
    if [ "$rc" -eq 0 ] && [ -n "$expected_pid" ] && [ "$reclaim" = 1 ]; then
      if fm_pid_alive "$lock_pid" \
        && { [ -z "$current_identity" ] || [ "$current_identity" = "$lock_identity" ]; }; then
        rc=1
      fi
    elif [ "$reclaim" = 1 ]; then
      :
    elif [ -n "$expected_pid" ] && [ -z "$current_identity" ] && fm_pid_alive "$lock_pid"; then
      rc=1
    elif [ "$reclaim" = 0 ] \
      && fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" \
      && [ "$FM_WATCHER_HEALTHY_PID" = "$lock_pid" ] \
      && [ "$FM_WATCHER_HEALTHY_IDENTITY" = "$lock_identity" ]; then
      rc=4
    elif fm_pid_alive "$lock_pid"; then
      if [ "$current_identity" = "$lock_identity" ]; then
        kill -TERM "$lock_pid" 2>/dev/null || true
        i=0
        while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
          sleep 0.1
          i=$((i + 1))
        done
      else
        rc=1
      fi
    fi
    if [ "$rc" -eq 0 ] && { [ -e "$WATCH_LOCK" ] || [ -L "$WATCH_LOCK" ]; }; then
      final_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
      final_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
      final_current_identity=$(fm_pid_identity "$final_pid" 2>/dev/null || printf '')
      [ "$final_pid" = "$lock_pid" ] || rc=3
      [ "$final_identity" = "$lock_identity" ] || rc=3
      if [ "$reclaim" = 1 ]; then
        if fm_pid_alive "$final_pid"; then
          [ -n "$final_current_identity" ] && [ "$final_current_identity" != "$final_identity" ] || rc=1
        fi
      else
        fm_pid_alive "$final_pid" && rc=1
      fi
    fi
    if [ "$rc" -eq 0 ] && { [ -e "$WATCH_LOCK" ] || [ -L "$WATCH_LOCK" ]; }; then
      if ! fm_recovery_transition "$STATE/.watcher-down" clear-stale-lock "$WATCH_LOCK" downtime "$lock_pid" "$lock_identity" 1; then
        rc=1
      fi
    fi
  fi
  fm_lock_release "$WATCH_LOCK.steal"
  [ "$rc" -eq 0 ] || return "$rc"
  [ ! -e "$WATCH_LOCK" ] && [ ! -L "$WATCH_LOCK" ]
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
HEALTHY_IDENTITY=
healthy_watcher() {
  HEALTHY_PID=
  HEALTHY_IDENTITY=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
  HEALTHY_IDENTITY=$FM_WATCHER_HEALTHY_IDENTITY
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

# Give a successor the same bounded confirmation window used for a fresh child.
# Adapter-owned continuations normally win immediately, but the bound avoids a
# false failure when process-close delivery and lock publication cross briefly.
wait_for_healthy_successor() {
  local deadline
  # date(1) exposes whole seconds. Add one rounding second so a timeout of one
  # second cannot collapse to a few milliseconds when called near a boundary.
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  while :; do
    healthy_watcher && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

fail_unexplained_cycle() {
  echo "watcher: FAILED - cycle ended without an actionable reason"
  return 1
}

# Close a cycle whose reason line this arm could not read against the bounded
# terminal-delivery ledger the watcher publishes before releasing its lock.
close_unobserved_cycle() {
  local i reason clean_identity record_pid record_identity record_reason
  clean_identity=$(printf '%s' "$cycle_watcher_identity" | tr '\t\r\n' '   ')
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || {
      fail_unexplained_cycle
      return 1
    }
    sleep 0.02
    i=$((i + 1))
  done
  reason=
  if [ -f "$WATCH_DELIVERY_LOG" ]; then
    while IFS=$'\t' read -r record_pid record_identity record_reason; do
      if [ "$record_pid" = "$cycle_watcher_pid" ] && [ "$record_identity" = "$clean_identity" ]; then
        reason=$record_reason
      fi
    done < "$WATCH_DELIVERY_LOG"
  fi
  fm_lock_release "$WATCH_DELIVERY_LOCK"
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason"
    return 0
  fi
  fail_unexplained_cycle
  return 1
}

# Stay alive across identity-matched healthy holders. If one cycle ends, attach
# to a verified successor. With no successor, report the wake that cycle durably
# delivered, or fail loudly - never a clean empty completion that an adapter could
# mistake for a no-op.
attach_and_wait() {
  local attached_pid=$1
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ] || [ "$HEALTHY_IDENTITY" != "$cycle_watcher_identity" ]; then
        cycle_log_append unknown unknown lock-replaced "attached:$HEALTHY_PID"
        attached_pid=$HEALTHY_PID
        cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      cycle_log_append unknown unknown attached-cycle-ended "attached:$HEALTHY_PID"
      attached_pid=$HEALTHY_PID
      cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
      report_attached
      continue
    fi
    if close_unobserved_cycle; then
      cycle_log_append unknown unknown attached-delivered-wake none
      return 0
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    return 1
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_attached_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  exit "$rc"
}

trap 'handle_attached_signal HUP 129' HUP
trap 'handle_attached_signal TERM 143' TERM
trap 'handle_attached_signal INT 130' INT

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

watch_output_reason_type() {
  local out=$1 line
  line=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$line" in
    signal:*) printf 'actionable-signal' ;;
    stale:*) printf 'actionable-stale' ;;
    check:*) printf 'actionable-check' ;;
    heartbeat*) printf 'actionable-heartbeat' ;;
    *) printf 'none' ;;
  esac
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

handling_successor_generation() {
  [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] || return 0
  fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 1
  case "$FM_RECOVERY_MARKER_TOKEN" in
    pending:downtime:*|pending:handling:*|announced:downtime:*|announced:handling:*) printf '%s' "${FM_RECOVERY_MARKER_TOKEN##*:}" ;;
    acked:*|'') ;;
    *) return 1 ;;
  esac
}

mode=arm
handling_generation=
handling_watcher_pid=
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  --handling-delivered)
    mode=handling-delivered
    handling_generation=${2:-}
    [ "${3:-}" = --watcher-pid ] || { echo "watcher: invalid handling delivery confirmation" >&2; exit 2; }
    handling_watcher_pid=${4:-}
    case "$handling_generation" in ''|*[!A-Za-z0-9._-]*) echo "watcher: invalid recovery generation" >&2; exit 2 ;; esac
    case "$handling_watcher_pid" in ''|*[!0-9]*) echo "watcher: invalid successor watcher pid" >&2; exit 2 ;; esac
    [ "$#" -eq 4 ] || { echo "watcher: unexpected handling delivery arguments" >&2; exit 2; }
    ;;
  *) echo "usage: $(basename "$0") [--restart | --handling-delivered GENERATION --watcher-pid PID]" >&2; exit 2 ;;
esac

if [ "$mode" = handling-delivered ]; then
  fm_pid_alive "$handling_watcher_pid" \
    && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$handling_watcher_pid" "$FM_HOME" \
    && fm_recovery_marker_begin_handling "$STATE/.watcher-down" "$handling_generation"
  exit $?
fi

if [ "$mode" = restart ]; then
  restart_recorded_watcher_lock
  clear_rc=$?
  if [ "$clear_rc" -eq 3 ]; then
    echo "watcher: FAILED - a successor watcher won the stale-lock handoff" >&2
    exit 1
  fi
  if [ "$clear_rc" -eq 4 ]; then
    mode=arm
  fi
  if [ "$clear_rc" -ne 0 ] && [ "$clear_rc" -ne 4 ]; then
    echo "watcher: FAILED - stale watcher recovery state could not be persisted" >&2
    exit 1
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
  cycle_begin "$HEALTHY_PID" attached "$HEALTHY_IDENTITY"
  report_attached
  attach_and_wait "$HEALTHY_PID"
  exit $?
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_out=
child_identity=
child_status() {
  local process_state
  fm_pid_alive "$child" || return 0
  process_state=$(ps -o stat= -p "$child" 2>/dev/null | tr -d '[:space:]')
  [ -n "$process_state" ] || return 2
  [[ "$process_state" == Z* ]] && return 0
  return 1
}
stop_child_bounded() {
  local current i=0 status
  [ -n "$child" ] || return 0
  child_status
  status=$?
  case "$status" in
    0) wait "$child" 2>/dev/null || true; return 0 ;;
    2) return 1 ;;
  esac
  current=$(fm_pid_identity "$child" 2>/dev/null || true)
  [ -n "$child_identity" ] && [ -n "$current" ] && [ "$current" = "$child_identity" ] || return 1
  kill -TERM "$child" 2>/dev/null || true
  while [ "$i" -lt 20 ]; do
    child_status
    status=$?
    [ "$status" -eq 0 ] && break
    if [ "$status" -eq 2 ]; then
      sleep 0.05
      i=$((i + 1))
      continue
    fi
    sleep 0.05
    i=$((i + 1))
  done
  child_status
  status=$?
  if [ "$status" -eq 2 ]; then
    return 1
  fi
  if [ "$status" -eq 1 ]; then
    current=$(fm_pid_identity "$child" 2>/dev/null || true)
    [ -n "$child_identity" ] && [ -n "$current" ] && [ "$current" = "$child_identity" ] || return 1
    kill -KILL "$child" 2>/dev/null || true
    i=0
    while [ "$i" -lt 20 ]; do
      child_status
      status=$?
      [ "$status" -eq 0 ] && break
      if [ "$status" -eq 2 ]; then
        sleep 0.05
        i=$((i + 1))
        continue
      fi
      sleep 0.05
      i=$((i + 1))
    done
  fi
  child_status
  status=$?
  [ "$status" -eq 0 ] || return 1
  wait "$child" 2>/dev/null || true
}
arm_emergency_write() {
  local reason=$1 emergency="$STATE/.watch-arm-emergency" tmp
  if [ -e "$emergency" ] || [ -L "$emergency" ]; then
    [ -f "$emergency" ] && [ ! -L "$emergency" ] || return 1
  fi
  tmp=$(mktemp "$STATE/.watch-arm-emergency.XXXXXX" 2>/dev/null) || return 1
  if ! {
    [ ! -f "$emergency" ] || cat "$emergency"
    printf 'at=%s\nreason=%s\nchild_pid=%s\nchild_identity=%s\n' \
      "$(date +%s)" "$reason" "${child:-unknown}" "${child_identity:-unknown}"
  } > "$tmp" 2>/dev/null || ! chmod 0600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$emergency" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}
arm_publish_failure() {
  local reason=$1 queue_status=1 emergency_status=1
  fm_recovery_transition "$STATE/.watcher-down" publish downtime >/dev/null 2>&1 || true
  if FM_WAKE_APPEND_LOCK_TRIES=${FM_WAKE_APPEND_LOCK_TRIES:-${FM_WATCH_ARM_WAKE_QUEUE_LOCK_TRIES:-100}} \
    fm_wake_append check watcher-arm "$reason" >/dev/null 2>&1; then
    queue_status=0
  fi
  if [ "$queue_status" -ne 0 ]; then
    arm_emergency_write "$reason" >/dev/null 2>&1 && emergency_status=0
  fi
  [ "$queue_status" -eq 0 ] || [ "$emergency_status" -eq 0 ]
}
cleanup_child() {
  local status attempts=0 max_attempts=${FM_WATCH_ARM_CLEANUP_TRIES:-40}
  case "$max_attempts" in ''|*[!0-9]*|0) max_attempts=40 ;; esac
  while [ "$attempts" -lt "$max_attempts" ]; do
    if stop_child_bounded; then
      break
    fi
    child_status
    status=$?
    case "$status" in
      0) wait "$child" 2>/dev/null || true; break ;;
      1|2) sleep 0.05 ;;
    esac
    attempts=$((attempts + 1))
  done
  if [ "$attempts" -ge "$max_attempts" ]; then
    arm_publish_failure "watcher arm child termination could not be confirmed"
    return 1
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
  return 0
}

hold_child_tracked() {
  local status next_report=0 now reason hold_seconds=${FM_WATCH_ARM_UNKNOWN_CHILD_HOLD_SECONDS:-60}
  local hold_deadline blocked=0
  case "$hold_seconds" in ''|*[!0-9]*|0) hold_seconds=60 ;; esac
  hold_deadline=$(( $(date +%s) + hold_seconds ))
  while [ -n "$child" ]; do
    if stop_child_bounded; then
      child=
      break
    fi
    now=$(date +%s)
    reason="watcher arm child remains live but its process identity cannot be confirmed"
    if [ "$blocked" -eq 0 ] && [ "$now" -ge "$next_report" ]; then
      arm_publish_failure "$reason" || printf 'watcher: emergency diagnostic persistence failed\n' >&2
      next_report=$((now + 20))
    fi
    if [ "$blocked" -eq 0 ] && [ "$now" -ge "$hold_deadline" ]; then
      arm_publish_failure "$reason; bounded cleanup window exhausted; retaining explicit child ownership" \
        || printf 'watcher: emergency diagnostic persistence failed\n' >&2
      arm_emergency_write "$reason; bounded cleanup window exhausted; retaining explicit child ownership" \
        || printf 'watcher: emergency diagnostic persistence failed\n' >&2
      arm_blocked_write "$reason; bounded cleanup window exhausted; retaining explicit child ownership" \
        || printf 'watcher: blocked-child state persistence failed\n' >&2
      blocked=1
    fi
    if [ "$blocked" -eq 1 ]; then
      child_status
      status=$?
      case "$status" in
        0) wait "$child" 2>/dev/null || true; child=; arm_blocked_clear; break ;;
        1|2) sleep 1 ;;
      esac
      continue
    fi
    child_status
    status=$?
    case "$status" in
      0) wait "$child" 2>/dev/null || true; child=; arm_blocked_clear; break ;;
      1|2) sleep 1 ;;
    esac
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_arm_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  if ! cleanup_child; then
    cycle_log_append "$rc" "$signal" arm-interrupted-unconfirmed none
    arm_publish_failure "watcher arm interrupted by $signal; child termination could not be confirmed" \
      || printf 'watcher: emergency diagnostic persistence failed\n' >&2
    hold_child_tracked
    exit "$rc"
  fi
  arm_publish_failure "watcher arm interrupted by $signal" \
    || printf 'watcher: emergency diagnostic persistence failed\n' >&2
  cycle_log_append "$rc" "$signal" arm-interrupted none
  exit "$rc"
}

trap 'handle_arm_signal HUP 129' HUP
trap 'handle_arm_signal TERM 143' TERM
trap 'handle_arm_signal INT 130' INT
trap 'arm_release_claim' EXIT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" >"$child_out" &
else
  "$WATCH" >"$child_out" &
fi
child=$!
child_identity=$(fm_pid_identity "$child" 2>/dev/null || true)
cycle_begin "$child" started "$child_identity"
child_done=0

owned_child_finished() {
  local rc=$1 signal reason_type status
  signal=$(cycle_signal_name "$rc")
  if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
    reason_type=$(watch_output_reason_type "$child_out")
    cycle_log_append "$rc" "$signal" "$reason_type" none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    if wait_for_healthy_successor; then
      cycle_log_append "$rc" "$signal" unexpected-clean-exit "attached:$HEALTHY_PID"
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
      report_attached
      cycle_begin "$HEALTHY_PID" attached "$HEALTHY_IDENTITY"
      attach_and_wait "$HEALTHY_PID"
      return $?
    fi
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    if close_unobserved_cycle; then
      cycle_log_append "$rc" "$signal" clean-exit-delivered-wake none
      return 0
    fi
    cycle_log_append "$rc" "$signal" unexpected-clean-exit none
    return 1
  fi

  reason_type="nonzero-exit"
  [ "$signal" = none ] || reason_type="signal-exit"
  cycle_log_append "$rc" "$signal" "$reason_type" none
  print_watch_output "$child_out"
  if ! grep -q '^watcher: FAILED' "$child_out" 2>/dev/null; then
    echo "watcher: FAILED - watcher cycle exited $rc without an actionable reason"
  fi
  rm -f "$child_out" 2>/dev/null || true
  child=
  child_out=
  status=$rc
  [ "$status" -gt 0 ] || status=1
  return "$status"
}

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
# date(1) exposes whole seconds. Keep the configured confirmation budget from
# collapsing when startup begins just before the next second boundary.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      cycle_refresh_lock_before
      if ! handling_generation=$(handling_successor_generation); then
        if ! cleanup_child; then
          cycle_log_append 1 none handling-handoff-termination-unconfirmed none
          echo "watcher: FAILED - watcher termination could not be confirmed" >&2
          hold_child_tracked
          exit 1
        fi
        cycle_log_append 1 none handling-handoff-failed none
        echo "watcher: FAILED - established successor could not inspect handling state"
        exit 1
      fi
      cycle_mark_predecessor_successor "started:$child"
      if [ -n "$handling_generation" ]; then
        echo "watcher: started pid=$child (beacon fresh) recovery-generation=$handling_generation"
      else
        echo "watcher: started pid=$child (beacon fresh)"
      fi
      wait "$child"
      rc=$?
      owned_child_finished "$rc"
      exit $?
    fi
    # Another watcher won the singleton; our child stood down.
    wait "$child"
    rc=$?
    owned_child_finished "$rc"
    exit $?
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    owned_child_finished "$rc"
    exit $?
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
print_watch_output "$child_out"
if ! cleanup_child; then
  cycle_log_append 1 none confirmation-timeout-termination-unconfirmed none
  echo "watcher: FAILED - watcher termination could not be confirmed" >&2
  hold_child_tracked
  exit 1
fi
rc=1
cycle_log_append "$rc" "$(cycle_signal_name "$rc")" confirmation-timeout none
echo "watcher: FAILED - no live watcher with a fresh beacon"
exit 1
