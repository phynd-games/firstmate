#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
# A selector whose meta records remote_host= is a remote secondmate: its pane
# lives on that host, so the capture routes over fm-on.sh to the host-local
# capture (fm-remote-secondmate-control.sh), clamped to that command's
# 100-line cap. An unreachable host or unreadable endpoint fails loudly naming
# the host; the local backend adapters are never asked to read a remote target.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

RAW_TARGET=$1
N=${2:-40}

REMOTE_META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
if [ -n "$REMOTE_META" ] && [ -n "$(fm_meta_get "$REMOTE_META" remote_host)" ]; then
  REMOTE_ID=${REMOTE_META##*/}
  REMOTE_ID=${REMOTE_ID%.meta}
  REMOTE_HOST=$(fm_meta_get "$REMOTE_META" remote_host)
  fm_backend_validate_remote_task_endpoint "$REMOTE_META" "$REMOTE_ID" fm-remote || {
    fm_backend_refuse_remote_task_endpoint "$REMOTE_META" "$REMOTE_ID"
    exit 1
  }
  remote_preflight_output= remote_preflight_rc=0
  if remote_preflight_output=$("$SCRIPT_DIR/fm-on.sh" "$REMOTE_ID" \
    fm-remote-secondmate-control.sh route "$REMOTE_ID" < /dev/null 2>&1); then
    :
  else
    remote_preflight_rc=$?
    remote_refusal=$(printf '%s\n' "$remote_preflight_output" | sed -n '/^REFUSED: /{p;q;}')
    if [ -n "$remote_refusal" ]; then
      printf '%s\n' "$remote_refusal" >&2
    else
      printf 'error: could not verify the remote pane of %s on %s through Herdr (host unreachable or capability unreadable; the mate is not thereby dead)\n' \
        "$REMOTE_ID" "$REMOTE_HOST" >&2
    fi
    exit "$remote_preflight_rc"
  fi
  remote_guard_output=$("$SCRIPT_DIR/fm-guard.sh" 2>&1 || true)
  case "$N" in ''|*[!0-9]*|0) N=40 ;; esac
  [ "$N" -le 100 ] || N=100
  remote_output= remote_rc=0
  if remote_output=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$REMOTE_ID" \
    fm-remote-secondmate-control.sh capture "$REMOTE_ID" "$N" < /dev/null 2>&1); then
    [ -z "$remote_guard_output" ] || printf '%s\n' "$remote_guard_output" >&2
    [ -z "$remote_output" ] || printf '%s\n' "$remote_output"
  else
    remote_rc=$?
    remote_refusal=$(printf '%s\n' "$remote_output" | sed -n '/^REFUSED: /{p;q;}')
    if [ -n "$remote_refusal" ]; then
      printf '%s\n' "$remote_refusal" >&2
    else
      [ -z "$remote_guard_output" ] || printf '%s\n' "$remote_guard_output" >&2
      [ -z "$remote_output" ] || printf '%s\n' "$remote_output" >&2
      echo "error: could not read the remote pane of $REMOTE_ID on $REMOTE_HOST (host unreachable or endpoint unreadable; the mate is not thereby dead)" >&2
    fi
    exit "$remote_rc"
  fi
  exit 0
fi

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")

# A legacy (absent or non-herdr) record is refused here by name and never read.
BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE") || exit 1
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

"$SCRIPT_DIR/fm-guard.sh" || true

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
