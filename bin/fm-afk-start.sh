#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a REFRESH: no stale-artifact clear);
#     - otherwise clears any prior away session's stale escalation artifacts
#       (fm_afk_clear_stale_artifacts) for a direct, non-prepared start, then
#       execs bin/fm-supervise-daemon.sh in the foreground. A prepared start was
#       already cleared transactionally by bin/fm-afk-launch.sh.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and fm_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process differs by harness/backend and is owned elsewhere:
#   - Harnesses with a native in-pane tracked-background tool (e.g. claude, grok)
#     run this directly via that tool, so the daemon inherits the captain pane's
#     env and auto-discovers it.
#   - Harnesses with NO native background mechanism (e.g. pi) run this THROUGH
#     bin/fm-afk-launch.sh, which creates a non-visible tracked terminal per
#     backend (herdr tab/workspace, tmux detached session) and passes the
#     captain pane in as FM_SUPERVISOR_TARGET so injection targets it, not the
#     daemon's own new pane.
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
set -eu

FM_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LOCK="$FM_AFK_STATE/.supervise-daemon.lock"
FM_SUPERVISION_CLAIM="$FM_AFK_STATE/.supervision-claim.lock"
FM_AFK_DAEMON="${FM_AFK_DAEMON_OVERRIDE:-$FM_AFK_START_DIR/fm-supervise-daemon.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_START_DIR/fm-wake-lib.sh"

fm_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# fm_afk_clear_stale_artifacts: on a FRESH away-session entry (the daemon is not
# already running), drop the previous away session's leftover escalation-delivery
# artifacts so they cannot surface as stale escalations under the new session.
# These are session-scoped by timing: a fresh entry owns a new supervision
# session and the new daemon has not produced anything yet, so anything present
# here belongs to a PRIOR session. This never drops a genuinely-pending
# escalation - the delivery buffer is a transient cache, and any condition still
# true (a crew still blocked, a check still firing) is re-derived and re-escalated
# fresh by the daemon's heartbeat catch-all scan and the durable
# state/.wake-queue replay (see docs/herdr-backend.md "Away-mode stale-artifact
# lifecycle" and bin/fm-supervise-daemon.sh's escalate_add/inject_wedge_alarm).
# NOT called on a refresh (daemon already alive), so the current session's own
# buffered escalations are preserved.
fm_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" 2>/dev/null
}

daemon_lock_owner() {
  local owner
  if [ -L "$FM_AFK_LOCK" ]; then
    owner=$(readlink "$FM_AFK_LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$FM_AFK_LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$FM_AFK_LOCK" ] || return 1
  printf '%s\n' "$FM_AFK_LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  [ -n "$identity" ] || return 1
  current=$(fm_pid_identity "$pid") || return 1
  [ "$current" = "$identity" ]
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  [ "$(daemon_lock_state)" = live ]
}

daemon_lock_state() {
  local owner pid recorded_identity current_identity
  owner=$(daemon_lock_owner 2>/dev/null || true)
  [ -n "$owner" ] || { printf 'absent\n'; return 0; }
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  [ -n "$pid" ] || { printf 'ambiguous\n'; return 0; }
  if ! fm_pid_alive "$pid"; then
    printf 'stale\n'
    return 0
  fi
  recorded_identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
  if [ -n "$recorded_identity" ] && [ -n "$current_identity" ] \
    && [ "$current_identity" = "$recorded_identity" ]; then
    printf 'live\n'
  else
    printf 'ambiguous\n'
  fi
}

fm_afk_flag_write() {  # <state-dir>
  local state=$1 lock="$1/.cursor-park-owner.lock" pending attempt=0 status=1
  mkdir -p "$state" || return 1
  [ ! -d "$state/.afk" ] || return 1
  pending=$(mktemp "$state/.afk.pending.XXXXXX") || return 1
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  while [ "$attempt" -lt 50 ]; do
    attempt=$((attempt + 1))
    if fm_lock_try_acquire "$lock"; then
      mv "$pending" "$state/.afk" && status=0
      fm_lock_release "$lock"
      rm -f "$pending" 2>/dev/null || true
      return "$status"
    fi
    [ "$attempt" -lt 50 ] && sleep 0.1
  done
  rm -f "$pending" 2>/dev/null || true
  return 1
}

fm_afk_start_main() {
  local claim_acquired=0
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-afk-start.sh}")" >&2; return 2 ;;
  esac

  mkdir -p "$FM_AFK_STATE"
  if [ "${FM_SUPERVISION_CLAIM_HELD:-0}" = 1 ]; then
    if ! fm_lock_owned_by_current "$FM_SUPERVISION_CLAIM"; then
      echo "afk: refusing an unverified continuity ownership claim" >&2
      return 1
    fi
  else
    if ! fm_supervision_claim_acquire "$FM_SUPERVISION_CLAIM" 100; then
      echo "afk: could not acquire the continuity ownership claim" >&2
      return 1
    fi
    claim_acquired=1
    export FM_SUPERVISION_CLAIM_HELD=1
  fi
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    if [ ! -f "$FM_AFK_STATE/.afk" ]; then
      [ "$claim_acquired" -eq 1 ] && fm_lock_release "$FM_SUPERVISION_CLAIM"
      echo "afk: launcher-prepared state is missing" >&2
      return 1
    fi
    if ! fm_supervision_claim_pending "$FM_AFK_STATE"; then
      [ "$claim_acquired" -eq 1 ] && fm_lock_release "$FM_SUPERVISION_CLAIM"
      echo "afk: lifecycle handoff reservation is missing or expired" >&2
      return 1
    fi
    export FM_AFK_HANDOFF=1
  else
    if ! fm_afk_flag_write "$FM_AFK_STATE"; then
      [ "$claim_acquired" -eq 1 ] && fm_lock_release "$FM_SUPERVISION_CLAIM"
      echo "afk: failed to write away-mode flag" >&2
      return 1
    fi
  fi

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    echo "afk: daemon already running pid=$pid"
    [ "$claim_acquired" -eq 1 ] && fm_lock_release "$FM_SUPERVISION_CLAIM"
    return 0
  fi

  if fm_pid_alive "$pid" && [ -n "$pid" ]; then
    local owner recorded_identity current_identity
    owner=$(daemon_lock_owner 2>/dev/null) || {
      echo "afk: refusing to replace a live away-daemon lock with unknown ownership" >&2
      [ "$claim_acquired" -eq 1 ] && fm_lock_release "$FM_SUPERVISION_CLAIM"
      return 1
    }
    recorded_identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ -z "$recorded_identity" ] || [ -z "$current_identity" ] \
      || [ "$current_identity" = "$recorded_identity" ]; then
      echo "afk: refusing to replace a live away daemon without a mismatched process identity" >&2
      [ "$claim_acquired" -eq 1 ] && fm_lock_release "$FM_SUPERVISION_CLAIM"
      return 1
    fi
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  if [ "${FM_AFK_STATE_PREPARED:-0}" != 1 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_STATE"; then
      [ "$claim_acquired" -eq 1 ] && fm_lock_release "$FM_SUPERVISION_CLAIM"
      echo "afk: failed to clear stale away-mode artifacts" >&2
      return 1
    fi
  fi

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  if ! exec "$FM_AFK_DAEMON"; then
    [ "$claim_acquired" -eq 1 ] && fm_lock_release "$FM_SUPERVISION_CLAIM"
    return 1
  fi
}

# Run only when executed, not when sourced (tests source fm_afk_clear_stale_artifacts
# and the lock helpers directly).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_start_main "$@"
fi
