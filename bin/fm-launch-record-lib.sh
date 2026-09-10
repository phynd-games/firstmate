#!/usr/bin/env bash
# fm-launch-record-lib.sh - the shell seam every launch or control owner uses to
# talk to the launch-record contract owned by bin/fm-launch-record.py.
#
# This file adds no policy of its own: it resolves the interpreter and the
# record owner once, forwards every call with this home's state directory, and
# gives owners three small helpers so the calling convention cannot drift:
#
#   fm_launch_record <command> [args...]
#       Forward one command. Exit codes are the owner's: 0 ok, 1 read/write
#       failure, 2 usage, 3 contract refusal. stderr is left to the caller.
#   fm_launch_record_available
#       0 when python3 and the owner script are usable, else 1 with the reason
#       on stderr. Launch owners call this BEFORE any external creation so a
#       missing interpreter refuses the launch instead of skipping the record.
#   fm_launch_record_launcher_args <launcher-pid>
#       Prints the `--launcher-pid <pid> --launcher-identity <identity>` pair
#       for the calling process, so a later launcher can tell an interrupted
#       spawn (launcher gone) from a concurrent one (launcher alive) by pid
#       PLUS start identity, never pid alone. The identity string is hashed by
#       the owner before it is stored.
#
# FM_LAUNCH_RECORD_PYTHON selects the interpreter (default: python3 on PATH).
# The state directory follows the same override the rest of the fleet uses:
# FM_STATE_OVERRIDE, else $FM_HOME/state, else <FM_ROOT>/state.

fm_launch_record_root() {
  if [ -n "${FM_ROOT:-}" ]; then
    printf '%s' "$FM_ROOT"
  else
    printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
}

fm_launch_record_state_dir() {
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s' "$FM_STATE_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/state' "$FM_HOME"
  else
    printf '%s/state' "$(fm_launch_record_root)"
  fi
}

fm_launch_record_python() {
  printf '%s' "${FM_LAUNCH_RECORD_PYTHON:-python3}"
}

fm_launch_record_owner() {
  # The owner lives beside this library in the same bin/, so a caller that
  # points FM_ROOT_OVERRIDE at a fixture root for other reasons still reaches
  # the real owner. FM_LAUNCH_RECORD_OWNER is a test-only override.
  if [ -n "${FM_LAUNCH_RECORD_OWNER:-}" ]; then
    printf '%s' "$FM_LAUNCH_RECORD_OWNER"
  else
    printf '%s/fm-launch-record.py' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
}

fm_launch_record_available() {
  local python owner
  python=$(fm_launch_record_python)
  owner=$(fm_launch_record_owner)
  if ! command -v "$python" >/dev/null 2>&1; then
    echo "error: the launch-record owner needs python3 (set FM_LAUNCH_RECORD_PYTHON or install python3); refusing to launch without a durable launch record" >&2
    return 1
  fi
  if [ ! -f "$owner" ]; then
    echo "error: the launch-record owner $owner is missing; refusing to launch without a durable launch record" >&2
    return 1
  fi
  return 0
}

fm_launch_record() {
  local python owner state
  python=$(fm_launch_record_python)
  owner=$(fm_launch_record_owner)
  state=$(fm_launch_record_state_dir)
  "$python" "$owner" --state "$state" "$@"
}

fm_launch_record_launcher_args() {
  local pid=${1:?launcher pid required} identity
  identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    printf -- '--launcher-pid\n%s\n--launcher-identity\n%s\n' "$pid" "$identity"
  else
    printf -- '--launcher-pid\n%s\n' "$pid"
  fi
}
