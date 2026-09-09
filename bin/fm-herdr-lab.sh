#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# default session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#
# Session names must begin with "fm-lab-" and can never be "default".
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated socket paths short.
# Every Herdr call made here carries a trailing --session <session>.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision records the running default session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
#
# Bounds. Every finite CLI call has a 3-second deadline (FM_HERDR_LAB_CALL_SECS,
# integer 1..3). provision, stop, and teardown each run under ONE 20-second
# aggregate budget that starts before their first preflight call; every call,
# poll, wait, and cleanup step inside that command is clipped to the time that
# budget has left, provision keeps a 4-second cleanup reserve while polling
# (at most 30 polls), and the clock is never restarted after a failure.
#
# Ownership. provision launches the named server as a direct child that first
# writes a setsid marker and then execs the exact Herdr command. The helper
# waits for that marker and records an allocation receipt under the state
# directory (<session>.allocation.json) holding the child's exec-stable
# identity (pid, birth time, parent, process group), the original aggregate
# deadline, and, once the lab reports running, the native session evidence
# Herdr actually supplies (the lab's socket_path and running flag). The command
# text is recorded as a description only; it is never identity. Every later
# signal rechecks that identity immediately before sending: a pid whose birth
# or group changed is a reused pid and is refused, an unreadable process table
# is unknown and refused, and only a positively absent pid clears the receipt.
# Cleanup signals the direct child and then each remaining member of the
# child's own process group individually, each after its own recheck; there
# is no blanket group kill. A descendant that left that group (its own setsid)
# cannot be proved ours and is never signaled; any group member that survives
# is reported by pid and the receipt is retained. A retained receipt blocks
# re-provision of that name until teardown reconciles it.
#
# Tripwire. The fleet-state record holds every field the installed Herdr CLI
# supplies for the default session (name, default, running, socket_path) plus
# the OS identity of the socket file (device:inode), which changes when a
# server re-binds its socket. The Herdr 0.8.x CLI exposes no server start
# time, pid, or generation, so a live-handoff restart that keeps the socket is
# outside this proof; the record says so in its server_generation field
# rather than claiming a proof the surface cannot supply. A tripwire failure is
# always reported as the primary result, even when cleanup also failed.
# Process identity comes from ps (pid, lstart, ppid, pgid, stat); the check
# between a recheck and the signal that follows it is an unavoidable window.
set -u

FM_HERDR_LAB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_HERDR_LAB_LIB_DIR/fm-timeout-lib.sh"

FM_HERDR_LAB_BUDGET_SECS=20
FM_HERDR_LAB_CLEANUP_RESERVE_SECS=4
FM_HERDR_LAB_MAX_POLLS=30
FM_HERDR_LAB_DEADLINE=
FM_HERDR_LAB_RESERVE=0

fm_herdr_lab_error() {
  echo "fm-herdr-lab: $*" >&2
}

fm_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_herdr_lab_error "refusing session name 'default'" ;;
    '') fm_herdr_lab_error "refusing an empty session name" ;;
    *) fm_herdr_lab_error "session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_herdr_lab_state_dir() {
  printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}"
}

fm_herdr_lab_private_state() {
  local directory
  directory=$(fm_herdr_lab_state_dir)
  (umask 077; mkdir -p "$directory") || return 1
  fm_herdr_lab_timed 1 python3 -c 'import os, stat, sys
p = sys.argv[1]
s = os.lstat(p)
if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
    sys.exit(1)
for entry in os.scandir(p):
    s = entry.stat(follow_symlinks=False)
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077 or s.st_nlink != 1:
        sys.exit(1)' "$directory" || {
    fm_herdr_lab_error "unsafe existing lab state directory or object: $directory"
    return 1
  }
}

fm_herdr_lab_timed() {
  local wanted=$1 seconds remaining
  shift
  remaining=$(( $(fm_herdr_lab_remaining) - FM_HERDR_LAB_RESERVE - 1 ))
  [ "$remaining" -ge 1 ] || return 124
  seconds=$wanted
  [ "$seconds" -le "$remaining" ] || seconds=$remaining
  fm_run_timed "$seconds" "$@"
}

fm_herdr_lab_pause() {
  fm_herdr_lab_clip 1 >/dev/null || return 124
  fm_herdr_lab_timed 1 sleep "$1"
}

fm_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_receipt_path() { # <session>
  local path
  path="$(fm_herdr_lab_state_dir)/$1.allocation.json"
  if [ ! -f "$path" ] && [ -f "$path.pending" ]; then path="$path.pending"; fi
  printf '%s' "$path"
}

