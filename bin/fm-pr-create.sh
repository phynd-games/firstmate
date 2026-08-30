#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -lt 1 ]; then
  echo "error: usage: fm-pr-create.sh <task-id> [gh-axi pr create arguments...]" >&2
  exit 2
fi
ID=$1
shift
[ "$#" -gt 0 ] || {
  echo "error: gh-axi pr create arguments are required" >&2
  exit 2
}
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SUBSTRATE_ROOT="${FM_SUBSTRATE_ROOT_OVERRIDE:-$FM_ROOT}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_pr_task_id_valid "$ID" || { echo "error: invalid direct PR task" >&2; exit 2; }
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
META_LOCK_HELD=0
DELIVERY_LOCK=
DELIVERY_LOCK_HELD=0
pr_create_cleanup() {
  if [ "$DELIVERY_LOCK_HELD" = 1 ]; then
    fm_lease_guard_release || true
    DELIVERY_LOCK_HELD=0
  fi
  [ -z "$DELIVERY_LOCK" ] || fm_lock_release "$DELIVERY_LOCK" || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_create_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
DELIVERY_LOCK=$(fm_pr_delivery_lock_path "$STATE" "$ID") || exit 1
fm_lock_acquire_wait "$DELIVERY_LOCK"
fm_lease_guard "$ID" "direct PR creation (fm-pr-create)"
DELIVERY_LOCK_HELD=1
"$SCRIPT_DIR/fm-pr-self-review-check.sh" "$ID" direct-PR
[ "$(grep -c '^worktree=' "$META" || true)" = 1 ] || {
  echo "error: direct PR task metadata must name exactly one worktree" >&2
  exit 1
}
WT=$(sed -n 's/^worktree=//p' "$META")
[ -n "$WT" ] && [ -d "$WT" ] && [ ! -L "$WT" ] || {
  echo "error: direct PR task worktree is unavailable" >&2
  exit 1
}
WT_REAL=$(cd "$WT" && pwd -P) || {
  echo "error: direct PR task worktree cannot be resolved" >&2
  exit 1
}
GIT_ROOT=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
GIT_ROOT_REAL=$(cd "$GIT_ROOT" 2>/dev/null && pwd -P || true)
[ -n "$GIT_ROOT_REAL" ] && [ "$GIT_ROOT_REAL" = "$WT_REAL" ] || {
  echo "error: direct PR task worktree is not the reviewed repository" >&2
  exit 1
}
BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$BRANCH" = "fm/$ID" ] || {
  echo "error: direct PR task is not on its reviewed branch fm/$ID" >&2
  exit 1
}
HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
fm_pr_head_valid "$HEAD" || { echo "error: direct PR task has no reviewed head" >&2; exit 1; }
fm_pr_git_remote_identity "$WT" || {
  echo "error: direct PR task has no valid forge repository" >&2
  exit 1
}
REVIEW_BASE=$(fm_pr_review_base_from_meta "$META") || {
  echo "error: direct PR task has no approved target base" >&2
  exit 1
}
IFS="$(printf '\t')" read -r REVIEW_BASE_REF REVIEW_BASE_SHA <<EOF
$REVIEW_BASE
EOF
REVIEW_BASE_BRANCH=$(fm_pr_review_base_branch "$REVIEW_BASE_REF") || {
  echo "error: direct PR task has no branch-shaped approved target base" >&2
  exit 1
}
[ "$FM_PR_REMOTE_PROVIDER" = github ] || {
  echo "error: direct PR creation requires a GitHub reviewed repository" >&2
  exit 1
}
ORIGIN_BEFORE=$(git -C "$WT" remote get-url origin 2>/dev/null) || {
  echo "error: direct PR task has no origin repository" >&2
  exit 1
}
REPORT=$(fm_pr_self_review_report_path "$DATA" "$ID") || exit 1
REPORT_HASH=$(fm_pr_sha256 "$REPORT") || exit 1
SUBSTRATE_HEAD=$(git -C "$SUBSTRATE_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
fm_pr_head_valid "$SUBSTRATE_HEAD" || { echo "error: direct PR task has no reviewed substrate head" >&2; exit 1; }
for arg in "$@"; do
  case "$arg" in
    --repo|--repo=*|-R|--head|--head=*|-*R*|-*H*)
      echo "error: direct PR creation cannot override the reviewed repository or branch" >&2
      exit 2
      ;;
    --hostname|--hostname=*|--base|--base=*|-B|-B*)
      echo "error: direct PR creation cannot override the reviewed forge host or approved base" >&2
      exit 2
      ;;
  esac
done
command -v gh-axi >/dev/null 2>&1 || {
  echo "error: gh-axi is required to create a pull request" >&2
  exit 1
}
[ "$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" = "$HEAD" ] || {
  echo "error: direct PR task head changed after review" >&2
  exit 1
}
[ "$(fm_pr_sha256 "$REPORT")" = "$REPORT_HASH" ] || {
  echo "error: direct PR self-review report changed after validation" >&2
  exit 1
}
[ "$(git -C "$WT" remote get-url origin 2>/dev/null || true)" = "$ORIGIN_BEFORE" ] || {
  echo "error: direct PR task repository changed after review" >&2
  exit 1
}
[ "$(git -C "$SUBSTRATE_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" = "$SUBSTRATE_HEAD" ] \
  && [ -z "$(git -C "$SUBSTRATE_ROOT" status --porcelain 2>/dev/null)" ] || {
  echo "error: direct PR substrate changed after review" >&2
  exit 1
}
cd "$WT"
GH_HOST="$FM_PR_REMOTE_HOST" gh-axi pr create --repo "$FM_PR_REMOTE_PATH" --head "$BRANCH" --base "$REVIEW_BASE_BRANCH" "$@"
