#!/usr/bin/env bash
# fm-validation-loop-lib.sh - deterministic rational limits for the automatic
# continuation of a crew's no-mistakes validation loop.
#
# WHY THIS EXISTS. The supervision absorb path (crew_absorb_class in
# bin/fm-classify-lib.sh) keeps absorbing wakes for as long as a crew is
# "provably working", and an actively-running no-mistakes step is exactly such
# proof. Nothing bounded HOW LONG that proof may be recycled: a run looping
# through fix rounds forever, re-presenting the same findings after every fix,
# or claiming `running` while its evidence never changes, was absorbed as
# routine progress indefinitely. This library is the ONE owner of the
# continue/stop decision that closes that hole, and of the durable per-task
# journal the decision is computed from.
#
# CONTRACT (accepted captain contract, stated once, here):
#   - A validation run may CONTINUE automatically while it has fresh evidence,
#     a coherent head advance, a bounded known change set, and a credible path
#     to completion (counters below every bound, evidence still moving).
#   - Automatic continuation STOPS when the loop is repetitive (fix rounds or
#     an identical findings theme past its bound), no longer advancing (active
#     run evidence frozen past the stall bound), or its pipeline evidence has
#     gone stale (an active run recorded here, but no readable run evidence
#     within the freshness bound - the unknown/unreadable/dead case).
#   - A stop NEVER touches the worker, the branch, the worktree, or the run:
#     it only flips the absorb verdict so the wake surfaces to the supervisor
#     with the recorded reason. Custody of the branch and the validation run
#     stays exactly where it was; recovery goes through the supported
#     same-copy path (stuck-crewmate-recovery, and AGENTS.md section 7's
#     supported abort/custody sequence for the run itself). Never a duplicate
#     worker, never a discarded change, never an approved or skipped failing
#     check, and the decision itself is pure bash - no LLM in the watcher.
#   - A threshold breach is never reported as routine progress: the journal
#     records the verdict durably, bin/fm-crew-state.sh decorates its detail
#     with it, and the watcher's surfaced reason names it.
#
# THRESHOLDS (all env-overridable; the bound is the count or age still treated
# as routine, and the first observation strictly past it stops):
#   FM_VLOOP_MAX_FIX_ROUNDS        default 6    observed entries into a fixing
#                                               phase for one run
#   FM_VLOOP_MAX_SAME_THEME        default 2    separate presentations of an
#                                               IDENTICAL findings set (the
#                                               third identical presentation
#                                               stops)
#   FM_VLOOP_STALL_SECS            default 3600 seconds an active running or
#                                               fixing run may show zero
#                                               evidence change
#   FM_VLOOP_EVIDENCE_MAX_AGE_SECS default 7200 seconds an active-run journal
#                                               stays fresh enough to justify
#                                               continuation with no new
#                                               readable run evidence
#   FM_VLOOP_MAX_CHANGE_COMMITS   default 64    commits accepted in one
#                                               coherent head transition
#   FM_VLOOP_MAX_CHANGE_FILES     default 256   existing project files changed
#                                               in one coherent head transition
#
# JOURNAL. state/<id>.validation-loop, key=value lines, rewritten atomically
# (tmp + mv) by fm_vloop_observe only; removed by teardown with the task's
# other state. Single writer by construction: the only folding caller is
# crew_absorb_class, which runs inside the watcher singleton (or the away-mode
# daemon that replaces it). Counters reset when the attributed run id changes,
# which is what hands a supervised recovery (a new run on the same branch and
# copy) a clean slate; removing the journal is the documented operator reset
# when the captain authorizes continuing a stopped loop as-is.
#
# EVIDENCE. fm_vloop_observe consumes the evidence file bin/fm-crew-state.sh
# exports when FM_CREW_STATE_EVIDENCE_FILE is set: the raw `axi status` TOON
# for a fully attributed run, or one `coarse: <status>` line from the
# runs-list fallback. A missing or unparseable evidence file folds nothing -
# this library never fabricates an observation.
#
# All functions are safe under `set -u` and never exit the caller; observe
# returns 2 for malformed evidence and 1 when the journal write itself fails.

# Directory of this library, for the sibling TOON field helpers.
_FM_VLOOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_VLOOP_LIB_DIR="."
# shellcheck source=bin/fm-nm-run-lib.sh
. "$_FM_VLOOP_LIB_DIR/fm-nm-run-lib.sh"

