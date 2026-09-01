#!/usr/bin/env bash
# fm-afk-launch.sh - the single owner of the away-mode daemon TERMINAL lifecycle:
# launch it in a NON-VISIBLE tracked terminal per backend, record its exact id,
# tear it down by that exact id, and reconcile a leaked one after a crash.
#
# Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/fm-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever
# terminal it is already in. Harnesses with a native in-pane tracked-background
# tool (claude, grok) run it there directly and it is fine. A harness with NO
# native background mechanism (pi) has to manufacture a terminal, and doing that
# by SPLITTING the captain's active pane visibly shrinks it - the regression this
# script fixes. Instead this creates a non-visible tracked terminal (a herdr tab/
# workspace with --no-focus) that never touches the
# captain's active tab, and NEVER uses shell `&` (which herdr/codex can reap).
#
# Correct supervisor targeting: the daemon finds the captain pane to inject into
# from its OWN inherited env (discover_supervisor_target). Running it in a
# separate terminal would make it discover its OWN pane, so this captures the
# captain pane FIRST (from the pane this script runs in) and passes it in as
# FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND explicitly.
#
# Usage:
#   fm-afk-launch.sh start     Capture the captain pane, then (unless the daemon
#                              is already running) launch the daemon in a fresh
#                              non-visible terminal for the detected backend and
#                              record it. Idempotent: an already-running daemon
#                              just refreshes state/.afk; a recorded-but-dead
#                              terminal is reconciled (closed by id) first.
#   fm-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#   fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
#                              cleanup flushes WHILE state/.afk is still present,
#                              wait for it, close the recorded terminal by exact
#                              id, then clear state/.afk last.
#   fm-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#
# Supported active backend: herdr. Retained adapters are available only in the
# repository's regression lane.
#
# Test seam: FM_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal (default bin/fm-afk-start.sh), so a topology test can run a harmless
# placeholder instead of a real daemon. FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND
# override the captured captain pane/backend (an isolated lab pane in tests).
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_LAUNCH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in
  /*) ;;
  *)
    FM_AFK_LAUNCH_HOME_INPUT=$FM_HOME
    FM_HOME=$(CDPATH='' cd -- "$FM_AFK_LAUNCH_HOME_INPUT" 2>/dev/null && pwd -P) || {
      echo "error: FM_HOME directory cannot be resolved: $FM_AFK_LAUNCH_HOME_INPUT" >&2
      exit 1
    }
    ;;
esac
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  case "$FM_STATE_OVERRIDE" in
    /*) ;;
    *)
      FM_AFK_LAUNCH_STATE_INPUT=$FM_STATE_OVERRIDE
      FM_STATE_OVERRIDE=$(CDPATH='' cd -- "$FM_AFK_LAUNCH_STATE_INPUT" 2>/dev/null && pwd -P) || {
        echo "error: FM_STATE_OVERRIDE directory cannot be resolved: $FM_AFK_LAUNCH_STATE_INPUT" >&2
        exit 1
      }
      ;;
  esac
fi
FM_AFK_LAUNCH_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LAUNCH_RECORD="$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal"
FM_AFK_LAUNCH_LOCK="$FM_AFK_LAUNCH_STATE/.afk-launch.lock"
FM_AFK_LAUNCH_WS_LABEL="firstmate-afk-daemon"

# shellcheck source=bin/fm-backend.sh
. "$FM_AFK_LAUNCH_DIR/fm-backend.sh"
# shellcheck source=bin/backends/herdr.sh
. "$FM_AFK_LAUNCH_DIR/backends/herdr.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-supervisor-target-lib.sh"
# fm-afk-start.sh provides the daemon-lock liveness helpers and
# fm_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-start.sh"
set +e

fm_afk_launch_log() { printf 'fm-afk-launch: %s\n' "$*" >&2; }

fm_afk_launch_preflight() {
  fm_backend_policy_legacy_lane && return 0
  local backend target workspace tab
  backend=$(discover_supervisor_backend) || return 1
  fm_backend_validate "$backend" || return 1
  target=$(discover_supervisor_target) || return 1
  if [ "$backend" = herdr ] && [ "${FM_SUPERVISOR_TARGET:-}" = "$target" ]; then
    fm_backend_herdr_target_ready "$target" || return $?
    workspace=$FM_BACKEND_HERDR_EXPECTED_WORKSPACE_ID
    tab=$FM_BACKEND_HERDR_EXPECTED_TAB_ID
  else
    workspace=${HERDR_WORKSPACE_ID:-}
    tab=${HERDR_TAB_ID:-}
  fi
  fm_backend_target_exists "$backend" "$target" "" \
    "$workspace" "$tab" || return $?
}

fm_afk_launch_lock_owned() {
  local pid expected actual
  [ -d "$FM_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null) || return 1
  expected=$(cat "$FM_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null) || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

fm_afk_launch_lock_acquire() {
  local attempt=0 incomplete=0 identity
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  while [ "$attempt" -lt 200 ]; do
    attempt=$((attempt + 1))
    if mkdir "$FM_AFK_LAUNCH_LOCK" 2>/dev/null; then
      if ! printf '%s' "$$" > "$FM_AFK_LAUNCH_LOCK/pid"; then
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      fi
      identity=$(fm_pid_identity "$$" 2>/dev/null) || {
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      }
      if [ -z "$identity" ] || ! printf '%s' "$identity" > "$FM_AFK_LAUNCH_LOCK/pid-identity"; then
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      fi
      return 0
    fi
    if [ ! -s "$FM_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$FM_AFK_LAUNCH_LOCK/pid-identity" ]; then
      incomplete=$((incomplete + 1))
      if [ "$incomplete" -lt 20 ]; then
        sleep 0.05
        continue
      fi
    else
      incomplete=0
    fi
    if ! fm_afk_launch_lock_owned; then
      rm -rf "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || return 1
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  fm_afk_launch_log "timed out waiting for launcher lock"
  return 1
}

fm_afk_launch_lock_release() {
  local pid
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "$$" ] || return 0
  rm -rf "$FM_AFK_LAUNCH_LOCK"
}

fm_afk_launch_usage() {
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${FM_AFK_LAUNCH_ENTRY:-$FM_ROOT/bin/fm-afk-start.sh}"
}

fm_afk_launch_record_write() {  # <backend> <target> <workspace> [tab]
  local pending
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  if [ "$1" = herdr ]; then
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" > "$pending" || { rm -f "$pending"; return 1; }
  else
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  fi
  mv "$pending" "$FM_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_allow_tmux() {
  fm_backend_policy_legacy_adapter_allowed tmux && return 0
  fm_backend_policy_refuse "AFK daemon terminal record" tmux \
    "Retire this pre-invariant AFK terminal record through docs/configuration.md \"Legacy task records\"."
  return 1
}

fm_afk_launch_flag_write() {
  fm_afk_flag_write "$FM_AFK_LAUNCH_STATE"
}

# Read the recorded terminal into the FM_AFK_REC_* fields. Returns 1 when no
# record exists.
fm_afk_launch_record_read() {
  local record fields
  FM_AFK_REC_BACKEND=""; FM_AFK_REC_TARGET=""; FM_AFK_REC_WORKSPACE=""; FM_AFK_REC_TAB=""
  [ -f "$FM_AFK_LAUNCH_RECORD" ] || return 1
  record=$(cat "$FM_AFK_LAUNCH_RECORD" 2>/dev/null) || record=""
  fields=$(printf '%s\n' "$record" | awk -F '\t' 'NF { print NF; exit }')
  IFS=$'\t' read -r FM_AFK_REC_BACKEND FM_AFK_REC_TARGET FM_AFK_REC_WORKSPACE FM_AFK_REC_TAB \
    < "$FM_AFK_LAUNCH_RECORD" || true
  if { [ "$fields" != 3 ] && [ "$fields" != 4 ]; } \
    || [ -z "$FM_AFK_REC_BACKEND" ] || [ -z "$FM_AFK_REC_TARGET" ]; then
    fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_AFK_REC_BACKEND" in
    herdr)
      [ "$fields" = 4 ] && [ -n "$FM_AFK_REC_WORKSPACE" ] && [ -n "$FM_AFK_REC_TAB" ] || {
        if declare -F fm_backend_policy_refuse >/dev/null 2>&1; then
          fm_backend_policy_refuse "AFK Herdr terminal record" herdr \
            "This record lacks exact workspace and tab identity; retire it through docs/configuration.md \"Legacy task records\"."
        else
          fm_afk_launch_log "daemon terminal record lacks exact Herdr workspace/tab identity"
        fi
        return 2
      }
      ;;
    tmux) fm_afk_launch_allow_tmux || return 2 ;;
    none) [ "$fields" = 3 ] && [ "$FM_AFK_REC_TARGET" = - ] && [ "$FM_AFK_REC_WORKSPACE" = native ] ;;
    *) return 2 ;;
  esac || { fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

fm_afk_launch_record_validate_if_present() {
  local result
  fm_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

fm_afk_launch_stop_preflight() {
  fm_backend_policy_legacy_lane && return 0
  local target session
  fm_afk_launch_record_validate_if_present || return 1
  if [ "$FM_AFK_REC_BACKEND" = herdr ]; then
    session=${FM_AFK_REC_TARGET%%:*}
  else
    target=$(discover_supervisor_target) || return 1
    session=${target%%:*}
  fi
  [ -n "$session" ] || return 1
  fm_backend_herdr_capability_preflight "AFK lifecycle" "$session" || return 1
}

# Close a recorded terminal by EXACT id (never a broad sweep). The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
fm_afk_launch_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      fm_backend_source herdr "AFK terminal close" "$session" || return 1
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] \
        && [ -n "${FM_AFK_REC_WORKSPACE:-}" ] && [ -n "${FM_AFK_REC_TAB:-}" ] || return 2
      fm_backend_herdr_stable_operation \
        "$session" "$FM_AFK_REC_WORKSPACE" "$FM_AFK_REC_TAB" "$pane" close >/dev/null
      ;;
    tmux)
      fm_afk_launch_allow_tmux || return 1
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "$target" 2>/dev/null
      ;;
    none)
      return 0
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_afk_launch_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 session pane workspace=${3:-} tab=${4:-} presence presence_rc
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      fm_backend_source herdr "AFK terminal liveness" "$session" || return 1
      [ -n "$workspace" ] && [ -n "$tab" ] || return 2
      if presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane" "$workspace" "$tab"); then
        :
      else
        presence_rc=$?
        return "$presence_rc"
      fi
      [ "$presence" = dead ]
      ;;
    tmux)
      fm_afk_launch_allow_tmux || return 1
      out=$(tmux has-session -t "$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eq "can't find session"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_close_recorded() {
  local close_result=0
  fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" || close_result=$?
  if fm_afk_launch_terminal_absent "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" \
    "${FM_AFK_REC_WORKSPACE:-}" "${FM_AFK_REC_TAB:-}"; then
    rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

fm_afk_launch_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 session pane presence presence_rc
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      fm_backend_source herdr "AFK terminal liveness" "$session" || return 1
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] \
        && [ -n "${FM_AFK_REC_WORKSPACE:-}" ] && [ -n "${FM_AFK_REC_TAB:-}" ] || return 2
      if presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane" \
        "$FM_AFK_REC_WORKSPACE" "$FM_AFK_REC_TAB"); then
        :
      else
        presence_rc=$?
        return "$presence_rc"
      fi
      [ "$presence" = present ]
      ;;
    tmux)
      fm_afk_launch_allow_tmux || return 1
      tmux has-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 attempt=0
  if [ -n "${FM_AFK_LAUNCH_ENTRY:-}" ]; then
    fm_afk_launch_terminal_alive "$backend" "$target"
    return
  fi
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    daemon_lock_held_by_live_daemon && return 0
    fm_afk_launch_terminal_alive "$backend" "$target" || return 1
    sleep 0.05
  done
  return 1
}

fm_afk_launch_commit_terminal() {  # <backend> <target> <workspace> [tab] [already-recorded]
  local backend=$1 target=$2 workspace=$3 tab=${4:-} already_recorded=${5:-0}
  if [ "$already_recorded" -ne 1 ] && ! fm_afk_launch_record_write "$backend" "$target" "$workspace" "$tab"; then
    fm_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    fm_afk_launch_close_terminal "$backend" "$target"
    return 1
  fi
  if ! fm_afk_launch_wait_ready "$backend" "$target"; then
    fm_afk_launch_log "daemon did not become ready; closing $backend:$target"
    FM_AFK_REC_BACKEND=$backend
    FM_AFK_REC_TARGET=$target
    fm_afk_launch_close_recorded
    return 1
  fi
}

fm_afk_launch_herdr_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane tab attempt=0
  local workspaces_rc panes_rc
  while [ "$attempt" -lt 20 ]; do
    attempt=$((attempt + 1))
    if workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>&1); then
      workspaces_rc=0
    else
      workspaces_rc=$?
    fi
    if [ "$workspaces_rc" -ne 0 ] || ! printf '%s' "$workspaces" | jq -e '
      (.result.workspaces | type) == "array"
      and all(.result.workspaces[]; (. | type) == "object"
        and (.workspace_id | type) == "string" and (.workspace_id | length) > 0
        and (.label | type) == "string")
    ' >/dev/null 2>&1; then
      fm_backend_policy_refuse "AFK Herdr workspace recovery" herdr \
        "The native Herdr workspace inventory failed or was malformed while recovering the daemon terminal. Repair Herdr, then verify the named session with 'herdr status --json'." || true
      return 2
    fi
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[] | select(.label == $want)] | length' 2>/dev/null) || {
      fm_backend_policy_refuse "AFK Herdr workspace recovery" herdr \
        "The native Herdr workspace inventory could not be parsed while recovering the daemon terminal. Repair Herdr, then verify the named session with 'herdr status --json'." || true
      return 2
    }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || {
      fm_backend_policy_refuse "AFK Herdr workspace recovery" herdr \
        "The daemon terminal recovery matched multiple Herdr workspaces with the same label. Resolve the ambiguity, then verify the named session with 'herdr status --json'." || true
      return 2
    }
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[] | select(.label == $want) | .workspace_id' 2>/dev/null) || {
      fm_backend_policy_refuse "AFK Herdr workspace recovery" herdr \
        "The native Herdr workspace identity could not be read while recovering the daemon terminal. Repair Herdr, then verify the named session with 'herdr status --json'." || true
      return 2
    }
    if panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>&1); then
      panes_rc=0
    else
      panes_rc=$?
    fi
    if [ "$panes_rc" -ne 0 ] || ! printf '%s' "$panes" | jq -e --arg workspace "$wsid" '
      (.result.panes | type) == "array"
      and all(.result.panes[]; (. | type) == "object"
        and (.pane_id | type) == "string" and (.pane_id | length) > 0
        and (.tab_id | type) == "string" and (.tab_id | length) > 0
        and (.workspace_id | type) == "string" and (.workspace_id | length) > 0
        and .workspace_id == $workspace)
    ' >/dev/null 2>&1; then
      fm_backend_policy_refuse "AFK Herdr pane recovery" herdr \
        "The native Herdr pane inventory failed or was malformed while recovering the daemon terminal. Repair Herdr, then verify the named session with 'herdr status --json'." || true
      return 2
    fi
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]] | length' 2>/dev/null) || {
      fm_backend_policy_refuse "AFK Herdr pane recovery" herdr \
        "The native Herdr pane inventory could not be parsed while recovering the daemon terminal. Repair Herdr, then verify the named session with 'herdr status --json'." || true
      return 2
    }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || {
      fm_backend_policy_refuse "AFK Herdr pane recovery" herdr \
        "The daemon terminal recovery matched multiple Herdr panes in one workspace. Resolve the ambiguity, then verify the named session with 'herdr status --json'." || true
      return 2
    }
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id' 2>/dev/null) || return 2
    tab=$(printf '%s' "$panes" | jq -r '.result.panes[0].tab_id' 2>/dev/null) || return 2
    printf '%s\t%s\t%s' "$wsid" "$tab" "$pane"
    return 0
  done
  fm_backend_policy_refuse "AFK Herdr workspace recovery" herdr \
    "The native Herdr daemon terminal did not become uniquely visible before recovery timed out. Repair Herdr, then verify the named session with 'herdr status --json'." || true
  return 2
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {
  local read_result
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_log "reconciling leaked daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET}"
    fm_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

fm_afk_launch_validate_herdr_identity() {  # <session> <workspace> <tab> <pane>
  local session=$1 workspace=$2 expected_tab=$3 pane=$4 out actual_tab rc=0
  if out=$(fm_backend_herdr_pane_get_checked "$session" "$workspace" "$expected_tab" "$pane" 0); then
    :
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    fm_backend_policy_refuse "AFK Herdr terminal identity" herdr \
      "The native Herdr pane identity could not be verified before recording the daemon terminal. Repair Herdr, then verify the named session with 'herdr status --json'." || true
    return 2
  fi
  actual_tab=$(printf '%s' "$out" | jq -er '.result.pane.tab_id' 2>/dev/null) || {
    fm_backend_policy_refuse "AFK Herdr terminal identity" herdr \
      "The native Herdr pane identity response was malformed before recording the daemon terminal. Repair Herdr, then verify the named session with 'herdr status --json'." || true
    return 2
  }
  if [ -n "$expected_tab" ] && [ "$actual_tab" != "$expected_tab" ]; then
    fm_backend_policy_refuse "AFK Herdr terminal identity" herdr \
      "The native Herdr pane and tab identities disagreed before recording the daemon terminal. Repair Herdr, then verify the named session with 'herdr status --json'." || true
    return 2
  fi
  printf '%s' "$actual_tab"
}

fm_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$FM_AFK_LAUNCH_STATE/.afk" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-inject-wedged" || result=1
  if [ "$had_afk" -eq 1 ]; then
    cp "$backup/.afk" "$FM_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$backup/$artifact" ]; then
      cp -p "$backup/$artifact" "$FM_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    fm_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Launch the daemon in a non-visible herdr terminal in the CAPTAIN's session
# (so the daemon can inject into the captain pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the captain's active tab. Prints the record line on success.
fm_afk_launch_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid tab pane entry cmd label recovered create_result verified_tab
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    fm_afk_launch_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  fm_backend_source herdr "AFK terminal creation" "$session" || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  label=${FM_AFK_LAUNCH_LABEL:-"$FM_AFK_LAUNCH_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -n "$wsid" ] && [ -n "$pane" ]; then
    if verified_tab=$(fm_afk_launch_validate_herdr_identity "$session" "$wsid" "$tab" "$pane"); then
      tab=$verified_tab
    else
      return 2
    fi
  fi
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    fm_afk_launch_log "herdr create failed after returning exact ids; closing $session:$pane"
    if fm_afk_launch_record_write herdr "$session:$pane" "$wsid" "$tab"; then
      FM_AFK_REC_BACKEND=herdr
      FM_AFK_REC_TARGET="$session:$pane"
      FM_AFK_REC_WORKSPACE=$wsid
      FM_AFK_REC_TAB=$tab
      fm_afk_launch_close_recorded || true
    else
      fm_afk_launch_log "failed to persist exact id for failed herdr create"
    fi
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$session" "$label") || {
      return 2
    }
    IFS=$'\t' read -r wsid tab pane <<< "$recovered"
  fi
  if [ -z "$wsid" ] || [ -z "$tab" ] || [ -z "$pane" ]; then
    fm_backend_policy_refuse "AFK Herdr terminal identity" herdr \
      "The native Herdr daemon terminal response did not contain an exact workspace, tab, and pane identity. Repair Herdr, then verify the named session with 'herdr status --json'." || true
    return 2
  fi
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write herdr "$session:$pane" "$wsid" "$tab"; then
    fm_afk_launch_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    FM_AFK_REC_WORKSPACE=$wsid
    FM_AFK_REC_TAB=$tab
    fm_afk_launch_close_terminal herdr "$session:$pane"
    return 1
  fi
  FM_AFK_REC_BACKEND=herdr
  FM_AFK_REC_TARGET="$session:$pane"
  FM_AFK_REC_WORKSPACE=$wsid
  FM_AFK_REC_TAB=$tab
  if ! fm_backend_herdr_stable_operation "$session" "$wsid" "$tab" "$pane" run "$cmd" >/dev/null; then
    fm_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    FM_AFK_REC_BACKEND=herdr
    FM_AFK_REC_TARGET="$session:$pane"
    fm_afk_launch_close_recorded || true
    return 1
  fi
  fm_afk_launch_commit_terminal herdr "$session:$pane" "$wsid" "$tab" 1 || return 1
  fm_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Retained-adapter daemon launch for the repository's regression lane.
fm_afk_launch_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session entry cmd hash nonce
  fm_afk_launch_allow_tmux || return 1
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="fm-afk-daemon-$hash-$nonce"
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write tmux "$session" ""; then
    fm_afk_launch_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_afk_launch_log "failed to create retained-lane tmux daemon session '$session'"
    if ! rm -f "$FM_AFK_LAUNCH_RECORD"; then
      fm_afk_launch_log "failed to remove planned tmux daemon record after creation failure"
    fi
    return 1
  fi
  fm_afk_launch_commit_terminal tmux "$session" "" "" 1 || return 1
  fm_afk_launch_log "daemon launched in retained-lane tmux session '$session', supervising $captain_target"
}

fm_afk_launch_start() {
  local captain_target captain_backend backup artifact had_afk=0 result
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 1
  fi
  # Capture the captain pane FIRST, before creating anything.
  captain_target=$(discover_supervisor_target) || {
    fm_afk_launch_log "could not resolve the captain supervisor pane (set FM_SUPERVISOR_TARGET)"; return 1; }
  captain_backend=$(discover_supervisor_backend) || {
    fm_afk_launch_log "could not resolve the captain supervisor backend (set FM_SUPERVISOR_BACKEND)"; return 1; }
  fm_backend_source "$captain_backend" "AFK launcher" || return 1

  mkdir -p "$FM_AFK_LAUNCH_STATE"

  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! fm_afk_launch_reconcile; then
    result=1
  else
    if fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      result=0
    else
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$captain_backend" in
      herdr) fm_afk_launch_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
      tmux)  fm_afk_launch_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
      *)
        fm_afk_launch_log "no non-visible daemon-launch primitive for backend '$captain_backend'"
        result=1
        ;;
    esac
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native() {
  local backup artifact had_afk=0 result=0
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 1
  fi
  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  fm_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    elif ! fm_afk_launch_flag_write; then
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_record_write none - native || result=1
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_stop() {
  local pid pid_identity current_identity result=0 read_result
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  if ! fm_backend_policy_legacy_lane; then
    if [ "$FM_AFK_REC_BACKEND" = herdr ]; then
      fm_backend_herdr_capability_preflight "AFK stop" "${FM_AFK_REC_TARGET%%:*}" || return 1
    else
      local target session
      target=$(discover_supervisor_target) || return 1
      session=${target%%:*}
      [ -n "$session" ] || return 1
      fm_backend_herdr_capability_preflight "AFK stop" "$session" || return 1
    fi
  fi
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate).
  pid=""
  pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  fi
  if [ -n "$pid" ]; then
    if ! kill -TERM "$pid" 2>/dev/null; then
      fm_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
      fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    }
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  # (2) Close the daemon's own terminal by exact id.
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_close_recorded || result=1
  fi
  # (3) Clear the away-mode flag LAST.
  if ! rm -f "$FM_AFK_LAUNCH_STATE/.afk"; then
    fm_afk_launch_log "failed to clear away-mode flag"
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_log "away mode stopped; daemon terminal torn down and .afk cleared"
  else
    fm_afk_launch_log "away mode stopped; terminal teardown remains recorded for retry"
  fi
  return "$result"
}

fm_afk_launch_main() {
  local result preflight_rc
  # Traps first, lock second. Acquiring before the handlers exist leaves a
  # window where a signal terminates this process by default action and leaks
  # the lock directory, which then blocks the next away-mode launch until the
  # stale-owner reclaim path clears it. fm_afk_launch_lock_release only removes
  # a lock this process owns, so arming it before acquisition is safe.
  trap fm_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "${1:-start}" in
    start|start-native)
      if fm_afk_launch_preflight; then
        :
      else
        preflight_rc=$?
        return "$preflight_rc"
      fi
      ;;
    stop|reconcile)
      if fm_afk_launch_stop_preflight; then
        :
      else
        preflight_rc=$?
        return "$preflight_rc"
      fi
      ;;
  esac
  fm_afk_launch_lock_acquire || return 1
  case "${1:-start}" in
    start) fm_afk_launch_start ;;
    start-native) fm_afk_launch_start_native ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_lock_release || result=1
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