fm_herdr_lab_marker_path() { # <session>
  printf '%s/%s.allocation.setsid' "$(fm_herdr_lab_state_dir)" "$1"
}

# --- one aggregate budget per lifecycle command -----------------------------

fm_herdr_lab_now() {
  date +%s
}

fm_herdr_lab_budget_start() { # <seconds>
  FM_HERDR_LAB_DEADLINE=$(( $(fm_herdr_lab_now) + $1 ))
  FM_HERDR_LAB_RESERVE=0
}

fm_herdr_lab_remaining() {
  [ -n "$FM_HERDR_LAB_DEADLINE" ] || { printf '%s' "$FM_HERDR_LAB_BUDGET_SECS"; return 0; }
  printf '%s' $(( FM_HERDR_LAB_DEADLINE - $(fm_herdr_lab_now) ))
}

# Print <wanted> clipped to the budget left after the active reserve, or fail
# when less than one whole second remains.
fm_herdr_lab_clip() { # <wanted>
  local wanted=$1 remaining
  remaining=$(( $(fm_herdr_lab_remaining) - FM_HERDR_LAB_RESERVE ))
  [ "$remaining" -ge 1 ] || return 1
  if [ "$wanted" -le "$remaining" ]; then
    printf '%s' "$wanted"
  else
    printf '%s' "$remaining"
  fi
}

fm_herdr_lab_call_secs() {
  local seconds=${FM_HERDR_LAB_CALL_SECS:-3}
  case "$seconds" in 1|2|3) ;; *) fm_herdr_lab_error "call deadline must be 1..3 seconds"; return 1 ;; esac
  printf '%s' "$seconds"
}

# Run one public command under a fresh aggregate budget unless a caller already
# opened one, so a teardown's inner stop shares the teardown clock instead of
# starting its own.
fm_herdr_lab_with_budget() { # <function> <args...>
  local owner=0 rc=0
  if [ -z "$FM_HERDR_LAB_DEADLINE" ]; then
    fm_herdr_lab_budget_start "$FM_HERDR_LAB_BUDGET_SECS"
    owner=1
  fi
  "$@" || rc=$?
  if [ "$owner" -eq 1 ]; then
    FM_HERDR_LAB_DEADLINE=
    FM_HERDR_LAB_RESERVE=0
  fi
  return "$rc"
}

fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1 seconds
  shift
  seconds=$(fm_herdr_lab_call_secs) || return 1
  seconds=$(fm_herdr_lab_clip "$seconds") || {
    fm_herdr_lab_error "aggregate deadline exhausted before: herdr $*"
    return 124
  }
  fm_herdr_lab_timed "$seconds" env HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_lab_session_list() { # <session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_socket_identity() { # <path>
  local path=$1 identity
  [ -n "$path" ] && [ -S "$path" ] || return 1
  case "$(uname 2>/dev/null)" in
    Darwin|*BSD*) identity=$(fm_herdr_lab_timed 1 stat -f '%d:%i' "$path" 2>/dev/null) || return 1 ;;
    *) identity=$(fm_herdr_lab_timed 1 stat -c '%d:%i' "$path" 2>/dev/null) || return 1 ;;
  esac
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s' "$identity"
}

fm_herdr_lab_fleet_state() { # <session>
  local name=$1 sessions
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  fm_herdr_lab_snapshot_fleet_state "$sessions"
}

fm_herdr_lab_snapshot_fleet_state() {
  local sessions=$1 snapshot socket identity
  snapshot=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true)]
    | if length == 1 and .[0].name == "default" and .[0].running == true
      then .[0] | {name, default, running, socket_path}
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error "fleet-state tripwire requires exactly one running default session"
    return 1
  }
  socket=$(printf '%s' "$snapshot" | jq -r '.socket_path // empty' 2>/dev/null)
  identity=$(fm_herdr_lab_socket_identity "$socket") || {
    fm_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: required socket OS identity unavailable"
    return 1
  }
  printf '%s' "$snapshot" | jq -c --arg identity "$identity" \
    '. + {socket_identity: $identity, server_generation: "unsupported-by-cli"}'
}

fm_herdr_lab_prepare() { # <session>
  local name=$1 sessions
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  fm_herdr_lab_private_state || return 1
  fm_herdr_lab_prepare_from_sessions "$name" "$sessions"
}

fm_herdr_lab_prepare_from_sessions() {
  local name=$1 sessions=$2 tripwire
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi

  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ ! -e "$tripwire" ] || {
    fm_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  (umask 077; set -C; fm_herdr_lab_snapshot_fleet_state "$sessions" > "$tripwire") || {
    rm -f "$tripwire"
    return 1
  }
}

