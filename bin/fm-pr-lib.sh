#!/usr/bin/env bash
# Shared validation and atomic artifact helpers for merge polling on the
# supported forges. Callers must validate task IDs and raw PR/MR URLs before
# constructing task paths or performing any side effect.
#
# The stored identity is provider-tagged: provider, url, host, path, number.
# "path" is the full project path, which is owner/repository on GitHub and an
# arbitrarily nested group/subgroup/project namespace on GitLab. A GitLab
# project can sit at any depth, so no owner/repository pair can address one and
# the sidecar carries the whole path instead. GitLab also runs on self-hosted
# instances, so the host is part of that identity rather than a constant. Every
# consumer re-derives the identity from the stored URL and refuses any record
# whose parts do not reconstruct that exact URL.
#
# A validated exact merged result is retired through a private receipt only
# after its durable wake is appended.
# The receipt binds the terminal observation to the canonical registration and
# lets a restart finish fixed-path removal without executing state-file bytes.

FM_PR_PROVIDER=
FM_PR_URL=
FM_PR_HOST=
FM_PR_PATH=
FM_PR_OWNER=
FM_PR_REPO=
FM_PR_NUMBER=
FM_PR_REMOTE_PROVIDER=
FM_PR_REMOTE_HOST=
FM_PR_REMOTE_PATH=
FM_PR_DATA_PROVIDER=
FM_PR_DATA_URL=
FM_PR_DATA_HOST=
FM_PR_DATA_PATH=
FM_PR_DATA_NUMBER=
FM_PR_META_PROVIDER=
FM_PR_META_URL=
FM_PR_META_HOST=
FM_PR_META_PATH=
FM_PR_META_NUMBER=
FM_PR_REG_ID=
FM_PR_REG_PROVIDER=
FM_PR_REG_URL=
FM_PR_REG_HOST=
FM_PR_REG_PATH=
FM_PR_REG_NUMBER=
FM_PR_REG_DATA_HASH=
FM_PR_REG_TEMPLATE_HASH=
FM_PR_REG_DATA_IDENTITY=
FM_PR_REG_CHECK_IDENTITY=
FM_PR_POLL_DATA_TMP=
FM_PR_POLL_CHECK_TMP=
FM_PR_POLL_REG_TMP=
FM_PR_POLL_DATA_DEST=
FM_PR_POLL_CHECK_DEST=
FM_PR_POLL_REG_DEST=
FM_PR_POLL_EXPECT_ID=
FM_PR_POLL_EXPECT_PROVIDER=
FM_PR_POLL_EXPECT_URL=
FM_PR_POLL_EXPECT_HOST=
FM_PR_POLL_EXPECT_PATH=
FM_PR_POLL_EXPECT_NUMBER=
FM_PR_POLL_EXPECT_DATA_HASH=
FM_PR_POLL_EXPECT_TEMPLATE_HASH=
FM_PR_POLL_EXPECT_DATA_IDENTITY=
FM_PR_POLL_EXPECT_CHECK_IDENTITY=
FM_PR_POLL_TEMPLATE=
FM_PR_POLL_STATE_DEVICE=
FM_PR_POLL_SNAPSHOT_ID=
FM_PR_POLL_SNAPSHOT_PROVIDER=
FM_PR_POLL_SNAPSHOT_URL=
FM_PR_POLL_SNAPSHOT_HOST=
FM_PR_POLL_SNAPSHOT_PATH=
FM_PR_POLL_SNAPSHOT_NUMBER=
FM_PR_POLL_SNAPSHOT_DATA_HASH=
FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH=
FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=
FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=
FM_PR_POLL_SNAPSHOT_REG_HASH=
FM_PR_POLL_SNAPSHOT_REG_IDENTITY=
FM_PR_RETIRE_ID=
FM_PR_RETIRE_PROVIDER=
FM_PR_RETIRE_URL=
FM_PR_RETIRE_HOST=
FM_PR_RETIRE_PATH=
FM_PR_RETIRE_NUMBER=
FM_PR_RETIRE_DATA_HASH=
FM_PR_RETIRE_TEMPLATE_HASH=
FM_PR_RETIRE_DATA_IDENTITY=
FM_PR_RETIRE_CHECK_IDENTITY=
FM_PR_RETIRE_REG_HASH=
FM_PR_RETIRE_REG_IDENTITY=
FM_PR_RETIRE_RECEIPT_HASH=
FM_PR_RETIRE_RECEIPT_IDENTITY=
FM_PR_POLL_RETIREMENT_REJECTED=

fm_task_id_path_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_pr_task_id_valid() {
  local id=${1-}
  fm_task_id_path_safe "$id"
}

fm_task_id_creation_valid() {
  local id=${1-}
  fm_pr_task_id_valid "$id" || return 1
  [ "${#id}" -le 64 ]
}

