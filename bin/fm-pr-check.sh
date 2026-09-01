#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SUBSTRATE_ROOT=

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
SUBSTRATE_ROOT=$(fm_pr_substrate_root_from_brief "$DATA/$ID/brief.md" || true)
[ -n "$SUBSTRATE_ROOT" ] || {
  echo "error: PR-ready task has no authoritative Firstmate substrate root" >&2
  exit 1
}
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
META_TMP=
META_LOCK=
META_LOCK_HELD=0
DELIVERY_LOCK=
DELIVERY_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
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
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
DELIVERY_LOCK=$(fm_pr_delivery_lock_path "$STATE" "$ID") || exit 1
fm_lock_acquire_wait "$DELIVERY_LOCK"
fm_lease_guard "$ID" "PR-ready publication (fm-pr-check)"
DELIVERY_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
KIND_COUNT=$(grep -c '^kind=' "$META" || true)
MODE_COUNT=$(grep -c '^mode=' "$META" || true)
KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$KIND_COUNT" = 1 ] && [ "$KIND" = ship ] || {
  echo "error: PR-ready task metadata must contain exactly one kind=ship" >&2
  exit 1
}
[ "$MODE_COUNT" = 1 ] || {
  echo "error: PR-ready task metadata must contain exactly one delivery mode" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR) ;;
  local-only)
    echo "error: local-only tasks must use fm-merge-local.sh" >&2
    exit 1
    ;;
  *) echo "error: PR-ready task metadata has an invalid delivery mode" >&2; exit 1 ;;
esac
[ "$(grep -c '^worktree=' "$META" || true)" = 1 ] || {
  echo "error: PR-ready task metadata must contain exactly one worktree" >&2
  exit 1
}
REVIEW_BASE=$(fm_pr_review_base_from_meta "$META" || true)
[ -n "$REVIEW_BASE" ] || {
  echo "error: PR-ready task metadata has no approved target base" >&2
  exit 1
}
IFS="$(printf '\t')" read -r REVIEW_BASE_REF REVIEW_BASE_SHA <<EOF
$REVIEW_BASE
EOF
REVIEW_BASE_BRANCH=$(fm_pr_review_base_branch "$REVIEW_BASE_REF") || {
  echo "error: PR-ready task metadata has no branch-shaped approved target base" >&2
  exit 1
}
WT=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
[ -n "$WT" ] && [ -d "$WT" ] && [ ! -L "$WT" ] && command -v git >/dev/null 2>&1 || {
  echo "error: PR-ready task worktree is unavailable" >&2
  exit 1
}
fm_pr_git_remote_matches "$WT" "$PROVIDER" "$HOST" "$PROJECT_PATH" || {
  echo "error: PR-ready URL does not identify the reviewed repository" >&2
  exit 1
}
REVIEW_HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
fm_pr_head_valid "$REVIEW_HEAD" || {
  echo "error: PR-ready task worktree has no valid HEAD" >&2
  exit 1
}
SUBSTRATE_HEAD=$(git -C "$SUBSTRATE_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
fm_pr_head_valid "$SUBSTRATE_HEAD" || {
  echo "error: PR-ready substrate has no valid HEAD" >&2
  exit 1
}
SUBSTRATE_LAUNCH_SHA=$(fm_pr_substrate_launch_sha "$DATA" "$ID" || true)
if ! fm_pr_self_review_report_valid "$DATA" "$ID" "$REVIEW_HEAD" "$WT" "$SUBSTRATE_ROOT" "$REVIEW_BASE_REF" "$REVIEW_BASE_SHA" "$SUBSTRATE_LAUNCH_SHA"; then
  echo "error: durable findings-first self-review report is unavailable or invalid" >&2
  exit 1
fi
REPORT=$(fm_pr_self_review_report_path "$DATA" "$ID") || exit 1
REPORT_HASH=$(fm_pr_sha256 "$REPORT") || exit 1

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head binds the registered PR/MR to the exact reviewed worktree head.
PR_HEAD=
if [ "$PROVIDER" = github ]; then
  command -v gh >/dev/null 2>&1 || { echo "error: GitHub PR head could not be verified" >&2; exit 1; }
  REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) || {
    echo "error: GitHub PR head could not be verified" >&2
    exit 1
  }
  REMOTE_BASE=$(cd "$WT" && gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) || {
    echo "error: GitHub PR base could not be verified" >&2
    exit 1
  }
else
  command -v glab >/dev/null 2>&1 || { echo "error: GitLab MR head could not be verified" >&2; exit 1; }
  GITLAB_PROJECT_URL="https://$HOST/$PROJECT_PATH"
  GITLAB_JSON=$(GITLAB_HOST="$HOST" glab mr view "$NUMBER" -R "$GITLAB_PROJECT_URL" -F json 2>/dev/null) || {
    echo "error: GitLab MR head could not be verified" >&2
    exit 1
  }
  REMOTE_HEAD=$(printf '%s\n' "$GITLAB_JSON" | sed \
    -e 's/.*"head_sha"[[:space:]]*:[[:space:]]*"\([0-9a-f][0-9a-f]*\)".*/\1/p' \
    -e 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f][0-9a-f]*\)".*/\1/p' | head -1)
  REMOTE_BASE=$(printf '%s\n' "$GITLAB_JSON" | sed \
    -e 's/.*"target_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    -e 's/.*"target_branch_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
fm_pr_head_valid "$REMOTE_HEAD" && [ "$REMOTE_HEAD" = "$REVIEW_HEAD" ] || {
  echo "error: forge PR/MR head does not match the reviewed worktree head" >&2
  exit 1
}
[ "$REMOTE_BASE" = "$REVIEW_BASE_BRANCH" ] || {
  echo "error: forge PR/MR base does not match the approved target base" >&2
  exit 1
}
PR_HEAD=$REMOTE_HEAD

FINAL_REVIEW_HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
[ "$FINAL_REVIEW_HEAD" = "$REVIEW_HEAD" ] \
  && [ "$(fm_pr_sha256 "$REPORT")" = "$REPORT_HASH" ] \
  && [ "$(git -C "$SUBSTRATE_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" = "$SUBSTRATE_HEAD" ] \
  && [ -z "$(git -C "$SUBSTRATE_ROOT" status --porcelain 2>/dev/null)" ] \
  && fm_pr_git_remote_matches "$WT" "$PROVIDER" "$HOST" "$PROJECT_PATH" || {
  echo "error: reviewed PR-ready inputs changed before publication" >&2
  exit 1
}

fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

FINAL_REVIEW_HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
[ "$FINAL_REVIEW_HEAD" = "$REVIEW_HEAD" ] \
  && [ "$(fm_pr_sha256 "$REPORT")" = "$REPORT_HASH" ] \
  && [ "$(git -C "$SUBSTRATE_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)" = "$SUBSTRATE_HEAD" ] \
  && [ -z "$(git -C "$SUBSTRATE_ROOT" status --porcelain 2>/dev/null)" ] \
  && fm_pr_git_remote_matches "$WT" "$PROVIDER" "$HOST" "$PROJECT_PATH" || {
  echo "error: reviewed PR-ready inputs changed before publication" >&2
  exit 1
}

[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
fm_lease_guard_release
DELIVERY_LOCK_HELD=0
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
printf 'armed: state/%s.check.sh\n' "$ID"