fm_herdr_lab_refuse_if_default() { # <session>
  local name=$1 info flag
  fm_herdr_lab_validate_name "$name" || return 1
  info=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  fm_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

fm_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_herdr_lab_error "run requires Herdr arguments"; return 1; }
  case "$1" in
    -*)
      fm_herdr_lab_error "run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        fm_herdr_lab_error "run forbids caller-supplied --session; the helper appends the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      fm_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      fm_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  fm_herdr_lab_raw "$name" "$@"
}

# --- process identity ---------------------------------------------------------
#
# Identity is the exec-stable triple birth|ppid|pgid read from ps. Exit 0 with
# the identity on stdout when the pid is present, 3 when it is positively
# absent (ps found nothing, or the pid is a zombie that can never act again),
# and 1 when the table could not be read in time - unknown, never absent.

fm_herdr_lab_proc_identity() { # <pid>
  local pid=$1 out rc=0 wday mon day time year ppid pgid stat
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  out=$(fm_herdr_lab_timed 1 env LC_ALL=C ps -p "$pid" -o lstart= -o ppid= -o pgid= -o stat= 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    1) [ -z "$out" ] && return 3; return 1 ;;
    *) return 1 ;;
  esac
  read -r wday mon day time year ppid pgid stat _ <<< "$out"
  [ -n "$year" ] && [ -n "$pgid" ] || return 1
  case "$stat" in Z*) return 3 ;; esac
  printf 'birth=%s-%s-%s-%s-%s ppid=%s pgid=%s\n' "$wday" "$mon" "$day" "$time" "$year" "$ppid" "$pgid"
}

fm_herdr_lab_identity_field() { # <identity> <field>
  local identity=$1 field=$2 token
  for token in $identity; do
    case "$token" in "$field="*) printf '%s' "${token#*=}"; return 0 ;; esac
  done
  return 1
}

# Live, non-zombie pids in process group <pgid> other than its leader. Exit 1
# when the table could not be read.
fm_herdr_lab_group_members() { # <pgid>
  local pgid=$1 table
  table=$(fm_herdr_lab_timed 1 env LC_ALL=C ps -e -o pid=,pgid=,stat= 2>/dev/null) || return 1
  printf '%s\n' "$table" | awk -v group="$pgid" '$2 == group && $1 != group && $3 !~ /^Z/ { print $1 }'
}

# Classify a recorded allocation as owned | absent | reused | unknown into
# FM_HERDR_LAB_ALLOCATION_STATE, leaving the current identity in
# FM_HERDR_LAB_CURRENT_IDENTITY when the pid is present. Called directly, never
# in a command substitution, so the result reaches the caller's shell.
fm_herdr_lab_allocation_state() { # <pid> <recorded-birth> <recorded-pgid>
  local pid=$1 birth=$2 pgid=$3 identity rc=0
  FM_HERDR_LAB_CURRENT_IDENTITY=
  FM_HERDR_LAB_ALLOCATION_STATE=unknown
  identity=$(fm_herdr_lab_proc_identity "$pid") || rc=$?
  case "$rc" in
    3) FM_HERDR_LAB_ALLOCATION_STATE=absent; return 0 ;;
    0) ;;
    *) return 0 ;;
  esac
  FM_HERDR_LAB_CURRENT_IDENTITY=$identity
  if [ "$(fm_herdr_lab_identity_field "$identity" birth)" = "$birth" ] \
    && [ "$(fm_herdr_lab_identity_field "$identity" pgid)" = "$pgid" ]; then
    FM_HERDR_LAB_ALLOCATION_STATE=owned
  else
    FM_HERDR_LAB_ALLOCATION_STATE=reused
  fi
}

