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
"$SCRIPT_DIR/fm-pr-self-review-check.sh" "$ID" direct-PR
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
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
for arg in "$@"; do
  case "$arg" in
    --repo|--repo=*|-R|--head|--head=*|-*R*|-*H*)
      echo "error: direct PR creation cannot override the reviewed repository or branch" >&2
      exit 2
      ;;
  esac
done
command -v gh-axi >/dev/null 2>&1 || {
  echo "error: gh-axi is required to create a pull request" >&2
  exit 1
}
cd "$WT"
exec gh-axi pr create "$@"