FM_VLOOP_MAX_FIX_ROUNDS_DEFAULT=6
FM_VLOOP_MAX_SAME_THEME_DEFAULT=2
FM_VLOOP_STALL_SECS_DEFAULT=3600
FM_VLOOP_EVIDENCE_MAX_AGE_SECS_DEFAULT=7200
FM_VLOOP_MAX_CHANGE_COMMITS_DEFAULT=64
FM_VLOOP_MAX_CHANGE_FILES_DEFAULT=256
fm_vloop_journal_path() {  # <state> <id>
  printf '%s/%s.validation-loop' "$1" "$2"
}

_fm_vloop_now() {
  printf '%s' "${FM_VLOOP_NOW:-$(date +%s)}"
}

_fm_vloop_hash() {  # stdin -> md5 hex
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# A positive-integer env value, else its default. Never lets a cleared or
# malformed override disable a bound.
_fm_vloop_bound() {  # <value> <default>
  case "${1:-}" in
    ''|*[!0-9]*|0) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Print the indented comma rows of one TOON table block ("<name>[N]{...}:").
_fm_vloop_block_rows() {  # <content> <table-name>
  printf '%s\n' "$1" | awk -v name="$2" '
    found {
      if ($0 ~ /^[[:space:]]+[^[:space:]].*$/) { print; next }
      exit
    }
    $0 ~ ("^[[:space:]]*" name "\\[[0-9]+\\]\\{") { found = 1 }
  '
}

# Findings theme signature: the md5 of the sorted findings rows with each
# row's first field (the per-run finding id, which changes every round even
# when the finding itself does not) stripped. Identical wording, file, and
# action therefore read as the same theme; any wording change reads as a new
# theme, so undersampling can only delay a stop, never invent one. Empty when
# the evidence carries no findings rows.
_fm_vloop_findings_sig() {  # <content>
  local rows
  rows=$(_fm_vloop_block_rows "$1" findings)
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | sed 's/^[[:space:]]*[^,]*,[[:space:]]*//' | LC_ALL=C sort | _fm_vloop_hash
}

# Steps-progress signature: the md5 of the steps rows with each row's LAST
# field (duration, which ticks on every read) stripped, so a step transition
# counts as evidence advance while a mere clock tick does not. Empty when the
# evidence carries no steps table.
_fm_vloop_steps_sig() {  # <content>
  local rows
  rows=$(_fm_vloop_block_rows "$1" steps)
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | sed -e 's/^[[:space:]]*//' -e 's/,[^,]*$//' | _fm_vloop_hash
}

# Derived loop phase, precedence: terminal beats gate beats fixing beats ci
# beats running. A parked gate outranks a concurrent fixing/ci step row
# because a parked run is surfaced as parked, not absorbed as working.
_fm_vloop_phase() {  # <content> <status> <outcome>
  local content=$1 status=$2 outcome=$3
  if [ -n "$outcome" ]; then printf 'terminal'; return; fi
  case "$status" in completed|failed|cancelled) printf 'terminal'; return ;; esac
  case "$status" in awaiting_approval|fix_review) printf 'gate'; return ;; esac
  if printf '%s\n' "$content" | grep -qE '^[[:space:]]*(gate|awaiting_agent):'; then
    printf 'gate'; return
  fi
  if [ "$status" = fixing ] || printf '%s\n' "$content" | grep -qE '^[[:space:]]+[^[:space:]]+,[[:space:]]*"?fixing"?[[:space:]]*,'; then
    printf 'fixing'; return
  fi
  if [ "$status" = ci ] || printf '%s\n' "$content" | grep -qE '^[[:space:]]*ci,[[:space:]]*"?running"?[[:space:]]*,'; then
    printf 'ci'; return
  fi
  printf 'running'
}

_fm_vloop_journal_get() {  # <journal-content> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

_fm_vloop_status_valid() {  # <status>
  case "$1" in
    running|fixing|ci|awaiting_approval|fix_review|completed|failed|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

_fm_vloop_outcome_valid() {  # <status> <outcome>
  case "$2" in
    '') return 0 ;;
    passed|checks-passed) [ "$1" = completed ] && return 0 ;;
    failed) case "$1" in completed|failed) return 0 ;; esac ;;
    cancelled) case "$1" in completed|cancelled) return 0 ;; esac ;;
  esac
  return 1
}