# Recheck <pid> against <identity> immediately before sending <signal>.
# Exit 0 sent, 3 positively absent, 2 identity changed (refused), 1 unknown.
fm_herdr_lab_signal_verified() { # <pid> <identity> <signal>
  local pid=$1 expected=$2 signal=$3 current rc=0
  if [ -n "${FM_HERDR_LAB_CANCELLING:-}" ] && [ "$pid" != "${FM_HERDR_LAB_LEADER:-}" ]; then
    fm_herdr_lab_verify_allocation "$FM_HERDR_LAB_CANCELLING" || return 1
  fi
  current=$(fm_herdr_lab_proc_identity "$pid") || rc=$?
  case "$rc" in
    3) return 3 ;;
    0) ;;
    *)
      fm_herdr_lab_error "cannot recheck pid $pid before SIG$signal; refusing to signal an unknown process"
      return 1
      ;;
  esac
  if [ "$(fm_herdr_lab_identity_field "$current" ppid)" = 1 ]; then
    expected="birth=$(fm_herdr_lab_identity_field "$expected" birth) ppid=1 pgid=$(fm_herdr_lab_identity_field "$expected" pgid)"
  fi
  [ "$current" = "$expected" ] || {
    fm_herdr_lab_error "pid $pid no longer matches its recorded identity; refusing SIG$signal (recorded: $expected; current: $current)"
    return 2
  }
  fm_herdr_lab_clip 1 >/dev/null || return 1
  kill -"$signal" "$pid" 2>/dev/null || {
    fm_herdr_lab_error "SIG$signal to pid $pid was not delivered; absence unproved"
    return 1
  }
}

# Poll until <pid> is positively absent or the grace window, clipped to the
# budget left, ends. With no budget left this is one immediate check.
fm_herdr_lab_wait_absent() { # <pid> <grace-seconds>
  local pid=$1 grace=$2 end rc
  grace=$(fm_herdr_lab_clip "$grace") || grace=0
  end=$(( $(fm_herdr_lab_now) + grace ))
  while [ "$(fm_herdr_lab_now)" -lt "$end" ]; do
    rc=0
    fm_herdr_lab_proc_identity "$pid" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 3 ] || return 0
    [ "$(fm_herdr_lab_now)" -lt "$end" ] || return 1
    fm_herdr_lab_pause 0.1 || return 1
  done
  return 1
}

# TERM, wait, then KILL one process, rechecking identity before each signal.
# Exit 0 when it is positively absent afterwards; 1 when it was preserved
# (identity changed or unknown) or survived.
fm_herdr_lab_terminate_verified() { # <pid> <identity>
  local pid=$1 identity=$2 rc=0
  fm_herdr_lab_signal_verified "$pid" "$identity" TERM || rc=$?
  case "$rc" in
    0) ;;
    3) return 0 ;;
    *) return 1 ;;
  esac
  fm_herdr_lab_wait_absent "$pid" 1 && return 0
  rc=0
  fm_herdr_lab_signal_verified "$pid" "$identity" KILL || rc=$?
  case "$rc" in
    0) ;;
    3) return 0 ;;
    *) return 1 ;;
  esac
  fm_herdr_lab_wait_absent "$pid" 1
}

fm_herdr_lab_read_receipt() { # <session> <jq-field>
  local receipt
  receipt=$(fm_herdr_lab_receipt_path "$1")
  [ -f "$receipt" ] || return 1
  jq -r "$2" "$receipt" 2>/dev/null
}

fm_herdr_lab_write_receipt() { # <session> <jq-program> <jq args...>
  local name=$1 program=$2 receipt tmp
  shift 2
  receipt=$(fm_herdr_lab_receipt_path "$name")
  tmp="$receipt.tmp.$$"
  if (umask 077; set -C; jq -nc "$@" "$program" > "$tmp") 2>/dev/null && mv -f "$tmp" "$receipt"; then
    return 0
  fi
  rm -f "$tmp"
  fm_herdr_lab_error "cannot write allocation receipt for '$name'"
  return 1
}

# Consume the allocation receipt for <session>: terminate the recorded direct
# child and each remaining member of its own process group, each after its own
# identity recheck, then remove the receipt only when everything it accounted
# for is positively absent. Anything unknown, reused, or surviving retains the
# receipt and fails.
fm_herdr_lab_capture_members() {
  local name=$1 receipt members member identity rc targets original
  receipt=$(fm_herdr_lab_receipt_path "$name")
  [ "$(jq -r '.pgid' "$receipt")" = "$(jq -r '.pid' "$receipt")" ] || return 1
  targets=$(jq -c '.targets // []' "$receipt") || return 1
  members=$(fm_herdr_lab_group_members "$(jq -r '.pgid' "$receipt")") || return 1
  FM_HERDR_LAB_GROUP_MEMBERS=$members
  original=$targets
  targets=$(printf '%s' "$targets" | jq -c --arg members "$members" \
    '. as $old | . + [$members | split("\n")[] | select(length > 0) | . as $pid | select(all($old[]; .pid != $pid)) | {pid:., identity:""}]') || return 1
  fm_herdr_lab_write_receipt "$name" "\$receipt + {targets:\$targets}" \
    --argjson receipt "$(cat "$receipt")" --argjson targets "$targets" || return 1
  for member in $members; do
    fm_herdr_lab_clip 1 >/dev/null || return 1
    if printf '%s' "$original" | jq -e --arg pid "$member" '.[] | select(.pid == $pid)' >/dev/null; then continue; fi
    rc=0
    identity=$(fm_herdr_lab_proc_identity "$member") || rc=$?
    if [ "$rc" -eq 3 ]; then
      targets=$(printf '%s' "$targets" | jq -c --arg pid "$member" '[.[] | select(.pid != $pid)]') || return 1
    else
      targets=$(printf '%s' "$targets" | jq -c --arg pid "$member" --arg identity "$identity" \
        'map(if .pid == $pid then .identity = $identity else . end)') || return 1
    fi
    fm_herdr_lab_write_receipt "$name" "\$receipt + {targets:\$targets}" \
      --argjson receipt "$(cat "$receipt")" --argjson targets "$targets" || return 1
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || return 1
  done
}

