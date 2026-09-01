#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a stale approved
# base or diverged branch and requires a new self-review. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SUBSTRATE_ROOT=
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
ID=${1:?usage: fm-merge-local.sh <task-id> [--reconcile]}
RECONCILE=0
case "${2-}" in
  '') ;;
  --reconcile) RECONCILE=1 ;;
  *) echo "error: usage: fm-merge-local.sh <task-id> [--reconcile]" >&2; exit 2 ;;
esac
fm_pr_task_id_valid "$ID" || { echo "error: invalid local-only task" >&2; exit 2; }
SUBSTRATE_ROOT=$(fm_pr_substrate_root_from_brief "$DATA/$ID/brief.md" || true)
[ -n "$SUBSTRATE_ROOT" ] || {
  echo "error: local-only task has no authoritative Firstmate substrate root" >&2
  exit 1
}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
META_LOCK_HELD=0
DELIVERY_LOCK=
DELIVERY_LOCK_HELD=0
META_TMP=
BRIEF_TMP=
META_BACKUP=
BRIEF_BACKUP=
merge_local_cleanup() {
  rm -f "$META_TMP" "$BRIEF_TMP" "$META_BACKUP" "$BRIEF_BACKUP" 2>/dev/null || true
  if [ "$DELIVERY_LOCK_HELD" = 1 ]; then
    fm_lock_release "$DELIVERY_LOCK" || true
    DELIVERY_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap merge_local_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
DELIVERY_LOCK=$(fm_pr_delivery_lock_path "$STATE" "$ID") || exit 1
fm_lock_acquire_wait "$DELIVERY_LOCK"
DELIVERY_LOCK_HELD=1

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
[ -n "$WT" ] && [ -d "$WT" ] && [ ! -L "$WT" ] || {
  echo "error: local-only task worktree is unavailable" >&2
  exit 1
}
[ "$(fm_pr_git_common_dir "$PROJ" 2>/dev/null || true)" = "$(fm_pr_git_common_dir "$WT" 2>/dev/null || true)" ] \
  && [ -n "$(fm_pr_git_common_dir "$PROJ" 2>/dev/null || true)" ] || {
  echo "error: local-only project is not the reviewed repository" >&2
  exit 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }
DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
DEFAULT_SHA=$(git -C "$PROJ" rev-parse --verify "refs/heads/$DEFAULT^{commit}" 2>/dev/null || true)

REVIEW_BASE=$(fm_pr_review_base_from_meta "$META" || true)
[ -n "$REVIEW_BASE" ] || { echo "error: local-only task has no valid approved review base" >&2; exit 1; }
IFS="$(printf '\t')" read -r REVIEW_BASE_REF REVIEW_BASE_SHA <<EOF
$REVIEW_BASE
EOF

if [ "$RECONCILE" -eq 1 ]; then
  [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ] || {
    echo "error: reconcile requires a clean task worktree" >&2
    exit 1
  }
  [ "$(git -C "$PROJ" rev-parse --verify "refs/heads/$BRANCH")" = "$(git -C "$WT" rev-parse --verify 'HEAD^{commit}')" ] || {
    echo "error: local-only branch is not the task worktree head" >&2
    exit 1
  }
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
    echo "error: reconcile the task branch with $DEFAULT first, then rerun --reconcile" >&2
    exit 1
  fi
  BRIEF="$DATA/$ID/brief.md"
  [ "$(grep -c '^Target-project approved base:' "$BRIEF" || true)" = 1 ] || {
    echo "error: local-only brief has no single approved target base" >&2
    exit 1
  }
  META_TMP=$(mktemp "$META.reconcile.XXXXXX") || exit 1
  BRIEF_TMP=$(mktemp "$BRIEF.reconcile.XXXXXX") || { rm -f "$META_TMP"; exit 1; }
  META_BACKUP=$(mktemp "$META.backup.XXXXXX") || { rm -f "$META_TMP" "$BRIEF_TMP"; exit 1; }
  BRIEF_BACKUP=$(mktemp "$BRIEF.backup.XXXXXX") || { rm -f "$META_TMP" "$BRIEF_TMP" "$META_BACKUP"; exit 1; }
  cp "$META" "$META_BACKUP"
  cp "$BRIEF" "$BRIEF_BACKUP"
  if ! awk -v ref="$DEFAULT" -v sha="$DEFAULT_SHA" '
    BEGIN { ref_seen = 0; sha_seen = 0 }
    /^review_base_ref=/ { print "review_base_ref=" ref; ref_seen++; next }
    /^review_base_sha=/ { print "review_base_sha=" sha; sha_seen++; next }
    { print }
    END { exit (ref_seen == 1 && sha_seen == 1) ? 0 : 1 }
  ' "$META" > "$META_TMP"; then
    rm -f "$META_TMP" "$BRIEF_TMP" "$META_BACKUP" "$BRIEF_BACKUP"
    exit 1
  fi
  if ! awk -v ref="$DEFAULT" -v sha="$DEFAULT_SHA" '
    BEGIN { seen = 0 }
    /^Target-project approved base:/ { print "Target-project approved base: ref=" ref "; sha=" sha; seen++; next }
    { print }
    END { exit seen == 1 ? 0 : 1 }
  ' "$BRIEF" > "$BRIEF_TMP"; then
    rm -f "$META_TMP" "$BRIEF_TMP" "$META_BACKUP" "$BRIEF_BACKUP"
    exit 1
  fi
  chmod 600 "$META_TMP" "$BRIEF_TMP"
  mv -f "$META_TMP" "$META"
  if ! mv -f "$BRIEF_TMP" "$BRIEF"; then
    cp "$META_BACKUP" "$META"
    cp "$BRIEF_BACKUP" "$BRIEF"
    rm -f "$META_TMP" "$BRIEF_TMP" "$META_BACKUP" "$BRIEF_BACKUP"
    exit 1
  fi
  rm -f "$META_BACKUP" "$BRIEF_BACKUP"
  REPORT=$(fm_pr_self_review_report_path "$DATA" "$ID") || exit 1
  rm -f "$REPORT"
  echo "reconciled $ID to approved base $DEFAULT ($DEFAULT_SHA); complete a new self-review before landing"
  exit 0
fi

REVIEW_HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
fm_pr_head_valid "$REVIEW_HEAD" || { echo "error: local-only task has no reviewed head" >&2; exit 1; }
[ "$(git -C "$PROJ" rev-parse --verify "refs/heads/$BRANCH")" = "$REVIEW_HEAD" ] || {
  echo "error: local-only branch is not the reviewed head" >&2
  exit 1
}
REPORT=$(fm_pr_self_review_report_path "$DATA" "$ID") || exit 1
REPORT_HASH=$(fm_pr_sha256 "$REPORT") || exit 1
"$FM_ROOT/bin/fm-pr-self-review-check.sh" "$ID" local-only

[ "$DEFAULT_SHA" = "$REVIEW_BASE_SHA" ] || {
  echo "REFUSED: $DEFAULT has advanced beyond the approved review base $REVIEW_BASE_SHA." >&2
  echo "Reconcile $BRANCH with the current $DEFAULT, then run fm-merge-local.sh $ID --reconcile and complete a new self-review before retrying." >&2
  exit 1
}

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi
[ "$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" = "$REVIEW_HEAD" ] \
  && [ "$(git -C "$PROJ" rev-parse --verify "refs/heads/$BRANCH" 2>/dev/null || true)" = "$REVIEW_HEAD" ] \
  && [ "$(fm_pr_sha256 "$REPORT")" = "$REPORT_HASH" ] || {
  echo "error: local-only reviewed inputs changed after validation" >&2
  exit 1
}

# Clean fast-forward only: DEFAULT must be the exact reviewed base and an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Reconcile $BRANCH with the current $DEFAULT, then complete a new self-review before retrying." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$REVIEW_HEAD" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
