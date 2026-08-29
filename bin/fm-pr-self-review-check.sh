#!/usr/bin/env bash
# Validate the durable findings-first self-review before a ship task becomes ready.
# Usage: fm-pr-self-review-check.sh <task-id> <no-mistakes|direct-PR|local-only>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SUBSTRATE_ROOT="${FM_SUBSTRATE_ROOT_OVERRIDE:-$FM_ROOT}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid self-review check request" >&2
  exit 2
fi
ID=$1
MODE=$2
fm_pr_task_id_valid "$ID" || { echo "error: invalid self-review check request" >&2; exit 2; }
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "error: invalid self-review delivery mode" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
[ "$(grep -c '^kind=' "$META" || true)" = 1 ] && [ "$(grep '^kind=' "$META" | cut -d= -f2- || true)" = ship ] || {
  echo "error: self-review check requires exactly one kind=ship" >&2
  exit 1
}
[ "$(grep -c '^mode=' "$META" || true)" = 1 ] && [ "$(grep '^mode=' "$META" | cut -d= -f2- || true)" = "$MODE" ] || {
  echo "error: self-review check mode does not match task metadata" >&2
  exit 1
}
[ "$(grep -c '^worktree=' "$META" || true)" = 1 ] || {
  echo "error: self-review check requires exactly one worktree" >&2
  exit 1
}
WT=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
[ -n "$WT" ] && [ -d "$WT" ] && [ ! -L "$WT" ] || {
  echo "error: PR-ready task worktree is unavailable" >&2
  exit 1
}
HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
fm_pr_head_valid "$HEAD" || {
  echo "error: PR-ready task worktree has no valid HEAD" >&2
  exit 1
}
SUBSTRATE_LAUNCH_SHA=$(fm_pr_substrate_launch_sha "$DATA" "$ID" || true)
if ! fm_pr_self_review_report_valid "$DATA" "$ID" "$HEAD" "$WT" "$SUBSTRATE_ROOT" "$SUBSTRATE_LAUNCH_SHA"; then
  echo "error: durable findings-first self-review report is unavailable or invalid" >&2
  exit 1
fi
printf 'validated: durable findings-first self-review report for %s\n' "$ID"