fm_herdr_lab_verify_allocation() {
  local name=$1 receipt pid birth pgid parent current_parent
  receipt=$(fm_herdr_lab_receipt_path "$name")
  pid=$(jq -r '.pid' "$receipt" 2>/dev/null) || return 1
  birth=$(jq -r '.birth' "$receipt") || return 1
  pgid=$(jq -r '.pgid' "$receipt") || return 1
  parent=$(jq -r '.ppid' "$receipt") || return 1
  case "$pid" in ''|0|null|*[!0-9]*) return 1 ;; esac
  fm_herdr_lab_allocation_state "$pid" "$birth" "$pgid"
  case "$FM_HERDR_LAB_ALLOCATION_STATE" in
    owned)
      current_parent=$(fm_herdr_lab_identity_field "$FM_HERDR_LAB_CURRENT_IDENTITY" ppid)
      [ "$current_parent" = "$parent" ] || [ "$current_parent" = 1 ] || return 1
      ;;
    absent) ;;
    reused) fm_herdr_lab_error "pid $pid is now a different process; retaining allocation receipt"; return 1 ;;
    *) fm_herdr_lab_error "cannot read the state of lab server pid $pid; retaining allocation receipt"; return 1 ;;
  esac
}

fm_herdr_lab_destructive_guard() {
  local name=$1 receipt sessions native socket running
  fm_herdr_lab_verify_allocation "$name" || return 1
  receipt=$(fm_herdr_lab_receipt_path "$name")
  sessions=$(fm_herdr_lab_session_list "$name") || return 1
  native=$(printf '%s' "$sessions" | jq -c --arg name "$name" \
    '[.sessions[]? | select(.name == $name and .default == false)] | if length == 1 then .[0] else empty end')
  [ -n "$native" ] || return 1
  socket=$(jq -r '.native.socket_path // empty' "$receipt")
  running=$(printf '%s' "$native" | jq -r '.running')
  if [ -n "$socket" ]; then
    [ "$(printf '%s' "$native" | jq -r '.socket_path')" = "$socket" ] || return 1
  else
    [ "$FM_HERDR_LAB_ALLOCATION_STATE" = owned ] || [ "$running" = false ] || return 1
  fi
  [ "$FM_HERDR_LAB_ALLOCATION_STATE" != absent ] || [ "$running" = false ] || return 1
  fm_herdr_lab_capture_members "$name" || return 1
  fm_herdr_lab_verify_allocation "$name"
}