_fm_vloop_scope_paths() {  # <evidence>
  local content=$1 table rows row path
  for table in changes change_set changed_files; do
    rows=$(_fm_vloop_block_rows "$content" "$table")
    [ -n "$rows" ] || continue
    while IFS= read -r row; do
      path=${row%%,*}
      path=$(fm_nm_trim "$path")
      [ -n "$path" ] || return 1
      printf '%s\n' "$path"
    done <<EOF
$rows
EOF
    return 0
  done
}

_fm_vloop_scope_valid() {  # <worktree> <base> <head> <paths>
  local worktree=$1 base=$2 head=$3 paths=$4 base_full head_full path seen='' count=0 max_files
  local change_files change_file change_count max_change max_commits
  [ -n "$worktree" ] && [ -n "$base" ] && [ -n "$head" ] && [ -n "$paths" ] || return 1
  base_full=$(git -C "$worktree" rev-parse --verify "${base}^{commit}" 2>/dev/null) || return 1
  head_full=$(git -C "$worktree" rev-parse --verify "${head}^{commit}" 2>/dev/null) || return 1
  git -C "$worktree" merge-base --is-ancestor "$base_full" "$head_full" 2>/dev/null || return 1
  max_files=$(_fm_vloop_bound "${FM_VLOOP_MAX_CHANGE_FILES:-}" "$FM_VLOOP_MAX_CHANGE_FILES_DEFAULT")
  for path in $paths; do
    [ -n "$path" ] || return 1
    count=$((count + 1))
    [ "$count" -le "$max_files" ] || return 1
    case " $seen " in *" $path "*) return 1 ;; esac
    seen="$seen $path"
    case "$path" in
      /*|../*|*/../*|*[[:space:]]*|*\|*) return 1 ;;
    esac
  done
  max_commits=$(_fm_vloop_bound "${FM_VLOOP_MAX_CHANGE_COMMITS:-}" "$FM_VLOOP_MAX_CHANGE_COMMITS_DEFAULT")
  max_change=$(git -C "$worktree" rev-list --count "$base_full..$head_full" 2>/dev/null) || return 1
  [ "$max_change" -le "$max_commits" ] || return 1
  change_files=$(git -C "$worktree" diff --name-only --no-renames "$base_full" "$head_full" 2>/dev/null) || return 1
  change_count=$(printf '%s\n' "$change_files" | awk 'NF { count += 1 } END { print count + 0 }')
  [ "$change_count" -eq "$count" ] || return 1
  [ "$change_count" -le "$max_files" ] || return 1
  while IFS= read -r change_file; do
    [ -n "$change_file" ] || continue
    case "$change_file" in
      /*|../*|*/../*|*[[:space:]]*|*\|*) return 1 ;;
    esac
    _fm_vloop_scope_contains "$paths" "$change_file" || return 1
  done <<EOF
$change_files
EOF
}

_fm_vloop_scope_contains() {  # <paths> <path>
  local path
  for path in $1; do
    [ "$path" = "$2" ] && return 0
  done
  return 1
}

_fm_vloop_journal_valid() {  # <journal-content>
  local stored=$1 key value version phase active scope_base scope_head scope_paths scope_count max_files
  for key in version run head status phase findings_sig progress_sig fix_rounds themes heads last_observed last_progress active stop_reason scope_base scope_head scope_paths; do
    printf '%s\n' "$stored" | grep -q "^$key=" || return 1
  done
  version=$(_fm_vloop_journal_get "$stored" version)
  [ "$version" = 1 ] || return 1
  status=$(_fm_vloop_journal_get "$stored" status)
  _fm_vloop_status_valid "$status" || return 1
  phase=$(_fm_vloop_journal_get "$stored" phase)
  case "$phase" in
    running|fixing|ci|gate|terminal|coarse) ;;
    *) return 1 ;;
  esac
  active=$(_fm_vloop_journal_get "$stored" active)
  case "$active" in 0|1) ;; *) return 1 ;; esac
  case "$phase" in
    running)
      [ "$active" = 1 ] || return 1
      [ "$status" = running ] || return 1
      ;;
    fixing)
      [ "$active" = 1 ] || return 1
      case "$status" in fixing|running) ;; *) return 1 ;; esac
      ;;
    ci)
      [ "$active" = 1 ] || return 1
      case "$status" in ci|running) ;; *) return 1 ;; esac
      ;;
    gate)
      [ "$active" = 1 ] || return 1
      case "$status" in awaiting_approval|fix_review|running) ;; *) return 1 ;; esac
      ;;
    terminal)
      [ "$active" = 0 ] || return 1
      case "$status" in completed|failed|cancelled) ;; *) return 1 ;; esac
      ;;
    coarse)
      case "$status:$active" in
        running:1|completed:0|failed:0|cancelled:0) ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  value=$(_fm_vloop_journal_get "$stored" fix_rounds)
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  for key in last_observed last_progress; do
    value=$(_fm_vloop_journal_get "$stored" "$key")
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
  done
  if [ "$phase" != coarse ]; then
    for key in run head; do
      value=$(_fm_vloop_journal_get "$stored" "$key")
      [ -n "$value" ] || return 1
    done
  else
    case "$status" in running|completed|failed|cancelled) ;; *) return 1 ;; esac
  fi
  scope_base=$(_fm_vloop_journal_get "$stored" scope_base)
  scope_head=$(_fm_vloop_journal_get "$stored" scope_head)
  scope_paths=$(_fm_vloop_journal_get "$stored" scope_paths)
  if [ -n "$scope_base" ] || [ -n "$scope_head" ] || [ -n "$scope_paths" ]; then
    [ -n "$scope_base" ] && [ -n "$scope_head" ] && [ -n "$scope_paths" ] || return 1
    case "$scope_base:$scope_head" in *[[:space:]]*) return 1 ;; esac
    scope_count=$(printf '%s\n' "$scope_paths" | awk 'NF { count += 1 } END { print count + 0 }')
    max_files=$(_fm_vloop_bound "${FM_VLOOP_MAX_CHANGE_FILES:-}" "$FM_VLOOP_MAX_CHANGE_FILES_DEFAULT")
    [ "$scope_count" -le "$max_files" ] || return 1
    for value in $scope_paths; do
      case "$value" in
        ''|*[[:space:]]*|/*|../*|*/../*|*\|*) return 1 ;;
      esac
    done
  fi
  return 0
}

# Bump <sig> in a "sig:count sig:count ..." theme list, appending a new sig.
_fm_vloop_themes_bump() {  # <themes> <sig>
  local themes=$1 sig=$2 out='' entry found=0 count
  for entry in $themes; do
    case "$entry" in
      "$sig":*)
        count=${entry#*:}
        case "$count" in ''|*[!0-9]*) count=0 ;; esac
        entry="$sig:$((count + 1))"
        found=1
        ;;
    esac
    out="$out$entry "
  done
  [ "$found" = 1 ] || out="$out$sig:1 "
  out=${out% }
  printf '%s' "$out"
}

# Highest count in a theme list, with the winning signature: "<count> <sig>".
_fm_vloop_themes_max() {  # <themes>
  local entry max=0 max_sig='' count
  for entry in ${1:-}; do
    count=${entry#*:}
    case "$count" in ''|*[!0-9]*) continue ;; esac
    if [ "$count" -gt "$max" ]; then
      max=$count
      max_sig=${entry%%:*}
    fi
  done
  printf '%s %s' "$max" "$max_sig"
}

fm_vloop_evidence_valid() {  # <content>
  local content=$1 first key value status outcome
  first=${content%%$'\n'*}
  [ "$first" = run: ] || return 1
  for key in id branch status head; do
    value=$(fm_nm_strip_quotes "$(fm_nm_field "$content" "$key")")
    [ -n "$value" ] || return 1
    case "$value" in *[[:space:]]*) return 1 ;; esac
  done
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$content" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$content" outcome)")
  _fm_vloop_status_valid "$status" || return 1
  _fm_vloop_outcome_valid "$status" "$outcome" || return 1
  return 0
}

_fm_vloop_head_seen() {  # <heads> <head>
  local entry
  for entry in ${1:-}; do
    [ "$entry" = "$2" ] && return 0
  done
  return 1
}

_fm_vloop_head_advance_valid() {  # <worktree> <old-head> <new-head> <scope-paths>
  local worktree=$1 old_head=$2 new_head=$3 scope_paths=${4:-} old_full new_full change_commits max_change
  local change_files change_file change_count max_files
  [ -n "$worktree" ] || return 1
  old_full=$(git -C "$worktree" rev-parse --verify "${old_head}^{commit}" 2>/dev/null) || return 1
  new_full=$(git -C "$worktree" rev-parse --verify "${new_head}^{commit}" 2>/dev/null) || return 1
  [ "$old_full" = "$new_full" ] && return 1
  git -C "$worktree" merge-base --is-ancestor "$old_full" "$new_full" 2>/dev/null || return 1
  fm_nm_head_matches_worktree "$worktree" "$new_full" || return 1
  change_commits=$(git -C "$worktree" rev-list --count "$old_full..$new_full" 2>/dev/null) || return 1
  max_change=$(_fm_vloop_bound "${FM_VLOOP_MAX_CHANGE_COMMITS:-}" "$FM_VLOOP_MAX_CHANGE_COMMITS_DEFAULT")
  [ "$change_commits" -le "$max_change" ] || return 1
  change_files=$(git -C "$worktree" diff --name-only --no-renames "$old_full" "$new_full" 2>/dev/null) || return 1
  [ -n "$change_files" ] || return 1
  change_count=$(printf '%s\n' "$change_files" | awk 'NF { count += 1 } END { print count + 0 }')
  max_files=$(_fm_vloop_bound "${FM_VLOOP_MAX_CHANGE_FILES:-}" "$FM_VLOOP_MAX_CHANGE_FILES_DEFAULT")
  [ "$change_count" -le "$max_files" ] || return 1
  [ -n "$scope_paths" ] || return 1
  while IFS= read -r change_file; do
    [ -n "$change_file" ] || return 1
    case "$change_file" in
      /*|../*|*/../*) return 1 ;;
    esac
    _fm_vloop_scope_contains "$scope_paths" "$change_file" || return 1
  done <<EOF
$change_files
EOF
}

_fm_vloop_record_stop() {  # <state> <id> <reason>
  local state=$1 id=$2 reason=$3 journal tmp
  journal=$(fm_vloop_journal_path "$state" "$id")
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 0
  cat "$journal" >/dev/null 2>&1 || return 1
  tmp="$journal.tmp.$$"
  awk -v reason="$reason" '
    BEGIN { found = 0 }
    /^stop_reason=/ { print "stop_reason=" reason; found = 1; next }
    { print }
    END { if (!found) print "stop_reason=" reason }
  ' "$journal" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
}

_fm_vloop_time_stop_reason() {  # <journal-content> <now>
  local stored=$1 now=$2 active stop_reason last_observed phase last_progress age max_age stall
  active=$(_fm_vloop_journal_get "$stored" active)
  [ "$active" = 1 ] || return 0
  stop_reason=$(_fm_vloop_journal_get "$stored" stop_reason)
  if [ -n "$stop_reason" ]; then
    printf '%s' "$stop_reason"
    return 0
  fi
  last_observed=$(_fm_vloop_journal_get "$stored" last_observed)
  case "$last_observed" in ''|*[!0-9]*) return 0 ;; esac
  max_age=$(_fm_vloop_bound "${FM_VLOOP_EVIDENCE_MAX_AGE_SECS:-}" "$FM_VLOOP_EVIDENCE_MAX_AGE_SECS_DEFAULT")
  age=$((now - last_observed))
  if [ "$age" -gt "$max_age" ]; then
    printf 'pipeline evidence stale: an active run was last readable %ss ago (bound %ss); current run state is unknown' "$age" "$max_age"
    return 0
  fi
  phase=$(_fm_vloop_journal_get "$stored" phase)
  case "$phase" in
    running|fixing)
      last_progress=$(_fm_vloop_journal_get "$stored" last_progress)
      case "$last_progress" in ''|*[!0-9]*) return 0 ;; esac
      stall=$(_fm_vloop_bound "${FM_VLOOP_STALL_SECS:-}" "$FM_VLOOP_STALL_SECS_DEFAULT")
      age=$((now - last_progress))
      if [ "$age" -gt "$stall" ]; then
        printf 'no evidence advance for %ss while the run claims %s (bound %ss)' "$age" "$phase" "$stall"
      fi
      ;;
  esac
}

_fm_vloop_record_time_stop() {  # <state> <id> <now>
  local state=$1 id=$2 now=$3 journal stored reason
  journal=$(fm_vloop_journal_path "$state" "$id")
  [ -e "$journal" ] || [ -L "$journal" ] || return 0
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  stored=$(cat "$journal" 2>/dev/null) || return 1
  _fm_vloop_journal_valid "$stored" || return 1
  reason=$(_fm_vloop_time_stop_reason "$stored" "$now")
  [ -n "$reason" ] || return 0
  _fm_vloop_record_stop "$state" "$id" "$reason"
}

# Fold one exported evidence file into the durable journal and recompute the
# counter-breach verdict. Never touches anything but the journal; a missing or
# empty evidence file folds only time-based breaches. 2 rejects malformed
# evidence and 1 reports a journal write failure.
fm_vloop_observe() {  # <state> <id> <evidence-file>
  local state=$1 id=$2 ev=$3 worktree=${4:-${FM_VLOOP_WORKTREE:-}} journal now content first stored=''
  local run_id status outcome head phase findings_sig steps_sig progress_sig
  local s_run s_phase s_findings_sig s_progress_sig s_fix_rounds s_themes s_last_progress s_status s_stop_reason s_head s_heads
  local s_scope_base s_scope_head s_scope_paths scope_base scope_head scope_paths evidence_base evidence_paths
  local fix_rounds themes heads last_progress active stop_reason='' max_fix max_theme theme_max tmp
  local head_transition=0
  [ -n "$state" ] && [ -d "$state" ] || return 0
  journal=$(fm_vloop_journal_path "$state" "$id")
  now=$(_fm_vloop_now)
  if [ ! -f "$ev" ] || [ ! -s "$ev" ]; then
    _fm_vloop_record_time_stop "$state" "$id" "$now" || return 1
    return 0
  fi
  content=$(cat "$ev" 2>/dev/null) || return 0
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    [ -f "$journal" ] && [ ! -L "$journal" ] || return 2
    stored=$(cat "$journal" 2>/dev/null) || return 2
    _fm_vloop_journal_valid "$stored" || return 2
  fi
  s_run=$(_fm_vloop_journal_get "$stored" run)
  s_phase=$(_fm_vloop_journal_get "$stored" phase)
  s_status=$(_fm_vloop_journal_get "$stored" status)
  s_findings_sig=$(_fm_vloop_journal_get "$stored" findings_sig)
  s_progress_sig=$(_fm_vloop_journal_get "$stored" progress_sig)
  s_fix_rounds=$(_fm_vloop_journal_get "$stored" fix_rounds)
  s_themes=$(_fm_vloop_journal_get "$stored" themes)
  s_last_progress=$(_fm_vloop_journal_get "$stored" last_progress)
  s_stop_reason=$(_fm_vloop_journal_get "$stored" stop_reason)
  s_head=$(_fm_vloop_journal_get "$stored" head)
  s_heads=$(_fm_vloop_journal_get "$stored" heads)
  s_scope_base=$(_fm_vloop_journal_get "$stored" scope_base)
  s_scope_head=$(_fm_vloop_journal_get "$stored" scope_head)
  s_scope_paths=$(_fm_vloop_journal_get "$stored" scope_paths)
  case "$s_fix_rounds" in ''|*[!0-9]*) s_fix_rounds=0 ;; esac
  case "$s_last_progress" in ''|*[!0-9]*) s_last_progress=$now ;; esac

  first=${content%%$'\n'*}
  case "$first" in
    coarse:*)
      # Coarse evidence has no run id, head, or step detail: it refreshes
      # freshness, and a coarse status change counts as evidence advance, but
      # counters and run identity stay untouched.
      status=$(fm_nm_trim "${first#coarse:}")
      [ -n "$status" ] || return 2
      last_progress=$now
      case "$status" in
        completed|failed|cancelled) active=0 ;;
        *) active=1 ;;
      esac
      tmp="$journal.tmp.$$"
      {
        printf 'version=1\n'
        printf 'run=%s\n' "$s_run"
        printf 'head=%s\n' "$(_fm_vloop_journal_get "$stored" head)"
        printf 'status=%s\n' "$status"
        printf 'phase=coarse\n'
        printf 'findings_sig=%s\n' "$s_findings_sig"
        printf 'progress_sig=%s\n' "$s_progress_sig"
        printf 'fix_rounds=%s\n' "$s_fix_rounds"
        printf 'themes=%s\n' "$s_themes"
        printf 'last_observed=%s\n' "$now"
        printf 'last_progress=%s\n' "$last_progress"
        printf 'active=%s\n' "$active"
        printf 'heads=%s\n' "$(_fm_vloop_journal_get "$stored" heads)"
        printf 'stop_reason=%s\n' "$s_stop_reason"
        printf 'scope_base=%s\n' "$s_scope_base"
        printf 'scope_head=%s\n' "$s_scope_head"
        printf 'scope_paths=%s\n' "$s_scope_paths"
      } > "$tmp" || { rm -f "$tmp"; return 1; }
      mv -f "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
      return 0
      ;;
    *)
      fm_vloop_evidence_valid "$content" || {
        _fm_vloop_record_stop "$state" "$id" "validation evidence malformed or incomplete for task $id" || return 1
        return 2
      }
      ;;
  esac

  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$content" id)")
  [ -n "$run_id" ] || return 0
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$content" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$content" outcome)")
  head=$(fm_nm_strip_quotes "$(fm_nm_field "$content" head)")
  phase=$(_fm_vloop_phase "$content" "$status" "$outcome")
  findings_sig=$(_fm_vloop_findings_sig "$content")
  steps_sig=$(_fm_vloop_steps_sig "$content")
  evidence_base=$(fm_nm_strip_quotes "$(fm_nm_field "$content" base)")
  evidence_paths=$(_fm_vloop_scope_paths "$content" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  if [ -n "$evidence_base" ] || [ -n "$evidence_paths" ]; then
    _fm_vloop_scope_valid "$worktree" "$evidence_base" "$head" "$evidence_paths" || {
      stop_reason="validation change-set manifest is invalid or untrusted for run $run_id"
    }
  fi

  fix_rounds=$s_fix_rounds
  themes=$s_themes
  heads=$s_heads
  last_progress=$s_last_progress
  if [ "$run_id" != "$s_run" ]; then
    # A new run id is the supervised recovery handoff: the loop being bounded
    # is per run, so a replacement run on the same branch and copy starts with
    # a clean slate.
    fix_rounds=0
    themes=''
    s_phase=''
    s_findings_sig=''
    s_stop_reason=''
    s_head=''
    heads=$head
    last_progress=$now
    scope_base=$evidence_base
    scope_paths=$evidence_paths
    if [ -n "$scope_base" ] || [ -n "$scope_paths" ]; then scope_head=$head; else scope_head=''; fi
  elif [ -z "$heads" ]; then
    heads=$head
    scope_base=$s_scope_base
    scope_head=$s_scope_head
    scope_paths=$s_scope_paths
  elif [ -n "$evidence_base" ] || [ -n "$evidence_paths" ]; then
    if [ "$evidence_base" != "$s_scope_base" ] || [ "$evidence_paths" != "$s_scope_paths" ]; then
      stop_reason="validation change-set scope changed without a recovery handoff for run $run_id"
    fi
    scope_base=$s_scope_base
    scope_head=$s_scope_head
    scope_paths=$s_scope_paths
  else
    scope_base=$s_scope_base
    scope_head=$s_scope_head
    scope_paths=$s_scope_paths
  fi
  if [ -z "$stop_reason" ] && [ "$run_id" = "$s_run" ] && [ -n "$s_head" ] && [ "$head" != "$s_head" ]; then
    if _fm_vloop_head_seen "$heads" "$head"; then
      stop_reason="incoherent head transition from ${s_head:-unknown} to $head for run $run_id"
    elif _fm_vloop_head_advance_valid "$worktree" "$s_head" "$head" "$scope_paths"; then
      head_transition=1
      heads="$heads $head"
    else
      stop_reason="incoherent head transition from ${s_head:-unknown} to $head for run $run_id"
    fi
  fi

  progress_sig=$(printf '%s|%s|%s|%s|%s|%s|%s' \
    "$run_id" "$head" "$status" "$outcome" "$phase" "$findings_sig" "$steps_sig" | _fm_vloop_hash)
  if [ "$progress_sig" != "$s_progress_sig" ] && { [ "$head" = "$s_head" ] || [ "$head_transition" = 1 ] || [ "$run_id" != "$s_run" ]; }; then
    last_progress=$now
  fi

  if [ "$phase" = fixing ] && [ "$s_phase" != fixing ]; then
    fix_rounds=$((fix_rounds + 1))
  fi
  if [ -n "$findings_sig" ] && [ "$findings_sig" != "$s_findings_sig" ]; then
    themes=$(_fm_vloop_themes_bump "$themes" "$findings_sig")
  fi

  if [ "$phase" = terminal ]; then active=0; else active=1; fi
  [ -n "$stop_reason" ] || stop_reason=$s_stop_reason

  max_fix=$(_fm_vloop_bound "${FM_VLOOP_MAX_FIX_ROUNDS:-}" "$FM_VLOOP_MAX_FIX_ROUNDS_DEFAULT")
  max_theme=$(_fm_vloop_bound "${FM_VLOOP_MAX_SAME_THEME:-}" "$FM_VLOOP_MAX_SAME_THEME_DEFAULT")
  theme_max=$(_fm_vloop_themes_max "$themes")
  theme_max=${theme_max%% *}
  if [ "$fix_rounds" -gt "$max_fix" ]; then
    stop_reason="fix rounds $fix_rounds exceeded bound $max_fix for run $run_id"
  elif [ "${theme_max:-0}" -gt "$max_theme" ]; then
    stop_reason="identical findings theme presented $theme_max times, exceeding bound $max_theme, for run $run_id"
  fi

  tmp="$journal.tmp.$$"
  {
    printf 'version=1\n'
    printf 'run=%s\n' "$run_id"
    printf 'head=%s\n' "$head"
    printf 'status=%s\n' "$status"
    printf 'phase=%s\n' "$phase"
    printf 'findings_sig=%s\n' "$findings_sig"
    printf 'progress_sig=%s\n' "$progress_sig"
    printf 'fix_rounds=%s\n' "$fix_rounds"
    printf 'themes=%s\n' "$themes"
    printf 'heads=%s\n' "$heads"
    printf 'last_observed=%s\n' "$now"
    printf 'last_progress=%s\n' "$last_progress"
    printf 'active=%s\n' "$active"
    printf 'stop_reason=%s\n' "$stop_reason"
    printf 'scope_base=%s\n' "$scope_base"
    printf 'scope_head=%s\n' "$scope_head"
    printf 'scope_paths=%s\n' "$scope_paths"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
  return 0
}

# The continue/stop verdict, one line: "continue", or "stop <reason>". A time
# breach is recorded here at the shared journal boundary before the reason is
# returned, so a later note-render sees the same durable stop.
fm_vloop_verdict() {  # <state> <id>
  local state=$1 id=$2 journal stored now active stop_reason
  journal=$(fm_vloop_journal_path "$state" "$id")
  if [ ! -e "$journal" ] && [ ! -L "$journal" ]; then
    printf 'continue'
    return 0
  fi
  if [ -L "$journal" ] || [ ! -f "$journal" ]; then
    printf 'stop validation-loop journal unreadable or incomplete; recover in the same copy'
    return 1
  fi
  stored=$(cat "$journal" 2>/dev/null) || {
    printf 'stop validation-loop journal unreadable or incomplete; recover in the same copy'
    return 1
  }
  if ! _fm_vloop_journal_valid "$stored"; then
    printf 'stop validation-loop journal unreadable or incomplete; recover in the same copy'
    return 1
  fi
  active=$(_fm_vloop_journal_get "$stored" active)
  [ "$active" = 1 ] || { printf 'continue'; return 0; }
  now=$(_fm_vloop_now)
  stop_reason=$(_fm_vloop_journal_get "$stored" stop_reason)
  if [ -n "$stop_reason" ]; then
    printf 'stop %s' "$stop_reason"
    return 0
  fi
  stop_reason=$(_fm_vloop_time_stop_reason "$stored" "$now")
  if [ -n "$stop_reason" ]; then
    if ! _fm_vloop_record_stop "$state" "$id" "$stop_reason"; then
      printf 'stop %s' "$stop_reason"
      return 1
    fi
    printf 'stop %s' "$stop_reason"
    return 0
  fi
  printf 'continue'
}

# The current stop reason alone (empty on continue), for wake decoration.
fm_vloop_reason() {  # <state> <id>
  local journal stored
  journal=$(fm_vloop_journal_path "$1" "$2")
  [ -e "$journal" ] || [ -L "$journal" ] || return 0
  if [ -L "$journal" ] || [ ! -f "$journal" ]; then
    printf 'validation-loop journal unreadable or incomplete; recover in the same copy'
    return 0
  fi
  stored=$(cat "$journal" 2>/dev/null) || {
    printf 'validation-loop journal unreadable or incomplete; recover in the same copy'
    return 0
  }
  if ! _fm_vloop_journal_valid "$stored"; then
    printf 'validation-loop journal unreadable or incomplete; recover in the same copy'
    return 0
  fi
  _fm_vloop_journal_get "$stored" stop_reason
}