# GitLab serves self-hosted instances, so the host is part of the identity
# rather than a constant. It is accepted only as a lowercase DNS name with no
# userinfo, port, or trailing dot, which keeps one canonical spelling per MR.
# github.com is refused here even though its shape is otherwise valid: it is
# GitHub's own host and never a GitLab instance, so a URL like
# https://github.com/o/r/-/merge_requests/1 (a typo'd or spoofed GitHub URL)
# would otherwise be armed as a GitLab watch that can never succeed.
fm_pr_gitlab_host_valid() {
  local host=${1-} label
  local LC_ALL=C
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  [ "$host" != github.com ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

# A GitLab project path is group[/subgroup...]/project, so at least two
# segments and no fixed depth. GitLab reserves "-" as its route separator and
# forbids a leading hyphen, ".git", and ".atom", so none of those can name a
# real namespace and each is refused here.
fm_pr_gitlab_path_valid() {
  local path=${1-} segment
  local LC_ALL=C
  local -a segments
  [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || return 1
  case "$path" in
    /*|*/|*//*) return 1 ;;
  esac
  IFS=/ read -ra segments <<< "$path"
  [ "${#segments[@]}" -ge 2 ] && [ "${#segments[@]}" -le 20 ] || return 1
  for segment in "${segments[@]}"; do
    [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || return 1
    case "$segment" in
      .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  done
}

# Parse a canonical PR or MR URL into the provider-tagged identity. Validation
# is strict and per provider: the GitHub username and repository rules are
# unchanged, and GitLab gets its own host and namespace rules rather than a
# loosened GitHub rule.
#
# FM_PR_OWNER and FM_PR_REPO are additionally set for github because
# bin/fm-pr-merge.sh addresses GitHub by owner/repository. A gitlab URL leaves
# them empty, and that path addresses the project by FM_PR_HOST and FM_PR_PATH
# instead, so a merge request on any instance resolves without a hardcoded host.
fm_pr_url_parse() {
  local raw=${1-} pattern host path
  local LC_ALL=C
  FM_PR_PROVIDER=
  FM_PR_URL=
  FM_PR_HOST=
  FM_PR_PATH=
  FM_PR_OWNER=
  FM_PR_REPO=
  FM_PR_NUMBER=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)$'
  if [[ "$raw" =~ $pattern ]]; then
    [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
    [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
    FM_PR_PROVIDER=github
    FM_PR_URL=$raw
    FM_PR_HOST=github.com
    FM_PR_PATH="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    # Consumed by bin/fm-pr-merge.sh, which addresses GitHub by owner/repository.
    # shellcheck disable=SC2034
    FM_PR_OWNER=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034
    FM_PR_REPO=${BASH_REMATCH[2]}
    FM_PR_NUMBER=${BASH_REMATCH[3]}
    return 0
  fi
  # The path class contains "/" and "-", so this match is greedy to the last
  # "/-/merge_requests/". Any earlier separator therefore lands inside the
  # captured path, where the reserved "-" segment is refused.
  pattern='^https://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  host=${BASH_REMATCH[1]}
  path=${BASH_REMATCH[2]}
  fm_pr_gitlab_host_valid "$host" || return 1
  fm_pr_gitlab_path_valid "$path" || return 1
  FM_PR_PROVIDER=gitlab
  FM_PR_URL=$raw
  FM_PR_HOST=$host
  FM_PR_PATH=$path
  FM_PR_NUMBER=${BASH_REMATCH[3]}
}

fm_pr_git_remote_identity() {
  local repo=$1 raw authority host path
  FM_PR_REMOTE_PROVIDER=
  FM_PR_REMOTE_HOST=
  FM_PR_REMOTE_PATH=
  [ -d "$repo" ] && [ ! -L "$repo" ] || return 1
  raw=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
  case "$raw" in
    git@*:*)
      host=${raw#git@}
      host=${host%%:*}
      path=${raw#*:}
      ;;
    ssh://git@*/*)
      authority=${raw#ssh://git@}
      host=${authority%%/*}
      path=${authority#*/}
      ;;
    https://*/*|http://*/*)
      authority=${raw#*://}
      host=${authority%%/*}
      path=${authority#*/}
      ;;
    *) return 1 ;;
  esac
  case "$host" in ''|*:*|*[^A-Za-z0-9.-]*) return 1 ;; esac
  case "$path" in ''|/*|*/|*//*|*\?*|*#*) return 1 ;; esac
  case "$path" in *.git) path=${path%.git} ;; esac
  [ -n "$path" ] || return 1
  if [ "$host" = github.com ]; then
    [[ "$path" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] || return 1
    FM_PR_REMOTE_PROVIDER=github
  else
    fm_pr_gitlab_host_valid "$host" || return 1
    fm_pr_gitlab_path_valid "$path" || return 1
    FM_PR_REMOTE_PROVIDER=gitlab
  fi
  FM_PR_REMOTE_HOST=$host
  FM_PR_REMOTE_PATH=$path
}

fm_pr_git_remote_matches() {
  local repo=$1 provider=$2 host=$3 path=$4
  fm_pr_git_remote_identity "$repo" || return 1
  [ "$FM_PR_REMOTE_PROVIDER" = "$provider" ] \
    && [ "$FM_PR_REMOTE_HOST" = "$host" ] \
    && [ "$FM_PR_REMOTE_PATH" = "$path" ]
}

fm_pr_git_common_dir() {
  local repo=$1 common
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) (cd "$common" && pwd -P) || return 1 ;;
    *) (cd "$repo" && cd "$common" && pwd -P) || return 1 ;;
  esac
}

fm_pr_head_valid() {
  local head=${1-}
  local LC_ALL=C
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

fm_pr_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_pr_file_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_pr_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_pr_file_inode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %i "$1" 2>/dev/null
  else
    stat -c %i "$1" 2>/dev/null
  fi
}

fm_pr_file_identity() {
  local device inode
  device=$(fm_pr_file_device "$1") || return 1
  inode=$(fm_pr_file_inode "$1") || return 1
  [ -n "$device" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$device" "$inode"
}

fm_pr_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_pr_private_file_valid() {
  local path=$1 mode=$2 device=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_mode "$path")" = "$mode" ] || return 1
  [ "$(fm_pr_file_device "$path")" = "$device" ] || return 1
  [ "$(fm_pr_file_link_count "$path")" = 1 ]
}

fm_pr_self_review_report_path() {
  local data=$1 id=$2
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$data" ] && [ ! -L "$data" ] || return 1
  [ -d "$data/$id" ] && [ ! -L "$data/$id" ] || return 1
  printf '%s/%s/pr-self-review.md\n' "$data" "$id"
}

fm_pr_delivery_lock_path() {
  local state=$1 id=$2
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  printf '%s/.delivery-%s.lock\n' "$state" "$id"
}

fm_pr_default_branch() {
  local repo=$1 ref branch
  [ -d "$repo" ] && [ ! -L "$repo" ] || return 1
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

fm_pr_review_base_from_meta() {
  local meta=$1 ref sha
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  [ "$(grep -c '^review_base_ref=' "$meta" || true)" = 1 ] || return 1
  [ "$(grep -c '^review_base_sha=' "$meta" || true)" = 1 ] || return 1
  ref=$(sed -n 's/^review_base_ref=//p' "$meta")
  sha=$(sed -n 's/^review_base_sha=//p' "$meta")
  case "$ref" in
    ''|[-.]*|*..*|*@\{*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  fm_pr_head_valid "$sha" || return 1
  printf '%s\t%s\n' "$ref" "$sha"
}

fm_pr_review_base_from_brief() {
  local brief=$1 line count ref sha
  [ -f "$brief" ] && [ ! -L "$brief" ] || return 1
  count=$(grep -c '^Target-project approved base:' "$brief" || true)
  [ "$count" = 1 ] || {
    [ "$count" = 0 ] && return 2
    return 1
  }
  line=$(grep '^Target-project approved base:' "$brief")
  printf '%s\n' "$line" | grep -Eq '^Target-project approved base: ref=[A-Za-z0-9._/-][A-Za-z0-9._/-]*; sha=[0-9a-f][0-9a-f]*$' || return 1
  line=$(sed -n 's/^Target-project approved base: ref=\([^;]*\); sha=\([0-9a-f][0-9a-f]*\)$/\1\t\2/p' "$brief")
  IFS="$(printf '\t')" read -r ref sha <<EOF
$line
EOF
  case "$ref" in
    ''|[-.]*|*..*|*@\{*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  fm_pr_head_valid "$sha" || return 1
  printf '%s\t%s\n' "$ref" "$sha"
}

fm_pr_review_base_branch() {
  local ref=${1-} branch
  case "$ref" in
    origin/*) branch=${ref#origin/} ;;
    refs/remotes/origin/*) branch=${ref#refs/remotes/origin/} ;;
    refs/heads/*) branch=${ref#refs/heads/} ;;
    refs/*) return 1 ;;
    *) branch=$ref ;;
  esac
  case "$branch" in
    ''|[-.]*|*..*|*@\{*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  printf '%s\n' "$branch"
}

fm_pr_review_base_resolve() {
  local worktree=$1 approved_ref=$2 approved_sha=$3 branch remote_ref resolved
  [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  fm_pr_head_valid "$approved_sha" || return 1
  resolved=$(git -C "$worktree" rev-parse --verify --quiet "$approved_ref^{commit}" 2>/dev/null || true)
  if [ "$resolved" = "$approved_sha" ]; then
    printf '%s\n' "$approved_ref"
    return 0
  fi
  branch=$(fm_pr_review_base_branch "$approved_ref") || return 1
  remote_ref="refs/remotes/origin/$branch"
  resolved=$(git -C "$worktree" rev-parse --verify --quiet "$remote_ref^{commit}" 2>/dev/null || true)
  if [ "$resolved" != "$approved_sha" ]; then
    git -C "$worktree" fetch --quiet origin "+refs/heads/$branch:$remote_ref" || return 1
    resolved=$(git -C "$worktree" rev-parse --verify --quiet "$remote_ref^{commit}" 2>/dev/null) || return 1
  fi
  [ "$resolved" = "$approved_sha" ] || return 1
  printf 'origin/%s\n' "$branch"
}

fm_pr_substrate_launch_sha() {
  local data=$1 id=$2 brief value count
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$data" ] && [ ! -L "$data" ] || return 1
  [ -d "$data/$id" ] && [ ! -L "$data/$id" ] || return 1
  brief="$data/$id/brief.md"
  [ -f "$brief" ] && [ ! -L "$brief" ] || return 1
  count=$(grep -c '^- Firstmate substrate launch SHA: `\([0-9a-f][0-9a-f]*\)`$' "$brief" || true)
  [ "$count" = 1 ] || return 1
  value=$(sed -n 's/^- Firstmate substrate launch SHA: `\([0-9a-f][0-9a-f]*\)`$/\1/p' "$brief")
  fm_pr_head_valid "$value" || return 1
  printf '%s\n' "$value"
}

fm_pr_substrate_root_from_brief() {
  local brief=$1 root count actual_root git_root
  [ -f "$brief" ] && [ ! -L "$brief" ] || return 1
  count=$(grep -c '^- Firstmate substrate root: `.*`$' "$brief" || true)
  [ "$count" = 1 ] || return 1
  root=$(sed -n 's/^- Firstmate substrate root: `\(.*\)`$/\1/p' "$brief")
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  actual_root=$(cd "$root" && pwd -P) || return 1
  git_root=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$git_root" ] || return 1
  [ "$(cd "$git_root" && pwd -P)" = "$actual_root" ] || return 1
  printf '%s\n' "$actual_root"
}

fm_pr_sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_pr_review_path_encode() {
  local path=$1 encoded
  encoded=$(printf '%s' "$path" | LC_ALL=C od -An -tx1 | tr -d '[:space:]') || return 1
  [ -n "$encoded" ] || return 1
  printf 'hex:%s\n' "$encoded"
}

fm_pr_self_review_report_valid() {
  local data=$1 id=$2 expected_head=${3-} worktree=${4-} substrate_root=${5-} expected_base_ref=${6-} expected_base_sha=${7-} expected_substrate_base=${8-}
  local report data_device parsed target_repository base_ref base_sha head_sha merge_base_sha changed_files tree_status
  local substrate_base_sha substrate_head_sha substrate_changed_files
  [ -n "$worktree" ] && [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  [ -n "$substrate_root" ] && [ -d "$substrate_root" ] && [ ! -L "$substrate_root" ] || return 1
  report=$(fm_pr_self_review_report_path "$data" "$id") || return 1
  data_device=$(fm_pr_file_device "$data") || return 1
  fm_pr_private_file_valid "$report" 600 "$data_device" || return 1
  [ "$(wc -c < "$report" | tr -d '[:space:]')" -le 1048576 ] || return 1
  parsed=$(awk -v task="$id" -v expected_head="$expected_head" '
    BEGIN {
      headings[1] = "# Findings"
      headings[2] = "# Target-project diff evidence"
      headings[3] = "# Firstmate substrate diff evidence"
      headings[4] = "# Surface review"
      headings[5] = "# Verification"
      headings[6] = "# Residual risks"
      expected = 1
      valid = 1
    }
    function field(prefix) {
      return substr($0, length(prefix) + 1)
    }
    function full_sha(value) {
      return (length(value) == 40 || length(value) == 64) && value !~ /[^0-9a-f]/
    }
    function full_digest(value) {
      return length(value) == 64 && value !~ /[^0-9a-f]/
    }
    NR == 1 {
      valid = valid && ($0 == "Self-review report: firstmate-pr-self-review.v1")
      next
    }
    NR == 2 {
      valid = valid && ($0 == "Task id: " task)
      next
    }
    NR == 3 {
      valid = valid && ($0 == headings[1])
      if (!valid) bad = 1
      expected = 2
      next
    }
    {
      if ($0 == headings[expected]) {
        if (expected > 1 && !content) bad = 1
        content = 0
        expected++
        next
      }
      for (i = 1; i <= 6; i++) {
        if ($0 == headings[i]) {
          bad = 1
          next
        }
      }
      if ($0 !~ /^[[:space:]]*$/) content = 1
      if (expected == 2) {
        if ($0 == "Review status: complete") finding_review = 1
        if (index($0, "Finding count: ") == 1 && field("Finding count: ") ~ /^[0-9]+$/) {
          finding_count = field("Finding count: ") + 0
          finding_count_seen = 1
        }
        if ($0 == "Finding summary: none") finding_summary = 1
        if (index($0, "Finding: ") == 1) {
          finding_entries++
          if (substr($0, length("Finding: ") + 1) !~ /^severity=(error|warning|info); path=[^;[:space:]][^;]*:[1-9][0-9]*; evidence=[^;[:space:]][^;]*[[:space:]][^;[:space:]]; consequence=[^;[:space:]][^;]*[[:space:]][^;[:space:]]; fix=[^;[:space:]][^;]*[[:space:]][^;[:space:]]$/) bad = 1
        }
      }
      if (expected == 3) {
        if (index($0, "Target repository: ") == 1 && length(field("Target repository: ")) > 0) {
          target_repository = 1
          target_repository_value = field("Target repository: ")
        }
        if (index($0, "Base ref: ") == 1 && length(field("Base ref: ")) > 0) {
          base_ref = 1
          base_ref_value = field("Base ref: ")
        }
        if (index($0, "Base SHA: ") == 1 && full_sha(field("Base SHA: "))) {
          base_sha = 1
          base_sha_value = field("Base SHA: ")
        }
        if (index($0, "Head SHA: ") == 1 && full_sha(field("Head SHA: "))) {
          head_sha = field("Head SHA: ")
          target_head = 1
        }
        if (index($0, "Merge-base SHA: ") == 1 && full_sha(field("Merge-base SHA: "))) {
          merge_base_sha = 1
          merge_base_sha_value = field("Merge-base SHA: ")
        }
        if (index($0, "Changed files: ") == 1 && full_digest(field("Changed files: "))) {
          changed_files = 1
          changed_files_value = field("Changed files: ")
        }
        if ($0 == "Tree status: clean") {
          tree_status = 1
          tree_status_value = "clean"
        }
      }
      if (expected == 4) {
        if (index($0, "Substrate base SHA: ") == 1 && full_sha(field("Substrate base SHA: "))) {
          substrate_base_sha = 1
          substrate_base_sha_value = field("Substrate base SHA: ")
        }
        if (index($0, "Substrate head SHA: ") == 1 && full_sha(field("Substrate head SHA: "))) {
          substrate_head_sha = 1
          substrate_head_sha_value = field("Substrate head SHA: ")
        }
        if (index($0, "Substrate changed files: ") == 1 && full_digest(field("Substrate changed files: "))) {
          substrate_changed_files = 1
          substrate_changed_files_value = field("Substrate changed files: ")
        }
        if ($0 == "Substrate diff: no substrate diff") substrate_no_diff = 1
      }
      if (expected == 5) {
        if (index($0, "Authority: ") == 1) { authority_count++; if (substantive(field("Authority: "), "authority")) authority = 1 }
        if (index($0, "Security: ") == 1) { security_count++; if (substantive(field("Security: "), "security")) security = 1 }
        if (index($0, "Path: ") == 1) { path_count++; if (substantive(field("Path: "), "path")) path = 1 }
        if (index($0, "Failure: ") == 1) { failure_count++; if (substantive(field("Failure: "), "failure")) failure = 1 }
        if (index($0, "Tests: ") == 1) { tests_count++; if (substantive(field("Tests: "), "tests")) tests = 1 }
        if (index($0, "Documentation: ") == 1) { documentation_count++; if (substantive(field("Documentation: "), "documentation")) documentation = 1 }
        if (index($0, "Delivery: ") == 1) { delivery_count++; if (substantive(field("Delivery: "), "delivery")) delivery = 1 }
      }
      if (expected == 6) {
        if (index($0, "Command: ") == 1 && length(field("Command: ")) > 0) command = 1
        if (index($0, "Result: ") == 1 && length(field("Result: ")) > 0) result = 1
      }
    }
    END {
      if (!content) bad = 1
      if (!finding_review || !finding_count_seen || finding_count != finding_entries) bad = 1
      if (finding_count == 0 && !finding_summary) bad = 1
      if (!target_repository || !base_ref || !base_sha || !target_head || !merge_base_sha || !changed_files || !tree_status) bad = 1
      if (!substrate_base_sha || !substrate_head_sha || !substrate_changed_files) bad = 1
      if (!authority || !security || !path || !failure || !tests || !documentation || !delivery) bad = 1
      if (authority_count != 1 || security_count != 1 || path_count != 1 || failure_count != 1 || tests_count != 1 || documentation_count != 1 || delivery_count != 1) bad = 1
      if (!command || !result) bad = 1
      if (expected_head != "" && head_sha != expected_head) bad = 1
      if (valid && !bad && expected == 7 && NR >= 8) {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", target_repository_value, base_ref_value, base_sha_value, head_sha, merge_base_sha_value, changed_files_value, tree_status_value, substrate_base_sha_value, substrate_head_sha_value, substrate_changed_files_value, substrate_no_diff
        exit 0
      }
      exit 1
    }
    function substantive(value, surface,    n, parts, i, signal) {
      n = split(value, parts, "; ")
      if (n != 5 || parts[1] != "reviewed") return 0
      if (parts[2] !~ /^files=[^;[:space:]][^;]*$/) return 0
      if (parts[3] !~ /^evidence=[^;[:space:]][^;]*:[1-9][0-9]* sha256=[0-9a-f]+ [^;[:space:]][^;]*$/) return 0
      for (i = 4; i <= 5; i++) {
        if (parts[i] !~ /^(evidence|consequence|fix)=[^;[:space:]][^;]*$/) return 0
        if (parts[i] !~ /=[^;[:space:]][^;]*[[:space:]][^;[:space:]]/) return 0
        if (length(parts[i]) < 12 || parts[i] ~ /=(none|n\/a|x|todo|tbd)$/) return 0
      }
      signal = tolower(parts[3] " " parts[4] " " parts[5])
      if (surface == "authority" && signal !~ /(authorit|owner|delivery|merge|no-mistakes)/) return 0
      if (surface == "security" && signal !~ /(security|trust|private|provenance|tamper|secret|credential|reject|refus|identity)/) return 0
      if (surface == "path" && signal !~ /(path|worktree|directory|task|travers|symlink|boundary)/) return 0
      if (surface == "failure" && signal !~ /(fail|error|refus|retry|invalid|malform|fallback|bound)/) return 0
      if (surface == "tests" && signal !~ /(test|verify|validat|assert|coverage|execute|command|regression)/) return 0
      if (surface == "documentation" && signal !~ /(doc|brief|skill|contract|agents|generated|record)/) return 0
      if (surface == "delivery" && signal !~ /(delivery|pr|merge|branch|push|no-mistakes|readiness)/) return 0
      return 1
    }
  ' "$report") || return 1
  IFS="$(printf '\t')" read -r target_repository base_ref base_sha head_sha merge_base_sha changed_files tree_status \
    substrate_base_sha substrate_head_sha substrate_changed_files substrate_no_diff <<EOF
$parsed
EOF
  case "$base_ref" in
    ''|[-.]*|*..*|*@\{*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  local actual_repository actual_head resolved_base actual_merge_base actual_changed_files actual_changed_paths actual_changed_path_count
  actual_repository=$(cd "$worktree" && pwd -P) || return 1
  actual_head=$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  [ "$target_repository" = "$actual_repository" ] || return 1
  [ "$head_sha" = "$actual_head" ] || return 1
  [ -n "$expected_base_ref" ] && [ "$base_ref" = "$expected_base_ref" ] || return 1
  [ -n "$expected_base_sha" ] && [ "$base_sha" = "$expected_base_sha" ] || return 1
  resolved_base=$(git -C "$worktree" rev-parse --verify "$base_ref^{commit}" 2>/dev/null) || return 1
  [ "$base_sha" = "$resolved_base" ] || return 1
  actual_merge_base=$(git -C "$worktree" merge-base "$base_sha" "$head_sha" 2>/dev/null) || return 1
  [ "$merge_base_sha" = "$actual_merge_base" ] || return 1
  actual_changed_files=$(git -C "$worktree" diff --name-status "$merge_base_sha" "$head_sha" | fm_pr_sha256_stream) || return 1
  [ "$changed_files" = "$actual_changed_files" ] || return 1
  actual_changed_paths=$(
    set -o pipefail
    git -C "$worktree" diff --name-only -z "$merge_base_sha" "$head_sha" |
      while IFS= read -r -d '' changed_path; do
        fm_pr_review_path_encode "$changed_path" || exit 1
      done
  ) || return 1
  [ -n "$actual_changed_paths" ] || return 1
  actual_changed_path_count=$(printf '%s\n' "$actual_changed_paths" | awk 'NF { count++ } END { print count + 0 }') || return 1
  [ -z "$(git -C "$worktree" status --porcelain 2>/dev/null)" ] || return 1
  [ -z "$(git -C "$substrate_root" status --porcelain 2>/dev/null)" ] || return 1
  fm_pr_review_path_syntax_valid() {
    local candidate=$1 encoded decoded
    case "$candidate" in
      hex:*)
        encoded=${candidate#hex:}
        case "$encoded" in
          ''|*[!0-9a-f]*) return 1 ;;
        esac
        [ $(( ${#encoded} % 2 )) -eq 0 ] || return 1
        printf -v decoded '%b' "$(printf '%s' "$encoded" | sed 's/../\\x&/g')" || return 1
        ;;
      ''|/*|*';'*|*,*|*:*|*[[:space:]]*) return 1 ;;
      *) decoded=$candidate ;;
    esac
    case "$decoded" in
      ''|/*) return 1 ;;
      *';'*|*,*|*:*|*[[:space:]]*)
        case "$candidate" in
          hex:*) ;;
          *) return 1 ;;
        esac
        ;;
    esac
    case "/$decoded/" in
      */../*|*/./*) return 1 ;;
    esac
    FM_PR_REVIEW_PATH=$decoded
    return 0
  }
  local line finding_path finding_file finding_line surface_files surface_file review_root
  local surface_evidence evidence_ref evidence_rest evidence_file evidence_line evidence_hash line_content actual_evidence_hash surface_review_files surface_evidence_files changed_path surface_name
  surface_review_files=
  surface_evidence_files=
  fm_pr_review_file_valid() {
    local review_file=$1
    for review_root in "$worktree" "$substrate_root"; do
      if [ -f "$review_root/$review_file" ] && [ ! -L "$review_root/$review_file" ] \
        && git -C "$review_root" ls-files --error-unmatch -- "$review_file" >/dev/null 2>&1; then
        return 0
      fi
    done
    if [ "$(git -C "$worktree" cat-file -t "$merge_base_sha:$review_file" 2>/dev/null)" = blob ]; then
      return 0
    fi
    if [ "$(git -C "$substrate_root" cat-file -t "$substrate_base_sha:$review_file" 2>/dev/null)" = blob ]; then
      return 0
    fi
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    finding_path=${line#* path=}
    finding_path=${finding_path%%; evidence=*}
    finding_file=${finding_path%:*}
    finding_line=${finding_path##*:}
    fm_pr_review_path_syntax_valid "$finding_file" || return 1
    finding_file=$FM_PR_REVIEW_PATH
    [ "$finding_line" -ge 1 ] 2>/dev/null || return 1
    fm_pr_review_file_valid "$finding_file" || return 1
  done < <(awk '/^Finding: / { print }' "$report")
  while IFS= read -r line || [ -n "$line" ]; do
    surface_files=${line#*files=}
    surface_files=${surface_files%%; evidence=*}
    [ -n "$surface_files" ] || return 1
    while IFS= read -r surface_file || [ -n "$surface_file" ]; do
      fm_pr_review_path_syntax_valid "$surface_file" || return 1
      surface_file=$FM_PR_REVIEW_PATH
      fm_pr_review_file_valid "$surface_file" || return 1
      surface_file=$(fm_pr_review_path_encode "$surface_file") || return 1
      surface_review_files="$surface_review_files$surface_file
"
    done < <(printf '%s\n' "$surface_files" | tr ',' '\n')
  done < <(awk '/^(Authority|Security|Path|Failure|Tests|Documentation|Delivery): / { print }' "$report")
  fm_pr_review_surface_file_valid() {
    local candidate=$1 allowed_files listed encoded_candidate
    allowed_files=${2-$surface_review_files}
    encoded_candidate=$(fm_pr_review_path_encode "$candidate") || return 1
    while IFS= read -r listed || [ -n "$listed" ]; do
      fm_pr_review_path_syntax_valid "$listed" || return 1
      listed=$FM_PR_REVIEW_PATH
      listed=$(fm_pr_review_path_encode "$listed") || return 1
      [ "$listed" = "$encoded_candidate" ] && return 0
    done < <(printf '%s\n' "$allowed_files" | tr ',' '\n')
    return 1
  }
  fm_pr_changed_path_valid() {
    local candidate=$1 changed_path encoded_candidate
    encoded_candidate=$(fm_pr_review_path_encode "$candidate") || return 1
    while IFS= read -r changed_path || [ -n "$changed_path" ]; do
      [ "$encoded_candidate" = "$changed_path" ] && return 0
    done <<EOF
$actual_changed_paths
EOF
    return 1
  }
  fm_pr_review_surface_path_valid() {
    local review_surface=$1 review_file=$2
    [ "$actual_changed_path_count" -lt 7 ] && return 0
    case "$review_surface:$review_file" in
      authority:AGENTS.md|authority:.agents/*|authority:bin/fm-brief.sh|authority:bin/fm-check*.sh|authority:bin/fm-merge*.sh|authority:bin/fm-pr*.sh|authority:bin/fm-promote.sh|authority:bin/fm-spawn.sh) return 0 ;;
      security:.agents/*|security:bin/fm-operational-input.sh|security:bin/fm-pending-reply-lib.sh|security:bin/fm-pr*.sh|security:bin/fm-send.sh|security:bin/firstmate_factory/*|security:schemas/*|security:tests/*security*|security:tests/*trust*) return 0 ;;
      path:.agents/*|path:bin/fm-pr*.sh|path:bin/fm-remote*.sh|path:bin/fm-send.sh|path:bin/fm-spawn.sh|path:tests/*path*|path:tests/*spawn*|path:tests/*secondmate*) return 0 ;;
      failure:bin/fm-*.sh|failure:bin/firstmate_factory/*|failure:schemas/*|failure:tests/*) return 0 ;;
      tests:bin/fm-test*.sh|tests:tests/*) return 0 ;;
      documentation:AGENTS.md|documentation:.agents/*|documentation:CONTRIBUTING.md|documentation:README*|documentation:docs/*|documentation:bin/fm-brief.sh) return 0 ;;
      delivery:AGENTS.md|delivery:bin/fm-brief.sh|delivery:bin/fm-merge*.sh|delivery:bin/fm-pr*.sh|delivery:bin/fm-promote.sh|delivery:bin/fm-send.sh|delivery:bin/fm-spawn.sh|delivery:tests/*delivery*|delivery:tests/*pr*) return 0 ;;
    esac
    return 1
  }
  fm_pr_review_changed_line_valid() {
    local review_file=$1 review_line=$2
    git -C "$worktree" diff --no-color --unified=0 "$merge_base_sha" "$head_sha" -- "$review_file" |
      awk -v target="$review_line" '
        function range_start(value, parts) {
          sub(/^[-+]/, "", value)
          split(value, parts, ",")
          return parts[1] + 0
        }
        function range_count(value, parts) {
          split(value, parts, ",")
          return parts[2] == "" ? 1 : parts[2] + 0
        }
        /^@@ / {
          old_start = range_start($2)
          old_count = range_count($2)
          new_start = range_start($3)
          new_count = range_count($3)
          if (new_count > 0 && target >= new_start && target < new_start + new_count) found = 1
          if (new_count == 0 && old_count > 0 && target >= old_start && target < old_start + old_count) found = 1
        }
        END { exit found ? 0 : 1 }
      '
  }
  while IFS= read -r changed_path || [ -n "$changed_path" ]; do
    fm_pr_review_path_syntax_valid "$changed_path" || return 1
    changed_path=$FM_PR_REVIEW_PATH
    fm_pr_changed_path_valid "$changed_path" || return 1
    fm_pr_review_surface_file_valid "$changed_path" || return 1
  done <<EOF
$actual_changed_paths
EOF
  while IFS= read -r line || [ -n "$line" ]; do
    actual_evidence_hash=
    surface_files=${line#*files=}
    surface_files=${surface_files%%; evidence=*}
    surface_evidence=${line#*; evidence=}
    surface_evidence=${surface_evidence%%; consequence=*}
    evidence_ref=${surface_evidence%% sha256=*}
    evidence_rest=${surface_evidence#"$evidence_ref" }
    evidence_hash=${evidence_rest#sha256=}
    evidence_hash=${evidence_hash%% *}
    evidence_file=${evidence_ref%:*}
    evidence_line=${evidence_ref##*:}
    fm_pr_review_path_syntax_valid "$evidence_file" || return 1
    evidence_file=$FM_PR_REVIEW_PATH
    surface_name=$(printf '%s' "${line%%:*}" | tr '[:upper:]' '[:lower:]') || return 1
    fm_pr_review_surface_path_valid "$surface_name" "$evidence_file" || return 1
    [ "$evidence_line" -ge 1 ] 2>/dev/null || return 1
    [ "${#evidence_hash}" -eq 64 ] || return 1
    case "$evidence_hash" in
      *[!0-9a-f]*) return 1 ;;
    esac
    fm_pr_review_surface_file_valid "$evidence_file" "$surface_files" || return 1
    fm_pr_changed_path_valid "$evidence_file" || return 1
    fm_pr_review_changed_line_valid "$evidence_file" "$evidence_line" || return 1
    if [ -f "$worktree/$evidence_file" ] && [ ! -L "$worktree/$evidence_file" ] \
      && git -C "$worktree" ls-files --error-unmatch -- "$evidence_file" >/dev/null 2>&1; then
      line_content=$(awk -v target="$evidence_line" 'NR == target { print; found = 1; exit } END { if (!found) exit 1 }' "$worktree/$evidence_file") || return 1
      actual_evidence_hash=$(printf '%s\n' "$line_content" | fm_pr_sha256_stream) || return 1
    elif [ "$(git -C "$worktree" cat-file -t "$merge_base_sha:$evidence_file" 2>/dev/null)" = blob ]; then
      line_content=$(git -C "$worktree" show "$merge_base_sha:$evidence_file" | awk -v target="$evidence_line" 'NR == target { print; found = 1; exit } END { if (!found) exit 1 }') || return 1
      actual_evidence_hash=$(printf '%s\n' "$line_content" | fm_pr_sha256_stream) || return 1
    fi
    evidence_file=$(fm_pr_review_path_encode "$evidence_file") || return 1
    surface_evidence_files="$surface_evidence_files$evidence_file
"
    [ "$actual_evidence_hash" = "$evidence_hash" ] || return 1
  done < <(awk '/^(Authority|Security|Path|Failure|Tests|Documentation|Delivery): / { print }' "$report")
  local unique_surface_evidence_count required_surface_evidence_count
  unique_surface_evidence_count=$(printf '%s\n' "$surface_evidence_files" | LC_ALL=C sort -u | awk 'NF { count++ } END { print count + 0 }') || return 1
  required_surface_evidence_count=$actual_changed_path_count
  [ "$required_surface_evidence_count" -le 7 ] || required_surface_evidence_count=7
  [ "$unique_surface_evidence_count" -ge "$required_surface_evidence_count" ] || return 1
  local actual_substrate_head actual_substrate_changed empty_digest
  actual_substrate_head=$(git -C "$substrate_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  [ "$substrate_head_sha" = "$actual_substrate_head" ] || return 1
  [ -n "$expected_substrate_base" ] && [ "$substrate_base_sha" = "$expected_substrate_base" ] || return 1
  git -C "$substrate_root" cat-file -e "$substrate_base_sha^{commit}" 2>/dev/null || return 1
  actual_substrate_changed=$(git -C "$substrate_root" diff --name-status "$substrate_base_sha" "$substrate_head_sha" | fm_pr_sha256_stream) || return 1
  [ "$substrate_changed_files" = "$actual_substrate_changed" ] || return 1
  empty_digest=$(printf '' | fm_pr_sha256_stream) || return 1
  if [ "$actual_substrate_changed" = "$empty_digest" ]; then
    [ "$substrate_no_diff" = 1 ] || return 1
  else
    [ -z "$substrate_no_diff" ] || return 1
  fi
}

fm_pr_regular_destination_or_absent() {
  local path=$1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ "$(fm_pr_file_link_count "$path")" = 1 ]
  fi
}

fm_pr_regular_destination_on_device_or_absent() {
  local path=$1 device=$2
  fm_pr_regular_destination_or_absent "$path" || return 1
  [ ! -e "$path" ] || [ "$(fm_pr_file_device "$path")" = "$device" ]
}

fm_pr_metadata_identity_parse() {
  local file=$1 line value pr_count=0 seen_pr=0 post_pr_invalid=0
  FM_PR_META_PROVIDER=
  FM_PR_META_URL=
  FM_PR_META_HOST=
  FM_PR_META_PATH=
  FM_PR_META_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if fm_pr_url_parse "$value"; then
          FM_PR_META_PROVIDER=$FM_PR_PROVIDER
          FM_PR_META_URL=$FM_PR_URL
          FM_PR_META_HOST=$FM_PR_HOST
          FM_PR_META_PATH=$FM_PR_PATH
          FM_PR_META_NUMBER=$FM_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          fm_pr_head_valid "$value" || post_pr_invalid=1
        fi
        ;;
      x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*)
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$FM_PR_META_URL" ]
}

# Sidecar layout: provider, url, host, path, number, one per line. A sidecar
# written before the provider tag existed has a URL on its first line and one
# line fewer, so it fails both the field count and the provider comparison and
# is refused rather than misread as a provider-tagged record.
fm_pr_poll_data_parse() {
  local file=$1 provider url host path number
  FM_PR_DATA_PROVIDER=
  FM_PR_DATA_URL=
  FM_PR_DATA_HOST=
  FM_PR_DATA_PATH=
  FM_PR_DATA_NUMBER=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r url <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  FM_PR_DATA_PROVIDER=$FM_PR_PROVIDER
  FM_PR_DATA_URL=$FM_PR_URL
  FM_PR_DATA_HOST=$FM_PR_HOST
  FM_PR_DATA_PATH=$FM_PR_PATH
  FM_PR_DATA_NUMBER=$FM_PR_NUMBER
}

# Registration layout: version tag, task id, then the same provider-tagged
# identity as the sidecar, then the two hashes and the two file identities.
# The version tag moved to v2 with the provider tag, so a registration written
# by the previous release is recognised as old and refused. The non-executing
# migration in bin/fm-pr-check-migrate.sh then rebuilds that poll from the
# task's recorded pull request URL.
fm_pr_poll_registration_parse() {
  local file=$1 version id provider url host path number data_hash template_hash data_identity check_identity
  FM_PR_REG_ID=
  FM_PR_REG_PROVIDER=
  FM_PR_REG_URL=
  FM_PR_REG_HOST=
  FM_PR_REG_PATH=
  FM_PR_REG_NUMBER=
  FM_PR_REG_DATA_HASH=
  FM_PR_REG_TEMPLATE_HASH=
  FM_PR_REG_DATA_IDENTITY=
  FM_PR_REG_CHECK_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r id <&7 || { exec 7<&-; return 1; }
  IFS= read -r provider <&7 || { exec 7<&-; return 1; }
  IFS= read -r url <&7 || { exec 7<&-; return 1; }
  IFS= read -r host <&7 || { exec 7<&-; return 1; }
  IFS= read -r path <&7 || { exec 7<&-; return 1; }
  IFS= read -r number <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r template_hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r data_identity <&7 || { exec 7<&-; return 1; }
  IFS= read -r check_identity <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = fm-pr-poll-registration-v2 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  FM_PR_REG_ID=$id
  FM_PR_REG_PROVIDER=$FM_PR_PROVIDER
  FM_PR_REG_URL=$FM_PR_URL
  FM_PR_REG_HOST=$FM_PR_HOST
  FM_PR_REG_PATH=$FM_PR_PATH
  FM_PR_REG_NUMBER=$FM_PR_NUMBER
  FM_PR_REG_DATA_HASH=$data_hash
  FM_PR_REG_TEMPLATE_HASH=$template_hash
  FM_PR_REG_DATA_IDENTITY=$data_identity
  FM_PR_REG_CHECK_IDENTITY=$check_identity
}

fm_pr_poll_cleanup() {
  [ -z "$FM_PR_POLL_DATA_TMP" ] || rm -f -- "$FM_PR_POLL_DATA_TMP"
  [ -z "$FM_PR_POLL_CHECK_TMP" ] || rm -f -- "$FM_PR_POLL_CHECK_TMP"
  [ -z "$FM_PR_POLL_REG_TMP" ] || rm -f -- "$FM_PR_POLL_REG_TMP"
  FM_PR_POLL_DATA_TMP=
  FM_PR_POLL_CHECK_TMP=
  FM_PR_POLL_REG_TMP=
}

fm_pr_poll_revoke_final() {
  local failed=0
  # Neutralize the runnable name first so a failed rearm cannot consume state
  # whose transactional registration did not commit successfully.
  if [ -e "$FM_PR_POLL_CHECK_DEST" ] || [ -L "$FM_PR_POLL_CHECK_DEST" ]; then
    rm -f -- "$FM_PR_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_REG_DEST" ] || [ -L "$FM_PR_POLL_REG_DEST" ]; then
    rm -f -- "$FM_PR_POLL_REG_DEST" || failed=1
  fi
  if [ -e "$FM_PR_POLL_DATA_DEST" ] || [ -L "$FM_PR_POLL_DATA_DEST" ]; then
    rm -f -- "$FM_PR_POLL_DATA_DEST" || failed=1
  fi
  [ ! -e "$FM_PR_POLL_CHECK_DEST" ] && [ ! -L "$FM_PR_POLL_CHECK_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_REG_DEST" ] && [ ! -L "$FM_PR_POLL_REG_DEST" ] || failed=1
  [ ! -e "$FM_PR_POLL_DATA_DEST" ] && [ ! -L "$FM_PR_POLL_DATA_DEST" ] || failed=1
  return "$failed"
}

fm_pr_poll_prepare() {
  local state=$1 id=$2 provider=$3 url=$4 host=$5 path=$6 number=$7 template=$8
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [ -f "$template" ] || return 1

  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  FM_PR_POLL_DATA_DEST="$state/$id.pr-poll"
  FM_PR_POLL_CHECK_DEST="$state/$id.check.sh"
  FM_PR_POLL_REG_DEST="$state/$id.pr-poll-registration"
  FM_PR_POLL_EXPECT_ID=$id
  FM_PR_POLL_EXPECT_PROVIDER=$provider
  FM_PR_POLL_EXPECT_URL=$url
  FM_PR_POLL_EXPECT_HOST=$host
  FM_PR_POLL_EXPECT_PATH=$path
  FM_PR_POLL_EXPECT_NUMBER=$number
  FM_PR_POLL_TEMPLATE=$template
  FM_PR_POLL_STATE_DEVICE=$(fm_pr_file_device "$state") || return 1
  [ -n "$FM_PR_POLL_STATE_DEVICE" ] || return 1
  FM_PR_POLL_DATA_TMP=$(mktemp "$state/.fm-pr-poll-data.XXXXXX") || return 1
  FM_PR_POLL_CHECK_TMP=$(mktemp "$state/.fm-pr-poll-check.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }
  FM_PR_POLL_REG_TMP=$(mktemp "$state/.fm-pr-poll-registration.XXXXXX") || {
    fm_pr_poll_cleanup
    return 1
  }

  if ! printf '%s\n%s\n%s\n%s\n%s\n' "$provider" "$url" "$host" "$path" "$number" > "$FM_PR_POLL_DATA_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_DATA_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_TMP" \
    || [ "$FM_PR_DATA_PROVIDER" != "$provider" ] \
    || [ "$FM_PR_DATA_URL" != "$url" ] \
    || [ "$FM_PR_DATA_HOST" != "$host" ] \
    || [ "$FM_PR_DATA_PATH" != "$path" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$number" ] \
    || ! cp "$template" "$FM_PR_POLL_CHECK_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_CHECK_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_CHECK_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! cmp -s "$template" "$FM_PR_POLL_CHECK_TMP"; then
    fm_pr_poll_cleanup
    return 1
  fi
  FM_PR_POLL_EXPECT_DATA_HASH=$(fm_pr_sha256 "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_TEMPLATE_HASH=$(fm_pr_sha256 "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_DATA_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_DATA_TMP") || { fm_pr_poll_cleanup; return 1; }
  FM_PR_POLL_EXPECT_CHECK_IDENTITY=$(fm_pr_file_identity "$FM_PR_POLL_CHECK_TMP") || { fm_pr_poll_cleanup; return 1; }
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-registration-v2 "$id" "$provider" "$url" "$host" "$path" "$number" \
      "$FM_PR_POLL_EXPECT_DATA_HASH" "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" \
      "$FM_PR_POLL_EXPECT_DATA_IDENTITY" "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" \
      > "$FM_PR_POLL_REG_TMP" \
    || ! chmod 0600 "$FM_PR_POLL_REG_TMP" \
    || ! fm_pr_private_file_valid "$FM_PR_POLL_REG_TMP" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_TMP" \
    || [ "$FM_PR_REG_ID" != "$id" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ]; then
    fm_pr_poll_cleanup
    return 1
  fi
}

fm_pr_poll_publish_prepared() {
  [ -n "$FM_PR_POLL_DATA_TMP" ] && [ -n "$FM_PR_POLL_CHECK_TMP" ] \
    && [ -n "$FM_PR_POLL_REG_TMP" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_DATA_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_REG_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$FM_PR_POLL_DATA_TMP" "$FM_PR_POLL_DATA_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_DATA_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_DATA_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || [ "$(fm_pr_file_identity "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$(fm_pr_sha256 "$FM_PR_POLL_DATA_DEST")" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || ! fm_pr_poll_data_parse "$FM_PR_POLL_DATA_DEST" \
    || [ "$FM_PR_DATA_PROVIDER" != "$FM_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$FM_PR_DATA_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_DATA_HOST" != "$FM_PR_POLL_EXPECT_HOST" ] \
    || [ "$FM_PR_DATA_PATH" != "$FM_PR_POLL_EXPECT_PATH" ] \
    || [ "$FM_PR_DATA_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! mv -f -- "$FM_PR_POLL_REG_TMP" "$FM_PR_POLL_REG_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_REG_TMP=
  if ! fm_pr_private_file_valid "$FM_PR_POLL_REG_DEST" 600 "$FM_PR_POLL_STATE_DEVICE" \
    || ! fm_pr_poll_registration_parse "$FM_PR_POLL_REG_DEST" \
    || [ "$FM_PR_REG_ID" != "$FM_PR_POLL_EXPECT_ID" ] \
    || [ "$FM_PR_REG_PROVIDER" != "$FM_PR_POLL_EXPECT_PROVIDER" ] \
    || [ "$FM_PR_REG_URL" != "$FM_PR_POLL_EXPECT_URL" ] \
    || [ "$FM_PR_REG_HOST" != "$FM_PR_POLL_EXPECT_HOST" ] \
    || [ "$FM_PR_REG_PATH" != "$FM_PR_POLL_EXPECT_PATH" ] \
    || [ "$FM_PR_REG_NUMBER" != "$FM_PR_POLL_EXPECT_NUMBER" ] \
    || [ "$FM_PR_REG_DATA_HASH" != "$FM_PR_POLL_EXPECT_DATA_HASH" ] \
    || [ "$FM_PR_REG_TEMPLATE_HASH" != "$FM_PR_POLL_EXPECT_TEMPLATE_HASH" ] \
    || [ "$FM_PR_REG_DATA_IDENTITY" != "$FM_PR_POLL_EXPECT_DATA_IDENTITY" ] \
    || [ "$FM_PR_REG_CHECK_IDENTITY" != "$FM_PR_POLL_EXPECT_CHECK_IDENTITY" ]; then
    fm_pr_poll_revoke_final || true
    return 1
  fi

  if ! fm_pr_regular_destination_on_device_or_absent "$FM_PR_POLL_CHECK_DEST" "$FM_PR_POLL_STATE_DEVICE" \
    || ! mv -f -- "$FM_PR_POLL_CHECK_TMP" "$FM_PR_POLL_CHECK_DEST"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
  FM_PR_POLL_CHECK_TMP=
  if ! fm_pr_poll_artifacts_valid "${FM_PR_POLL_CHECK_DEST%/*}" "$FM_PR_POLL_EXPECT_ID" "$FM_PR_POLL_TEMPLATE"; then
    fm_pr_poll_revoke_final || true
    return 1
  fi
}

fm_pr_poll_artifacts_valid() {
  local state=$1 id=$2 template=$3 state_device check data registration meta data_hash template_hash data_identity check_identity
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  meta="$state/$id.meta"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || return 1
  cmp -s "$template" "$check" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  template_hash=$(fm_pr_sha256 "$check") || return 1
  data_identity=$(fm_pr_file_identity "$data") || return 1
  check_identity=$(fm_pr_file_identity "$check") || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_REG_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_REG_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_DATA_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$data_hash" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$template_hash" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$data_identity" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$check_identity" ] || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_DATA_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_DATA_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$FM_PR_DATA_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$FM_PR_DATA_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_DATA_NUMBER" ]
}

fm_pr_poll_snapshot_capture() {
  local state=$1 id=$2 template=$3 registration
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  FM_PR_POLL_SNAPSHOT_REG_HASH=$(fm_pr_sha256 "$registration") || return 1
  FM_PR_POLL_SNAPSHOT_REG_IDENTITY=$(fm_pr_file_identity "$registration") || return 1
  FM_PR_POLL_SNAPSHOT_ID=$id
  FM_PR_POLL_SNAPSHOT_PROVIDER=$FM_PR_DATA_PROVIDER
  FM_PR_POLL_SNAPSHOT_URL=$FM_PR_DATA_URL
  FM_PR_POLL_SNAPSHOT_HOST=$FM_PR_DATA_HOST
  FM_PR_POLL_SNAPSHOT_PATH=$FM_PR_DATA_PATH
  FM_PR_POLL_SNAPSHOT_NUMBER=$FM_PR_DATA_NUMBER
  FM_PR_POLL_SNAPSHOT_DATA_HASH=$FM_PR_REG_DATA_HASH
  FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH=$FM_PR_REG_TEMPLATE_HASH
  FM_PR_POLL_SNAPSHOT_DATA_IDENTITY=$FM_PR_REG_DATA_IDENTITY
  FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY=$FM_PR_REG_CHECK_IDENTITY
}

fm_pr_poll_snapshot_matches() {
  local state=$1 id=$2 template=$3 registration reg_hash reg_identity
  [ -n "$FM_PR_POLL_SNAPSHOT_ID" ] && [ "$id" = "$FM_PR_POLL_SNAPSHOT_ID" ] || return 1
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_POLL_SNAPSHOT_PROVIDER" ] || return 1
  [ "$FM_PR_DATA_URL" = "$FM_PR_POLL_SNAPSHOT_URL" ] || return 1
  [ "$FM_PR_DATA_HOST" = "$FM_PR_POLL_SNAPSHOT_HOST" ] || return 1
  [ "$FM_PR_DATA_PATH" = "$FM_PR_POLL_SNAPSHOT_PATH" ] || return 1
  [ "$FM_PR_DATA_NUMBER" = "$FM_PR_POLL_SNAPSHOT_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$FM_PR_POLL_SNAPSHOT_DATA_HASH" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$FM_PR_POLL_SNAPSHOT_REG_HASH" ] || return 1
  [ "$reg_identity" = "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" ]
}

fm_pr_poll_retirement_parse() {
  local file=$1 version id provider url host path number data_hash template_hash
  local data_identity check_identity reg_hash reg_identity result _extra
  FM_PR_RETIRE_ID=
  FM_PR_RETIRE_PROVIDER=
  FM_PR_RETIRE_URL=
  FM_PR_RETIRE_HOST=
  FM_PR_RETIRE_PATH=
  FM_PR_RETIRE_NUMBER=
  FM_PR_RETIRE_DATA_HASH=
  FM_PR_RETIRE_TEMPLATE_HASH=
  FM_PR_RETIRE_DATA_IDENTITY=
  FM_PR_RETIRE_CHECK_IDENTITY=
  FM_PR_RETIRE_REG_HASH=
  FM_PR_RETIRE_REG_IDENTITY=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 9< "$file" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r id <&9 || { exec 9<&-; return 1; }
  IFS= read -r provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r host <&9 || { exec 9<&-; return 1; }
  IFS= read -r path <&9 || { exec 9<&-; return 1; }
  IFS= read -r number <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r template_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r data_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r check_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_hash <&9 || { exec 9<&-; return 1; }
  IFS= read -r reg_identity <&9 || { exec 9<&-; return 1; }
  IFS= read -r result <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-pr-poll-retirement-v1 ] || return 1
  fm_pr_task_id_valid "$id" || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$template_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$data_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$check_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [[ "$reg_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$reg_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  [ "$result" = merged ] || return 1
  FM_PR_RETIRE_ID=$id
  FM_PR_RETIRE_PROVIDER=$provider
  FM_PR_RETIRE_URL=$url
  FM_PR_RETIRE_HOST=$host
  FM_PR_RETIRE_PATH=$path
  FM_PR_RETIRE_NUMBER=$number
  FM_PR_RETIRE_DATA_HASH=$data_hash
  FM_PR_RETIRE_TEMPLATE_HASH=$template_hash
  FM_PR_RETIRE_DATA_IDENTITY=$data_identity
  FM_PR_RETIRE_CHECK_IDENTITY=$check_identity
  FM_PR_RETIRE_REG_HASH=$reg_hash
  FM_PR_RETIRE_REG_IDENTITY=$reg_identity
}

fm_pr_poll_retirement_receipt_valid() {
  local state=$1 id=$2 receipt state_device meta
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_retirement_parse "$receipt" || return 1
  [ "$FM_PR_RETIRE_ID" = "$id" ] || return 1
  meta="$state/$id.meta"
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  FM_PR_RETIRE_RECEIPT_HASH=$(fm_pr_sha256 "$receipt") || return 1
  FM_PR_RETIRE_RECEIPT_IDENTITY=$(fm_pr_file_identity "$receipt") || return 1
}

fm_pr_poll_retirement_data_valid() {
  local state=$1 id=$2 state_device data data_hash data_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  data="$state/$id.pr-poll"
  fm_pr_private_file_valid "$data" 600 "$state_device" || return 1
  fm_pr_poll_data_parse "$data" || return 1
  data_hash=$(fm_pr_sha256 "$data") || return 1
  data_identity=$(fm_pr_file_identity "$data") || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_DATA_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_DATA_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_DATA_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_DATA_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  [ "$data_hash" = "$FM_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$data_identity" = "$FM_PR_RETIRE_DATA_IDENTITY" ]
}

fm_pr_poll_retirement_registration_valid() {
  local state=$1 id=$2 state_device registration reg_hash reg_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  registration="$state/$id.pr-poll-registration"
  fm_pr_private_file_valid "$registration" 600 "$state_device" || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  reg_hash=$(fm_pr_sha256 "$registration") || return 1
  reg_identity=$(fm_pr_file_identity "$registration") || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  [ "$FM_PR_REG_PROVIDER" = "$FM_PR_RETIRE_PROVIDER" ] || return 1
  [ "$FM_PR_REG_URL" = "$FM_PR_RETIRE_URL" ] || return 1
  [ "$FM_PR_REG_HOST" = "$FM_PR_RETIRE_HOST" ] || return 1
  [ "$FM_PR_REG_PATH" = "$FM_PR_RETIRE_PATH" ] || return 1
  [ "$FM_PR_REG_NUMBER" = "$FM_PR_RETIRE_NUMBER" ] || return 1
  [ "$FM_PR_REG_DATA_HASH" = "$FM_PR_RETIRE_DATA_HASH" ] || return 1
  [ "$FM_PR_REG_TEMPLATE_HASH" = "$FM_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_RETIRE_DATA_IDENTITY" ] || return 1
  [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_RETIRE_CHECK_IDENTITY" ] || return 1
  [ "$reg_hash" = "$FM_PR_RETIRE_REG_HASH" ] || return 1
  [ "$reg_identity" = "$FM_PR_RETIRE_REG_IDENTITY" ]
}

fm_pr_poll_retirement_check_valid() {
  local state=$1 id=$2 state_device check check_hash check_identity
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  fm_pr_private_file_valid "$check" 600 "$state_device" || return 1
  check_hash=$(fm_pr_sha256 "$check") || return 1
  check_identity=$(fm_pr_file_identity "$check") || return 1
  [ "$check_hash" = "$FM_PR_RETIRE_TEMPLATE_HASH" ] || return 1
  [ "$check_identity" = "$FM_PR_RETIRE_CHECK_IDENTITY" ]
}

fm_pr_poll_retirement_state_valid() {
  local state=$1 id=$2 check data registration has_check=0 has_data=0 has_registration=0
  fm_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] || has_check=1
  [ ! -e "$data" ] && [ ! -L "$data" ] || has_data=1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || has_registration=1
  if [ "$has_check" -eq 1 ]; then
    [ "$has_data" -eq 1 ] && [ "$has_registration" -eq 1 ] || return 1
    fm_pr_poll_retirement_check_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_data_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  if [ "$has_registration" -eq 1 ]; then
    [ "$has_data" -eq 1 ] || return 1
    fm_pr_poll_retirement_data_valid "$state" "$id" || return 1
    fm_pr_poll_retirement_registration_valid "$state" "$id" || return 1
    return 0
  fi
  [ "$has_data" -eq 0 ] || fm_pr_poll_retirement_data_valid "$state" "$id"
}

fm_pr_poll_retirement_remove_exact() {
  local path=$1 state_device=$2 expected_identity=$3 expected_hash=$4
  fm_pr_private_file_valid "$path" 600 "$state_device" || return 1
  [ "$(fm_pr_file_identity "$path")" = "$expected_identity" ] || return 1
  [ "$(fm_pr_sha256 "$path")" = "$expected_hash" ] || return 1
  rm -f -- "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

fm_pr_poll_retirement_discard_obsolete() {
  local state=$1 id=$2 template=$3 receipt registration state_device
  local receipt_hash receipt_identity current_reg_hash current_reg_identity
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  fm_pr_poll_retirement_parse "$receipt" || return 1
  [ "$FM_PR_RETIRE_ID" = "$id" ] || return 1
  receipt_hash=$(fm_pr_sha256 "$receipt") || return 1
  receipt_identity=$(fm_pr_file_identity "$receipt") || return 1
  fm_pr_poll_artifacts_valid "$state" "$id" "$template" || return 1
  registration="$state/$id.pr-poll-registration"
  current_reg_hash=$(fm_pr_sha256 "$registration") || return 1
  current_reg_identity=$(fm_pr_file_identity "$registration") || return 1
  if [ "$current_reg_hash" = "$FM_PR_RETIRE_REG_HASH" ] \
    && [ "$current_reg_identity" = "$FM_PR_RETIRE_REG_IDENTITY" ] \
    && [ "$FM_PR_REG_DATA_IDENTITY" = "$FM_PR_RETIRE_DATA_IDENTITY" ] \
    && [ "$FM_PR_REG_CHECK_IDENTITY" = "$FM_PR_RETIRE_CHECK_IDENTITY" ]; then
    return 1
  fi
  fm_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash"
}

fm_pr_poll_retirement_publish() {
  local state=$1 id=$2 template=$3 result=$4 receipt state_device tmp
  [ "$result" = merged ] || return 1
  fm_pr_poll_snapshot_matches "$state" "$id" "$template" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  receipt="$state/$id.pr-poll-retirement"
  fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" || return 1
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-retirement.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-retirement-v1 \
      "$FM_PR_POLL_SNAPSHOT_ID" \
      "$FM_PR_POLL_SNAPSHOT_PROVIDER" \
      "$FM_PR_POLL_SNAPSHOT_URL" \
      "$FM_PR_POLL_SNAPSHOT_HOST" \
      "$FM_PR_POLL_SNAPSHOT_PATH" \
      "$FM_PR_POLL_SNAPSHOT_NUMBER" \
      "$FM_PR_POLL_SNAPSHOT_DATA_HASH" \
      "$FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH" \
      "$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY" \
      "$FM_PR_POLL_SNAPSHOT_REG_HASH" \
      "$FM_PR_POLL_SNAPSHOT_REG_IDENTITY" \
      merged > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$state_device" \
    || ! fm_pr_poll_retirement_parse "$tmp" \
    || [ "$FM_PR_RETIRE_ID" != "$id" ] \
    || ! fm_pr_poll_snapshot_matches "$state" "$id" "$template" \
    || ! fm_pr_regular_destination_on_device_or_absent "$receipt" "$state_device" \
    || [ -e "$receipt" ] || [ -L "$receipt" ] \
    || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_poll_retirement_receipt_valid "$state" "$id" || return 1
}

fm_pr_poll_retirement_recover_one() {
  local state=$1 id=$2 template=$3 receipt state_device check data registration
  local receipt_hash receipt_identity
  fm_pr_task_id_valid "$id" || return 1
  receipt="$state/$id.pr-poll-retirement"
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    return 0
  fi
  if ! fm_pr_poll_retirement_state_valid "$state" "$id"; then
    fm_pr_poll_retirement_discard_obsolete "$state" "$id" "$template" && return 0
    return 1
  fi
  state_device=$(fm_pr_file_device "$state") || return 1
  check="$state/$id.check.sh"
  data="$state/$id.pr-poll"
  registration="$state/$id.pr-poll-registration"
  receipt_hash=$FM_PR_RETIRE_RECEIPT_HASH
  receipt_identity=$FM_PR_RETIRE_RECEIPT_IDENTITY
  if [ -e "$check" ] || [ -L "$check" ]; then
    fm_pr_poll_retirement_remove_exact "$check" "$state_device" \
      "$FM_PR_RETIRE_CHECK_IDENTITY" "$FM_PR_RETIRE_TEMPLATE_HASH" || return 1
  fi
  if [ -e "$registration" ] || [ -L "$registration" ]; then
    fm_pr_poll_retirement_remove_exact "$registration" "$state_device" \
      "$FM_PR_RETIRE_REG_IDENTITY" "$FM_PR_RETIRE_REG_HASH" || return 1
  fi
  if [ -e "$data" ] || [ -L "$data" ]; then
    fm_pr_poll_retirement_remove_exact "$data" "$state_device" \
      "$FM_PR_RETIRE_DATA_IDENTITY" "$FM_PR_RETIRE_DATA_HASH" || return 1
  fi
  fm_pr_poll_retirement_remove_exact "$receipt" "$state_device" \
    "$receipt_identity" "$receipt_hash" || return 1
  [ ! -e "$check" ] && [ ! -L "$check" ] \
    && [ ! -e "$registration" ] && [ ! -L "$registration" ] \
    && [ ! -e "$data" ] && [ ! -L "$data" ] \
    && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
}

fm_pr_poll_retirement_recover_all() {
  local state=$1 template=$2 receipt id
  FM_PR_POLL_RETIREMENT_REJECTED=
  for receipt in "$state"/*.pr-poll-retirement; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=$(basename "$receipt" .pr-poll-retirement)
    if ! fm_pr_task_id_valid "$id" \
      || ! fm_pr_poll_retirement_recover_one "$state" "$id" "$template"; then
      FM_PR_POLL_RETIREMENT_REJECTED="$FM_PR_POLL_RETIREMENT_REJECTED $receipt"
    fi
  done
  [ -z "$FM_PR_POLL_RETIREMENT_REJECTED" ]
}

# --- merge-notification canonical-identity marker ----------------------------
# A merged-PR poll retires (fm_pr_poll_retirement_recover_one) in the same
# watcher cycle that detects it, which is normally enough on its own to stop a
# duplicate detection: the check.sh is gone, so nothing re-polls it. The
# exception is the same poll re-registered after its merge was already
# surfaced. Its retirement state is scoped to one registration, so this marker
# carries the canonical PR identity across registrations for the task. Only a
# matching identity is a no-op; a different PR for the same task reaches its
# role-routed supervision destination and replaces the marker when its first
# outcome is published.
fm_pr_poll_merge_marker_matches() {  # <marker> <device> <provider> <host> <path> <number>
  local marker=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6
  local version provider host path number
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  exec 8< "$marker" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-pr-poll-merge-notified-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ]
}

fm_pr_poll_merge_already_notified() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-merge-notified"
  fm_pr_poll_merge_marker_matches "$marker" "$state_device" \
    "$provider" "$host" "$path" "$number"
}

fm_pr_poll_merge_mark_notified() {  # <state> <id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 marker tmp state_device
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  marker="$state/$id.pr-poll-merge-notified"
  fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-pr-poll-merge-notified.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n' \
      fm-pr-poll-merge-notified-v1 "$provider" "$host" "$path" "$number" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_poll_merge_marker_matches "$tmp" "$state_device" \
      "$provider" "$host" "$path" "$number" \
    || ! fm_pr_regular_destination_on_device_or_absent "$marker" "$state_device" \
    || ! mv -f -- "$tmp" "$marker" \
    || ! fm_pr_poll_merge_marker_matches "$marker" "$state_device" \
      "$provider" "$host" "$path" "$number"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Removed at teardown alongside the other per-task PR-poll artifacts
# (bin/fm-teardown.sh) so a retired task id leaves no residue behind.
fm_pr_poll_merge_notified_remove() {  # <state> <id>
  local state=$1 id=$2 marker
  fm_pr_task_id_valid "$id" || return 1
  marker="$state/$id.pr-poll-merge-notified"
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  rm -f -- "$marker"
}