fm_herdr_lab_cancel_allocation() {
  local name=$1 receipt pid pgid identity member targets survivors unresolved=0 rc entry sessions
  local FM_HERDR_LAB_CANCELLING=$1 FM_HERDR_LAB_LEADER
  receipt=$(fm_herdr_lab_receipt_path "$name")
  fm_herdr_lab_verify_allocation "$name" || return 1
  pid=$(jq -r '.pid' "$receipt")
  FM_HERDR_LAB_LEADER=$pid
  pgid=$(jq -r '.pgid' "$receipt")
  identity=$FM_HERDR_LAB_CURRENT_IDENTITY
  fm_herdr_lab_capture_members "$name" || {
    fm_herdr_lab_error "cannot account for descendants of pid $pid; retaining allocation receipt"
    return 1
  }
  if [ "$FM_HERDR_LAB_ALLOCATION_STATE" = owned ]; then
    fm_herdr_lab_terminate_verified "$pid" "$identity" || {
      fm_herdr_lab_error "lab server pid $pid was not proved gone; retaining allocation receipt"
      return 1
    }
  fi
  targets=$(jq -c '.targets[]?' "$receipt") || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    member=$(printf '%s' "$entry" | jq -r '.pid')
    identity=$(printf '%s' "$entry" | jq -r '.identity')
    rc=0
    fm_herdr_lab_proc_identity "$member" >/dev/null || rc=$?
    [ "$rc" -ne 3 ] || continue
    if [ "$rc" -ne 0 ] || [ "$(fm_herdr_lab_identity_field "$identity" pgid)" != "$pgid" ] \
      || ! fm_herdr_lab_verify_allocation "$name" \
      || ! fm_herdr_lab_terminate_verified "$member" "$identity"; then
      fm_herdr_lab_error "descendant pid $member unproved (recorded: $identity); retaining allocation receipt"
      unresolved=1
    fi
  done <<< "$targets"
  fm_herdr_lab_capture_members "$name" || return 1
  survivors=$FM_HERDR_LAB_GROUP_MEMBERS
  if [ -n "$survivors" ] || [ "$unresolved" -ne 0 ]; then
    fm_herdr_lab_error "lab process group $pgid has unresolved members: $survivors; retaining allocation receipt"
    return 1
  fi
  fm_herdr_lab_verify_allocation "$name" || return 1
  [ "$FM_HERDR_LAB_ALLOCATION_STATE" = absent ] || return 1
  fm_herdr_lab_clip 1 >/dev/null || return 1
  sessions=$(fm_herdr_lab_session_list "$name") || return 1
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null; then
    return 0
  fi
  rm -f "$receipt" "$(fm_herdr_lab_marker_path "$name")" "$(fm_herdr_lab_marker_path "$name").accepted"
}

# Launch the named server as a direct child and bind its identity before any
# poll. Exit 0 with the receipt written; 1 when the child could not be bound
# (it is either positively gone or already recorded for cancellation).
fm_herdr_lab_allocate() {
  local name=$1 marker server_pid content='' identity='' rc=0 ppid pgid birth allocated marker_end receipt pending record
  fm_herdr_lab_private_state || return 1
  fm_herdr_lab_clip 3 >/dev/null || return 1
  marker=$(fm_herdr_lab_marker_path "$name")
  receipt=$(fm_herdr_lab_receipt_path "$name")
  pending="$receipt.pending"
  (umask 077; set -C; : > "$pending") || return 1
  allocated=$(fm_herdr_lab_now)
  marker_end=$(( allocated + $(fm_herdr_lab_clip 2) ))
  rm -f "$marker" "$marker.accepted" "$marker.tmp"
  (umask 077; exec python3 -c 'import os, sys, time
marker, end = sys.argv[1], int(sys.argv[2])
if time.time() >= end:
    sys.exit(1)
os.setsid()
with open(marker + ".tmp", "x") as handle:
    handle.write(str(os.getpid()))
os.replace(marker + ".tmp", marker)
while time.time() < end:
    try:
        with open(marker + ".accepted") as handle:
            if handle.read() == str(os.getpid()):
                os.execvp(sys.argv[3], sys.argv[3:])
    except FileNotFoundError:
        pass
    time.sleep(0.01)
sys.exit(1)' "$marker" "$marker_end" env HERDR_SESSION="$name" herdr server --session "$name") >/dev/null 2>&1 &
  server_pid=$!
  while [ "$(fm_herdr_lab_now)" -lt "$marker_end" ]; do
    content=$(cat "$marker" 2>/dev/null) || content=
    [ "$content" != "$server_pid" ] || break
    fm_herdr_lab_pause 0.05 || break
  done
  identity=$(fm_herdr_lab_proc_identity "$server_pid") || rc=$?
  if [ "$rc" -eq 3 ]; then
    rm -f "$pending" "$marker"
    fm_herdr_lab_error "lab server for '$name' exited before its identity could be bound"
    return 1
  fi
  ppid=$(fm_herdr_lab_identity_field "$identity" ppid) || ppid=unknown
  pgid=$(fm_herdr_lab_identity_field "$identity" pgid) || pgid=unknown
  birth=$(fm_herdr_lab_identity_field "$identity" birth) || birth=unknown
  record=$(jq -nc --arg name "$name" --argjson pid "$server_pid" --arg birth "$birth" \
    --arg ppid "$ppid" --arg pgid "$pgid" --argjson allocated "$allocated" --argjson deadline "$FM_HERDR_LAB_DEADLINE" \
    --arg command "herdr server --session $name" \
    '{name:$name,pid:$pid,birth:$birth,ppid:($ppid|try tonumber catch $ppid),pgid:($pgid|try tonumber catch $pgid),own_group:($pgid == ($pid|tostring)),allocated_epoch:$allocated,deadline_epoch:$deadline,command_description:$command,native:null}')
  if [ -z "$record" ] || ! printf '%s\n' "$record" > "$pending"; then
    fm_herdr_lab_error "allocation publication failed: pid $server_pid identity $identity; receipt not published; record=$record"
    [ "$rc" -ne 0 ] || fm_herdr_lab_terminate_verified "$server_pid" "$identity" || true
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ "$content" != "$server_pid" ] || [ "$ppid" != "${BASHPID:-$$}" ] || [ "$pgid" != "$server_pid" ]; then
    fm_herdr_lab_error "unbound allocation pid $server_pid identity $identity; evidence retained at $pending"
    if [ "$rc" -eq 0 ] && [ "$ppid" = "${BASHPID:-$$}" ] && [ "$pgid" = "$server_pid" ]; then
      fm_herdr_lab_cancel_allocation "$name" || true
    fi
    return 1
  fi
  if ! mv -f "$pending" "$receipt"; then
    fm_herdr_lab_error "cannot publish allocation receipt for pid $server_pid ($identity); pending evidence at $pending"
    fm_herdr_lab_cancel_allocation "$name" || true
    return 1
  fi
  if ! (umask 077; set -C; printf '%s' "$server_pid" > "$marker.accepted"); then
    fm_herdr_lab_cancel_allocation "$name" || true
    return 1
  fi
}

