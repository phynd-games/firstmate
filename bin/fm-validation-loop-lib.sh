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
# returns non-zero only when the journal write itself fails.

# Directory of this library, for the sibling TOON field helpers.
_FM_VLOOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_VLOOP_LIB_DIR="."
# shellcheck source=bin/fm-nm-run-lib.sh
. "$_FM_VLOOP_LIB_DIR/fm-nm-run-lib.sh"

FM_VLOOP_MAX_FIX_ROUNDS_DEFAULT=6
FM_VLOOP_MAX_SAME_THEME_DEFAULT=2
FM_VLOOP_STALL_SECS_DEFAULT=3600
FM_VLOOP_EVIDENCE_MAX_AGE_SECS_DEFAULT=7200
# Newest-first cap on distinct findings themes the journal tracks; older
# themes age out, so one long run cannot grow the journal without bound.
FM_VLOOP_THEME_CAP=8

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
      if ($0 ~ /^[[:space:]]+[^[:space:]].*,/) { print; next }
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

# Bump <sig> in a "sig:count sig:count ..." theme list, appending a new sig
# and dropping the oldest entry past FM_VLOOP_THEME_CAP.
_fm_vloop_themes_bump() {  # <themes> <sig>
  local themes=$1 sig=$2 out='' entry found=0 count n=0
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
  # Enforce the cap by dropping from the front (oldest first).
  n=$(printf '%s\n' "$out" | wc -w | tr -d '[:space:]')
  while [ "${n:-0}" -gt "$FM_VLOOP_THEME_CAP" ]; do
    out=${out#* }
    n=$((n - 1))
  done
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

# Fold one exported evidence file into the durable journal and recompute the
# counter-breach verdict. Never touches anything but the journal; a missing,
# empty, or unparseable evidence file folds nothing. 1 only when the journal
# write fails.
fm_vloop_observe() {  # <state> <id> <evidence-file>
  local state=$1 id=$2 ev=$3 journal now content first stored=''
  local run_id status outcome head phase findings_sig steps_sig progress_sig
  local s_run s_phase s_findings_sig s_progress_sig s_fix_rounds s_themes s_last_progress s_status
  local fix_rounds themes last_progress active stop_reason='' max_fix max_theme theme_max tmp
  [ -n "$state" ] && [ -d "$state" ] || return 0
  [ -f "$ev" ] && [ -s "$ev" ] || return 0
  journal=$(fm_vloop_journal_path "$state" "$id")
  now=$(_fm_vloop_now)
  content=$(cat "$ev" 2>/dev/null) || return 0
  [ -f "$journal" ] && [ ! -L "$journal" ] && stored=$(cat "$journal" 2>/dev/null || true)
  s_run=$(_fm_vloop_journal_get "$stored" run)
  s_phase=$(_fm_vloop_journal_get "$stored" phase)
  s_status=$(_fm_vloop_journal_get "$stored" status)
  s_findings_sig=$(_fm_vloop_journal_get "$stored" findings_sig)
  s_progress_sig=$(_fm_vloop_journal_get "$stored" progress_sig)
  s_fix_rounds=$(_fm_vloop_journal_get "$stored" fix_rounds)
  s_themes=$(_fm_vloop_journal_get "$stored" themes)
  s_last_progress=$(_fm_vloop_journal_get "$stored" last_progress)
  case "$s_fix_rounds" in ''|*[!0-9]*) s_fix_rounds=0 ;; esac
  case "$s_last_progress" in ''|*[!0-9]*) s_last_progress=$now ;; esac

  first=${content%%$'\n'*}
  case "$first" in
    coarse:*)
      # Coarse evidence has no run id, head, or step detail: it refreshes
      # freshness, and a coarse status change counts as evidence advance, but
      # counters and run identity stay untouched.
      status=$(fm_nm_trim "${first#coarse:}")
      last_progress=$s_last_progress
      [ "$status" = "$s_status" ] || last_progress=$now
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
        printf 'phase=%s\n' "$s_phase"
        printf 'findings_sig=%s\n' "$s_findings_sig"
        printf 'progress_sig=%s\n' "$s_progress_sig"
        printf 'fix_rounds=%s\n' "$s_fix_rounds"
        printf 'themes=%s\n' "$s_themes"
        printf 'last_observed=%s\n' "$now"
        printf 'last_progress=%s\n' "$last_progress"
        printf 'active=%s\n' "$active"
        printf 'stop_reason=%s\n' "$(_fm_vloop_journal_get "$stored" stop_reason)"
      } > "$tmp" || { rm -f "$tmp"; return 1; }
      mv -f "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
      return 0
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

  fix_rounds=$s_fix_rounds
  themes=$s_themes
  last_progress=$s_last_progress
  if [ "$run_id" != "$s_run" ]; then
    # A new run id is the supervised recovery handoff: the loop being bounded
    # is per run, so a replacement run on the same branch and copy starts with
    # a clean slate.
    fix_rounds=0
    themes=''
    s_phase=''
    s_findings_sig=''
    last_progress=$now
  fi

  progress_sig=$(printf '%s|%s|%s|%s|%s|%s|%s' \
    "$run_id" "$head" "$status" "$outcome" "$phase" "$findings_sig" "$steps_sig" | _fm_vloop_hash)
  [ "$progress_sig" = "$s_progress_sig" ] || last_progress=$now

  if [ "$phase" = fixing ] && [ "$s_phase" != fixing ]; then
    fix_rounds=$((fix_rounds + 1))
  fi
  if [ -n "$findings_sig" ] && [ "$findings_sig" != "$s_findings_sig" ]; then
    themes=$(_fm_vloop_themes_bump "$themes" "$findings_sig")
  fi

  if [ "$phase" = terminal ]; then active=0; else active=1; fi

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
    printf 'last_observed=%s\n' "$now"
    printf 'last_progress=%s\n' "$last_progress"
    printf 'active=%s\n' "$active"
    printf 'stop_reason=%s\n' "$stop_reason"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
  return 0
}