# Bind the native evidence Herdr supplies for the running lab: its socket_path
# and running flag from session list. Only fields the CLI actually returns are
# recorded; nothing is inferred from the name.
fm_herdr_lab_bind_native() { # <session>
  local name=$1 sessions native receipt
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read the lab session record to bind native evidence for '$name'"
    return 1
  }
  native=$(printf '%s' "$sessions" | jq -c --arg name "$name" \
    '[.sessions[]? | select(.name == $name and .default == false and .running == true) | {socket_path, running}] | if length == 1 then .[0] else empty end' 2>/dev/null)
  [ -n "$native" ] || {
    fm_herdr_lab_error "lab session '$name' reported running but session list has no single non-default running record for it"
    return 1
  }
  fm_herdr_lab_verify_allocation "$name" || return 1
  [ "$FM_HERDR_LAB_ALLOCATION_STATE" = owned ] || return 1
  receipt=$(fm_herdr_lab_receipt_path "$name")
  # shellcheck disable=SC2016  # jq program: $receipt, $native, $bound are jq variables.
  fm_herdr_lab_write_receipt "$name" '$receipt + {native: ($native + {bound_epoch: $bound})}' \
    --argjson receipt "$(cat "$receipt")" --argjson native "$native" --argjson bound "$(fm_herdr_lab_now)" || return 1
  fm_herdr_lab_verify_allocation "$name" || return 1
  [ "$FM_HERDR_LAB_ALLOCATION_STATE" = owned ]
}

fm_herdr_lab_provision_impl() { # <session>
  local name=$1 sessions tripwire running=false attempt receipt pid status_json poll_status
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }
  command -v python3 >/dev/null 2>&1 || { fm_herdr_lab_error "python3 is required for isolated provision ownership"; return 1; }
  command -v ps >/dev/null 2>&1 || { fm_herdr_lab_error "ps is required for provision ownership"; return 1; }
  fm_herdr_lab_private_state || return 1
  receipt=$(fm_herdr_lab_receipt_path "$name")
  if [ -e "$receipt" ]; then
    # Only a positively absent server clears a retained receipt; anything
    # alive, reused, or unreadable is an uncertain cleanup and blocks re-provision.
    pid=$(fm_herdr_lab_read_receipt "$name" '.pid')
    fm_herdr_lab_allocation_state "$pid" "$(fm_herdr_lab_read_receipt "$name" '.birth')" "$(fm_herdr_lab_read_receipt "$name" '.pgid')"
    case "$FM_HERDR_LAB_ALLOCATION_STATE" in
      absent)
        fm_herdr_lab_cancel_allocation "$name" || return 1
        rm -f "$receipt"
        ;;
      owned)
        fm_herdr_lab_error "retained allocation receipt for '$name': its server pid $pid is still alive; reconcile it with teardown before provisioning again"
        return 1
        ;;
      *)
        fm_herdr_lab_error "retained allocation receipt for '$name': server pid $pid is $FM_HERDR_LAB_ALLOCATION_STATE; reconcile it with teardown before provisioning again"
        return 1
        ;;
    esac
  fi

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      fm_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    fm_herdr_lab_check_tripwire "$name" || return 1
  else
    fm_herdr_lab_prepare_from_sessions "$name" "$sessions" || return 1
  fi

  fm_herdr_lab_allocate "$name" || return 1
  attempt=0
  FM_HERDR_LAB_RESERVE=$FM_HERDR_LAB_CLEANUP_RESERVE_SECS
  while [ "$attempt" -lt "$FM_HERDR_LAB_MAX_POLLS" ] && fm_herdr_lab_clip 1 >/dev/null 2>&1; do
    poll_status=0
    status_json=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null) || poll_status=$?
    running=$(printf '%s' "$status_json" | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      if fm_herdr_lab_refuse_if_default "$name" && fm_herdr_lab_bind_native "$name"; then
        FM_HERDR_LAB_RESERVE=0
        return 0
      fi
      break
    fi
    if [ "$poll_status" -ne 124 ]; then fm_herdr_lab_pause 0.2 || break; fi
    attempt=$((attempt + 1))
  done
  FM_HERDR_LAB_RESERVE=0
  fm_herdr_lab_cancel_allocation "$name" || true
  if [ "$running" = true ]; then
    fm_herdr_lab_error "lab session '$name' reported running but could not be verified as a non-default owned lab; cancellation attempted"
  else
    fm_herdr_lab_error "lab session '$name' did not report running within the $FM_HERDR_LAB_BUDGET_SECS-second aggregate budget"
  fi
  return 1
}

fm_herdr_lab_provision() { # <session>
  fm_herdr_lab_with_budget fm_herdr_lab_provision_impl "$1"
}

fm_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire before after
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  before=$(cat "$tripwire")
  after=$(fm_herdr_lab_fleet_state "$name") || return 1
  [ "$before" = "$after" ] || {
    fm_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: default session changed during lab work"
    fm_herdr_lab_error "before: $before"
    fm_herdr_lab_error "after:  $after"
    return 1
  }
}

fm_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  rm -f "$tripwire"
}

fm_herdr_lab_stop_impl() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  fm_herdr_lab_private_state || return 1
  fm_herdr_lab_destructive_guard "$name" || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json
}

fm_herdr_lab_stop() { # <session>
  fm_herdr_lab_with_budget fm_herdr_lab_stop_impl "$1"
}

# Reconcile a retained allocation receipt once the lab session itself is gone:
# a positively absent server clears it, an owned live server is terminated
# with rechecks, and anything else retains it.
fm_herdr_lab_reconcile_receipt() { # <session>
  local name=$1 receipt
  receipt=$(fm_herdr_lab_receipt_path "$name")
  [ -f "$receipt" ] || return 0
  fm_herdr_lab_cancel_allocation "$name"
}

fm_herdr_lab_teardown_impl() { # <session>
  local name=$1 tripwire sessions delete_status=0 cleanup_failed=0
  fm_herdr_lab_validate_name "$name" || return 1
  fm_herdr_lab_private_state || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    # Never turn a failed/uncertain stop into an attempted delete. Preserve the
    # tripwire so an operator can reconcile the exact named lab safely.
    if ! fm_herdr_lab_stop_impl "$name" >/dev/null; then
      fm_herdr_lab_error "session stop failed for '$name'; not attempting delete"
      cleanup_failed=1
    else
      if ! fm_herdr_lab_destructive_guard "$name"; then
        cleanup_failed=1
      else
        fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
        if sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null); then
          if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
            if [ "$delete_status" -ne 0 ]; then
              fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
            else
              fm_herdr_lab_error "lab session '$name' remains after teardown"
            fi
            cleanup_failed=1
          fi
        else
          fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
          cleanup_failed=1
        fi
      fi
    fi
  fi
  if [ "$cleanup_failed" -eq 0 ]; then
    fm_herdr_lab_reconcile_receipt "$name" || cleanup_failed=1
  fi
  # The tripwire is always evaluated, and its failure is the primary result.
  if ! fm_herdr_lab_check_tripwire "$name"; then
    [ "$cleanup_failed" -eq 0 ] || fm_herdr_lab_error "cleanup of '$name' also failed; see above"
    return 1
  fi
  [ "$cleanup_failed" -eq 0 ] || return 1
  rm -f "$tripwire"
}

fm_herdr_lab_teardown() { # <session>
  fm_herdr_lab_with_budget fm_herdr_lab_teardown_impl "$1"
}

fm_herdr_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf 'fm-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

fm_herdr_lab_usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_provision "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli "$@"
      ;;
    stop)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_teardown "$2"
      ;;
    -h|--help|help)
      fm_herdr_lab_usage
      ;;
    *)
      fm_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_lab_main "$@"
fi