# The continue/stop verdict, one line: "continue", or "stop <reason>". A pure
# read of the journal plus the clock - no evidence call, no write. No journal,
# or a journal whose last evidence was terminal, is "continue": with no active
# loop recorded there is nothing to stop.
fm_vloop_verdict() {  # <state> <id>
  local state=$1 id=$2 journal stored now active stop_reason last_observed last_progress phase age
  local max_age stall
  journal=$(fm_vloop_journal_path "$state" "$id")
  [ -f "$journal" ] && [ ! -L "$journal" ] || { printf 'continue'; return 0; }
  stored=$(cat "$journal" 2>/dev/null) || { printf 'continue'; return 0; }
  active=$(_fm_vloop_journal_get "$stored" active)
  [ "$active" = 1 ] || { printf 'continue'; return 0; }
  now=$(_fm_vloop_now)
  stop_reason=$(_fm_vloop_journal_get "$stored" stop_reason)
  if [ -n "$stop_reason" ]; then
    printf 'stop %s' "$stop_reason"
    return 0
  fi
  last_observed=$(_fm_vloop_journal_get "$stored" last_observed)
  case "$last_observed" in ''|*[!0-9]*) last_observed=$now ;; esac
  max_age=$(_fm_vloop_bound "${FM_VLOOP_EVIDENCE_MAX_AGE_SECS:-}" "$FM_VLOOP_EVIDENCE_MAX_AGE_SECS_DEFAULT")
  age=$((now - last_observed))
  if [ "$age" -gt "$max_age" ]; then
    printf 'stop pipeline evidence stale: an active run was last readable %ss ago (bound %ss); current run state is unknown' "$age" "$max_age"
    return 0
  fi
  phase=$(_fm_vloop_journal_get "$stored" phase)
  case "$phase" in
    running|fixing)
      last_progress=$(_fm_vloop_journal_get "$stored" last_progress)
      case "$last_progress" in ''|*[!0-9]*) last_progress=$now ;; esac
      stall=$(_fm_vloop_bound "${FM_VLOOP_STALL_SECS:-}" "$FM_VLOOP_STALL_SECS_DEFAULT")
      age=$((now - last_progress))
      if [ "$age" -gt "$stall" ]; then
        printf 'stop no evidence advance for %ss while the run claims %s (bound %ss)' "$age" "$phase" "$stall"
        return 0
      fi
      ;;
  esac
  printf 'continue'
}

# The current stop reason alone (empty on continue), for wake decoration.
fm_vloop_reason() {  # <state> <id>
  local verdict
  verdict=$(fm_vloop_verdict "$1" "$2")
  case "$verdict" in
    stop\ *) printf '%s' "${verdict#stop }" ;;
  esac
}
