#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Top-level fields:
#   schema: stable schema id.
#   generated: UTC observation time for this fresh command execution.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#     Structured rows preserve captain-hold metadata such as hold_kind,
#     hold_reason, and hold_until when tasks-axi emits it. They also carry
#     normalized current_role, requires_child_metadata, blocked_by_ids,
#     unresolved_blocker_ids, captain_actionable, and deferred_marker fields.
#     Repeated blocker tokens remain ordered; a blocker resolves only when its
#     structured record is Done, and missing ids stay open.
#     captain_actionable means "waiting on the captain now": queued, held for
#     the captain, unblocked, and due (no hold_until, or hold_until at or
#     before the observation date, matching tasks-axi's own date-gate rule).
#     There is no separate decision type: any captain-held task is the same
#     primitive, whatever kind its row carries.
#     deferred_marker is a presentation hint only: the row's hold reason or
#     body carries an explicit SUPERSEDED / NOT REQUIRED / DEFERRED marker.
#     It never changes captain_actionable; renderers may use it to keep
#     prose-deferred rows out of default views.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     harness, model, and effort are the dispatch record for that worker as
#     spawned; model and effort are null when the spawn recorded none.
#     current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   main_inventory: {valid,reason,orphan_in_flight[],unstructured_current_count} -
#     main-home current-inventory checks shared with secondmate_home_summary_json
#     (orphan structured in-flight ids with no state/<id>.meta, and unstructured
#     current backlog rows). Does not invent live tasks; meta remains truth for
#     workers. Bearings maps failures into omitted[] disclosure (and a Charted
#     Next gate line) rather than silent empty Underway.
#   secondmate_current: {records[],total,shown,truncated} - bounded current summaries
#     for registered secondmates, selected from validated structured state inside
#     each home with explicit provenance, freshness, endpoint evidence, and unknown
#     failure reasons. Parent status and bounded terminal evidence are historical,
#     untrusted supplements only and never override readable structured-home facts.
#     Each structured-home record carries active_children, decisions_open, holds,
#     queued, landed, endpoints, counts, and omitted. Every successfully sampled
#     home also carries reconcile_inventory independently of projection trust.
#     Actionable captain holds
#     appear in decisions_open; blocked captain holds remain queued with metadata.
#   secondmate_landed: {records[],truncated[],unreadable[],partial[]} - the
#     compatibility landed-work roll-up derived from secondmate_current. Readable
#     structured homes are partial, not unreadable, when an unavailable child state
#     or a backlog-vs-metadata inventory mismatch makes their summary incomplete;
#     they retain independently trustworthy structured surfaces. An inventory
#     mismatch also keeps the home's own current classification, which only an
#     unavailable child state or an untrustworthy backlog collapses to unknown.
#   secondmate_guidance: return-channel action note for renderers and bearings.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
SNAPSHOT_NOW=${FM_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ -n "${FM_SNAPSHOT_NOW_EPOCH:-}" ]; then
  SNAPSHOT_EPOCH=$FM_SNAPSHOT_NOW_EPOCH
else
  SNAPSHOT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date -u -d "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date +%s)
fi
case "$SNAPSHOT_EPOCH" in ''|*[!0-9]*) SNAPSHOT_EPOCH=$(date +%s) ;; esac
# The observation date gates captain-hold deferral: a `hold-until` date still in
# the future keeps a captain hold out of captain_actionable until it is due
# (tasks-axi's own contract: the hold is inactive on and after that date).
SNAPSHOT_TODAY=${SNAPSHOT_NOW%%T*}
case "$SNAPSHOT_TODAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) SNAPSHOT_TODAY=$(date -u +%Y-%m-%d) ;;
esac

# Cross-home bounds are explicit so one broken or unexpectedly large home cannot
# hang or explode the parent snapshot.
FM_SNAPSHOT_SECONDMATES=${FM_SNAPSHOT_SECONDMATES:-20}
FM_SNAPSHOT_SECONDMATE_TIMEOUT=${FM_SNAPSHOT_SECONDMATE_TIMEOUT:-8}
FM_SNAPSHOT_CREW_STATE_TIMEOUT=${FM_SNAPSHOT_CREW_STATE_TIMEOUT:-10}
FM_SNAPSHOT_SECONDMATE_MAX_BYTES=${FM_SNAPSHOT_SECONDMATE_MAX_BYTES:-262144}
FM_SNAPSHOT_SECONDMATE_CHILDREN=${FM_SNAPSHOT_SECONDMATE_CHILDREN:-20}
FM_SNAPSHOT_SECONDMATE_QUEUED=${FM_SNAPSHOT_SECONDMATE_QUEUED:-20}
FM_SNAPSHOT_SECONDMATE_DECISIONS=${FM_SNAPSHOT_SECONDMATE_DECISIONS:-20}
FM_SNAPSHOT_TERMINAL_LINES=${FM_SNAPSHOT_TERMINAL_LINES:-8}
FM_SNAPSHOT_TERMINAL_BYTES=${FM_SNAPSHOT_TERMINAL_BYTES:-4096}
FM_SNAPSHOT_TERMINAL_TIMEOUT=${FM_SNAPSHOT_TERMINAL_TIMEOUT:-2}
FM_SNAPSHOT_HERDR_TIMEOUT=${FM_SNAPSHOT_HERDR_TIMEOUT:-2}
FM_SNAPSHOT_PARENT_ACTIVITY_LINES=${FM_SNAPSHOT_PARENT_ACTIVITY_LINES:-256}
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=${FM_SNAPSHOT_PARENT_ACTIVITY_BYTES:-65536}
FM_SNAPSHOT_PARENT_ACTIVITIES=${FM_SNAPSHOT_PARENT_ACTIVITIES:-20}
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=${FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT:-2}
FM_SNAPSHOT_REGISTRY_LINES=${FM_SNAPSHOT_REGISTRY_LINES:-256}
FM_SNAPSHOT_REGISTRY_BYTES=${FM_SNAPSHOT_REGISTRY_BYTES:-65536}
FM_SNAPSHOT_REGISTRY_RECORDS=${FM_SNAPSHOT_REGISTRY_RECORDS:-40}
FM_SNAPSHOT_REGISTRY_TIMEOUT=${FM_SNAPSHOT_REGISTRY_TIMEOUT:-2}
FM_SNAPSHOT_BACKLOG_BYTES=${FM_SNAPSHOT_BACKLOG_BYTES:-262144}
FM_SNAPSHOT_META_BYTES=${FM_SNAPSHOT_META_BYTES:-65536}
FM_SNAPSHOT_STATUS_BYTES=${FM_SNAPSHOT_STATUS_BYTES:-262144}
FM_SNAPSHOT_REPORTS=${FM_SNAPSHOT_REPORTS:-256}
FM_DASHBOARD_STAMP_DEPTH=${FM_DASHBOARD_STAMP_DEPTH:-2}
FM_DASHBOARD_STAMP_MAX_ENTRIES=${FM_DASHBOARD_STAMP_MAX_ENTRIES:-512}
validate_positive_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      printf 'fm-fleet-snapshot: %s must be a positive integer\n' "$1" >&2
      exit 2
      ;;
  esac
}
case "$FM_SNAPSHOT_SECONDMATES" in
  ''|*[!0-9]*)
    echo "fm-fleet-snapshot: FM_SNAPSHOT_SECONDMATES must be a non-negative integer" >&2
    exit 2
    ;;
esac
validate_positive_bound FM_SNAPSHOT_SECONDMATE_TIMEOUT "$FM_SNAPSHOT_SECONDMATE_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_CREW_STATE_TIMEOUT "$FM_SNAPSHOT_CREW_STATE_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_MAX_BYTES "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_CHILDREN "$FM_SNAPSHOT_SECONDMATE_CHILDREN"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_QUEUED "$FM_SNAPSHOT_SECONDMATE_QUEUED"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_DECISIONS "$FM_SNAPSHOT_SECONDMATE_DECISIONS"
validate_positive_bound FM_SNAPSHOT_TERMINAL_LINES "$FM_SNAPSHOT_TERMINAL_LINES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_BYTES "$FM_SNAPSHOT_TERMINAL_BYTES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_TIMEOUT "$FM_SNAPSHOT_TERMINAL_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_HERDR_TIMEOUT "$FM_SNAPSHOT_HERDR_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_LINES "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_BYTES "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITIES "$FM_SNAPSHOT_PARENT_ACTIVITIES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_REGISTRY_LINES "$FM_SNAPSHOT_REGISTRY_LINES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_BYTES "$FM_SNAPSHOT_REGISTRY_BYTES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_RECORDS "$FM_SNAPSHOT_REGISTRY_RECORDS"
validate_positive_bound FM_SNAPSHOT_REGISTRY_TIMEOUT "$FM_SNAPSHOT_REGISTRY_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_BACKLOG_BYTES "$FM_SNAPSHOT_BACKLOG_BYTES"
validate_positive_bound FM_SNAPSHOT_META_BYTES "$FM_SNAPSHOT_META_BYTES"
validate_positive_bound FM_SNAPSHOT_STATUS_BYTES "$FM_SNAPSHOT_STATUS_BYTES"
validate_positive_bound FM_SNAPSHOT_REPORTS "$FM_SNAPSHOT_REPORTS"
validate_positive_bound FM_DASHBOARD_STAMP_DEPTH "$FM_DASHBOARD_STAMP_DEPTH"
validate_positive_bound FM_DASHBOARD_STAMP_MAX_ENTRIES "$FM_DASHBOARD_STAMP_MAX_ENTRIES"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"  # validate_secondmate_home: shared seeded-home boundary checks
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json
       fm-fleet-snapshot.sh --local-only --json
       fm-fleet-snapshot.sh --local-only --stamp
       fm-fleet-snapshot.sh --secondmate-home-summary

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.

--secondmate-home-summary emits the bounded structured summary used after a
validated registered-home handoff. It is local-only, skips nested secondmate
aggregation, includes generated_epoch for freshness arithmetic, and marks
inventory contradictions or unavailable child state invalid.
Its invalidity object names the normalized failure kind and affected ids.
Actionable tasks-axi captain holds appear as decisions_open and stay visible in
queued with hold_reason, hold_kind, hold_until, deferred_marker, and plural
blocker fields for downstream projections. A captain hold is actionable only
when every blocker is Done and any hold-until date has arrived.
Cross-home reads use FM_SNAPSHOT_SECONDMATES (default 20, 0 lifts the count
bound), FM_SNAPSHOT_SECONDMATE_TIMEOUT, and FM_SNAPSHOT_SECONDMATE_MAX_BYTES.
Each per-task current-state read is bounded by FM_SNAPSHOT_CREW_STATE_TIMEOUT
(default 10 seconds), so one unreachable remote secondmate host cannot extend
the snapshot without limit; a read that hits the bound reports state unknown.
Terminal contradiction evidence uses
FM_SNAPSHOT_TERMINAL_LINES, FM_SNAPSHOT_TERMINAL_BYTES, and
FM_SNAPSHOT_TERMINAL_TIMEOUT and never becomes canonical current state.
Parent activity evidence uses FM_SNAPSHOT_PARENT_ACTIVITY_LINES,
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, FM_SNAPSHOT_PARENT_ACTIVITIES, and
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT, with truncation disclosed in the result.
The registered secondmate table uses FM_SNAPSHOT_REGISTRY_LINES,
FM_SNAPSHOT_REGISTRY_BYTES, FM_SNAPSHOT_REGISTRY_RECORDS, and
FM_SNAPSHOT_REGISTRY_TIMEOUT, with unavailability and truncation disclosed.
Herdr-backed local endpoint reads use FM_SNAPSHOT_HERDR_TIMEOUT.
EOF
}

OUTPUT_MODE=json
LOCAL_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) ;;
    --stamp) OUTPUT_MODE=stamp; LOCAL_ONLY=1 ;;
    --local-only) LOCAL_ONLY=1 ;;
    --secondmate-home-summary) OUTPUT_MODE=secondmate-home-summary; LOCAL_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

SNAPSHOT_HOME_REAL=$(cd "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")
SNAPSHOT_FILE_REASON=
SNAPSHOT_REAL=
snapshot_local_path_safe() {  # <path>
  local path=$1 dir base real
  SNAPSHOT_FILE_REASON=
  SNAPSHOT_REAL=
  [ -n "$path" ] || {
    SNAPSHOT_FILE_REASON='not present'
    return 1
  }
  if [ -L "$path" ]; then
    SNAPSHOT_FILE_REASON='refused: the path is a symlink'
    return 1
  fi
  if [ ! -e "$path" ]; then
    SNAPSHOT_FILE_REASON='not present'
    return 1
  fi
  dir=${path%/*}
  [ "$dir" = "$path" ] && dir=.
  base=${path##*/}
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    SNAPSHOT_FILE_REASON='refused: the directory could not be resolved'
    return 1
  }
  real="$real/$base"
  case "$real" in
    "$SNAPSHOT_HOME_REAL"/*) SNAPSHOT_REAL=$real ;;
    *) SNAPSHOT_FILE_REASON='refused: resolves outside this home'; return 1 ;;
  esac
  return 0
}

snapshot_local_file_safe() {  # <path>
  local info
  info=$(snapshot_record_read "$1" info 1) || {
    SNAPSHOT_FILE_REASON=$(printf '%s' "$info" | tail -1)
    [ -n "$SNAPSHOT_FILE_REASON" ] || SNAPSHOT_FILE_REASON='could not read the record'
    return 1
  }
  # shellcheck disable=SC2034 # Set for callers that read it after the resolve.
  SNAPSHOT_REAL=$1
  return 0
}

snapshot_local_root_safe() {  # <path>
  local path=$1 anchor parent resolved
  SNAPSHOT_FILE_REASON=
  [ -L "$path" ] && {
    SNAPSHOT_FILE_REASON='refused: the root is a symlink'
    return 1
  }
  if [ -e "$path" ]; then
    [ -d "$path" ] || {
      SNAPSHOT_FILE_REASON='refused: the root is not a directory'
      return 1
    }
    anchor=$path
  else
    anchor=$path
    while [ ! -e "$anchor" ] && [ ! -L "$anchor" ]; do
      case "$anchor" in
        ''|/) SNAPSHOT_FILE_REASON='refused: the root could not be resolved'; return 1 ;;
      esac
      parent=${anchor%/*}
      [ -n "$parent" ] || parent=/
      anchor=$parent
    done
  fi
  [ ! -L "$anchor" ] || {
    SNAPSHOT_FILE_REASON='refused: an ancestor of the root is a symlink'
    return 1
  }
  [ -d "$anchor" ] || {
    SNAPSHOT_FILE_REASON='refused: the containing path is not a directory'
    return 1
  }
  resolved=$(cd "$anchor" 2>/dev/null && pwd -P) || {
    SNAPSHOT_FILE_REASON='refused: the root could not be resolved'
    return 1
  }
  case "$resolved" in
    "$SNAPSHOT_HOME_REAL"|"$SNAPSHOT_HOME_REAL"/*) return 0 ;;
    *) SNAPSHOT_FILE_REASON='refused: the root resolves outside this home'; return 1 ;;
  esac
}

path_present_json() {  # <path>
  local present=0
  if [ "$LOCAL_ONLY" -eq 1 ]; then
    snapshot_local_path_safe "$1" && present=1
  else
    [ -e "$1" ] && present=1
  fi
  jq -n --arg path "$1" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

regular_file_present_json() {  # <path>
  local present=0 available=true reason=
  if [ "$LOCAL_ONLY" -eq 1 ]; then
    if snapshot_local_file_safe "$1"; then
      present=1
    else
      available=false
      reason=$SNAPSHOT_FILE_REASON
    fi
  else
    if [ -f "$1" ] && [ -r "$1" ]; then
      present=1
    else
      available=false
      reason='not present'
    fi
  fi
  jq -n --arg path "$1" --arg reason "$reason" \
    --argjson present "$(bool_json "$present")" \
    --argjson available "$available" \
    '{path:$path,present:$present,available:$available,
      reason:(if $reason == "" then null else $reason end)}'
}

snapshot_record_read() {  # <path> <mode> <limit> [<root> ...]
  local path=$1 mode=$2 limit=$3
  shift 3
  [ "$#" -gt 0 ] || set -- "$STATE" "$DATA" "$CONFIG" "$PROJECTS"
  if [ -n "${SNAPSHOT_REPORT_EXCLUDE_PATHS:-}" ]; then
    FM_DASHBOARD_REPORT_EXCLUDE_PATHS="$SNAPSHOT_REPORT_EXCLUDE_PATHS" \
      python3 "$SCRIPT_DIR/fm-dashboard-read.py" "$path" "$@" \
      "$mode" "$limit" - /dev/null 2>&1
  else
    python3 "$SCRIPT_DIR/fm-dashboard-read.py" "$path" "$@" \
      "$mode" "$limit" - /dev/null 2>&1
  fi
}

snapshot_record_text() {  # <path> [<limit>] [<root> ...]
  local path=$1 limit=${2:-$FM_SNAPSHOT_BACKLOG_BYTES}
  if [ "$#" -ge 2 ]; then shift 2; else shift; fi
  snapshot_record_read "$path" text "$limit" "$@"
}

snapshot_record_lines() {  # <path> <limit> [<root> ...]
  snapshot_record_read "$1" lines "$2" "${@:3}"
}

snapshot_record_bytes() {  # <path> <limit> [<root> ...]
  snapshot_record_read "$1" bytes "$2" "${@:3}"
}

snapshot_record_tail_bytes() {  # <path> <limit> [<root> ...]
  snapshot_record_read "$1" tail_bytes "$2" "${@:3}"
}

snapshot_record_info() {  # <path> [<root> ...]
  snapshot_record_read "$1" info 1 "${@:2}"
}

if [ "$LOCAL_ONLY" -eq 1 ]; then
  for snapshot_root in "$STATE" "$DATA" "$CONFIG" "$PROJECTS"; do
    snapshot_local_root_safe "$snapshot_root" || {
      echo "fm-fleet-snapshot: unsafe local-only root $snapshot_root: $SNAPSHOT_FILE_REASON" >&2
      exit 1
    }
  done
fi

meta_value() {  # <meta-file> <key>
  local content
  content=$(snapshot_record_text "$1" "$FM_SNAPSHOT_META_BYTES" "$STATE" "$DATA" "$CONFIG" "$PROJECTS") || return 1
  meta_value_text "$content" "$2"
}

meta_value_text() {  # <metadata-text> <key>
  printf '%s\n' "$1" | awk -v key="$2" '
    index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  '
}

last_nonempty_line() {  # <file>
  local content
  content=$(snapshot_record_lines "$1" "$FM_SNAPSHOT_STATUS_BYTES") || return 1
  printf '%s\n' "$content" | awk 'NF { line=$0 } END { if (line != "") print line }'
}

# A crew-state read is bounded like every other cross-home read here. For a
# remote secondmate fm-crew-state.sh reaches its host over ssh, and ssh's own
# dead-peer detection deliberately never kills a slow-but-alive remote command,
# so without this bound one unreachable or slow host extends the whole snapshot
# without limit - and this snapshot is also the producer behind the repeatedly
# published home ledger. A read that hits the bound is indistinguishable from
# the already-handled unreadable case: empty output folds to state unknown.
crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep probe_error probe_status=0 freshness
  raw=$(
    fm_run_timed "$FM_SNAPSHOT_HERDR_TIMEOUT" env \
      FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      FM_BACKEND_NO_SERVER_START=1 \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>&1
  )
  probe_status=$?
  probe_error=$(printf '%s\n' "$raw" | tail -1)
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  freshness=unknown
  if [ "$probe_status" -ne 0 ]; then
    source=probe-failed
    detail=${probe_error:-"Herdr probe failed (exit $probe_status)"}
    freshness=degraded
  elif [ -z "$raw" ]; then
    source=probe-unknown
    detail='Herdr probe returned no current state'
  fi
  if [ "$probe_status" -eq 0 ]; then
    case "$raw" in
      state:\ *"$sep"source:\ *)
        rest=${raw#state: }
        state=${rest%%"$sep"source: *}
        rest=${rest#*"$sep"source: }
        case "$rest" in
          *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
          *) source=$rest ;;
        esac
        freshness=fresh
        ;;
    esac
  fi
  if [ "$probe_status" -eq 0 ] && [ "$state" = unknown ] && [ "$source" = none ]; then
    case "$detail" in
      backend\ target\ gone:*|no\ backend\ target\ recorded)
        source=probe-failed
        freshness=degraded
        ;;
    esac
  fi
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" \
    --arg detail "$detail" --arg freshness "$freshness" \
    '{state:$state,source:$source,detail:$detail,raw:$raw,freshness:$freshness}'
}

snapshot_herdr_target_state() {  # <target> <expected-label>
  fm_run_timed "$FM_SNAPSHOT_HERDR_TIMEOUT" env \
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    bash -c "
      . \"\$1\"
      fm_backend_source herdr || exit 1
      fm_backend_herdr_target_shape_valid \"\$2\" || exit 1
      out=\$(fm_backend_herdr_cli \"\$FM_BACKEND_HERDR_SESSION\" pane get \"\$FM_BACKEND_HERDR_PANE\" 2>&1)
      status=\$?
      if [ \"\$status\" -ne 0 ]; then
        printf '%s\\n' \"\$out\" >&2
        exit \"\$status\"
      fi
      code=\$(printf '%s' \"\$out\" | jq -r '.error.code // empty' 2>/dev/null)
      if [ -n \"\$code\" ]; then
        # pane_not_found is an ANSWER: that pane is gone. Every other error code
        # means the probe itself failed - an unavailable server, a refused
        # session - and collapsing it to exit-zero 'unknown' would present a
        # failed probe as a successful one that happened to learn nothing.
        if [ \"\$code\" = pane_not_found ]; then
          printf 'dead'
          exit 0
        fi
        printf 'Herdr pane probe failed: %s\\n' \"\$code\" >&2
        exit 3
      fi
      pid=\$(printf '%s' \"\$out\" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
      [ \"\$pid\" = \"\$FM_BACKEND_HERDR_PANE\" ] && printf 'present' || printf 'unknown'
    " snapshot-herdr-target "$SCRIPT_DIR/fm-backend.sh" "$1" "$2"
}

snapshot_herdr_agent_alive() {  # <target>
  fm_run_timed "$FM_SNAPSHOT_HERDR_TIMEOUT" env \
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    bash -c "
      . \"\$1\"
      fm_backend_source herdr || exit 1
      fm_backend_herdr_target_shape_valid \"\$2\" || exit 1
      pane_out=\$(fm_backend_herdr_cli \"\$FM_BACKEND_HERDR_SESSION\" pane get \"\$FM_BACKEND_HERDR_PANE\" 2>&1)
      status=\$?
      if [ \"\$status\" -ne 0 ]; then
        printf '%s\\n' \"\$pane_out\" >&2
        exit \"\$status\"
      fi
      pane_code=\$(printf '%s' \"\$pane_out\" | jq -r '.error.code // empty' 2>/dev/null)
      if [ -n \"\$pane_code\" ]; then
        if [ \"\$pane_code\" = pane_not_found ]; then
          printf 'dead'
          exit 0
        fi
        printf 'Herdr pane probe failed: %s\\n' \"\$pane_code\" >&2
        exit 3
      fi
      pane_id=\$(printf '%s' \"\$pane_out\" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
      [ \"\$pane_id\" = \"\$FM_BACKEND_HERDR_PANE\" ] || { printf 'unknown'; exit 0; }
      agent_out=\$(fm_backend_herdr_cli \"\$FM_BACKEND_HERDR_SESSION\" agent get \"\$FM_BACKEND_HERDR_PANE\" 2>&1)
      status=\$?
      if [ \"\$status\" -ne 0 ]; then
        printf '%s\\n' \"\$agent_out\" >&2
        exit \"\$status\"
      fi
      agent_code=\$(printf '%s' \"\$agent_out\" | jq -r '.error.code // empty' 2>/dev/null)
      if [ -n \"\$agent_code\" ]; then
        if [ \"\$agent_code\" = agent_not_found ]; then
          printf 'dead'
          exit 0
        fi
        printf 'Herdr agent probe failed: %s\\n' \"\$agent_code\" >&2
        exit 3
      fi
      agent_status=\$(printf '%s' \"\$agent_out\" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
      case \"\$agent_status\" in
        working|idle|done|blocked) printf 'alive' ;;
        *) printf 'unknown' ;;
      esac
    " snapshot-herdr-agent "$SCRIPT_DIR/fm-backend.sh" "$1"
}

status_event_json() {  # <status-log>
  local log=$1 present=0 available=true reason='' raw='' verb='' note='' read_error
  if [ "$LOCAL_ONLY" -eq 1 ] && { [ -e "$log" ] || [ -L "$log" ]; } \
    && ! snapshot_local_file_safe "$log"; then
    available=false
    reason=$SNAPSHOT_FILE_REASON
  elif [ -f "$log" ]; then
    present=1
    if ! raw=$(last_nonempty_line "$log"); then
      read_error=$(printf '%s' "$raw" | tail -1)
      available=false
      reason=${read_error:-'could not read the status log'}
      raw=''
    else
      verb=$(status_line_verb "$raw")
      note=$(status_line_note "$raw")
    fi
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --arg reason "$reason" \
    --argjson present "$(bool_json "$present")" \
    --argjson available "$(bool_json "$available")" \
    '{path:$path,present:$present,available:$available,reason:(if $reason == "" then null else $reason end),kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw}}'
}

first_pr_url_in_file() {  # <file>
  local content
  FIRST_PR_REASON=
  content=$(snapshot_record_text "$1" "$FM_SNAPSHOT_STATUS_BYTES") || {
    FIRST_PR_REASON=$(printf '%s' "$content" | tail -1)
    printf '%s\n' "$FIRST_PR_REASON"
    return 1
  }
  printf '%s\n' "$content" | grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' | head -1
}

backlog_json() {  # [<backlog-path>] - defaults to this home's $BACKLOG
  local backlog=${1:-$BACKLOG}
  if [ ! -e "$backlog" ] && [ ! -L "$backlog" ]; then
    jq -n --arg path "$backlog" '{path:$path,present:false,available:true,reason:"not present",records:[]}'
    return 0
  fi
  local backlog_text
  if ! backlog_text=$(snapshot_record_text "$backlog"); then
    SNAPSHOT_FILE_REASON=$(printf '%s' "$backlog_text" | tail -1)
    jq -n --arg path "$backlog" --arg reason "$SNAPSHOT_FILE_REASON" \
      '{path:$path,present:false,available:false,reason:$reason,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  printf '%s\n' "$backlog_text" | jq -Rn --arg path "$backlog" --arg today "$SNAPSHOT_TODAY" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind|hold-until):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,key:($section + "-" + ($order|tostring)),state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             key:($section + "-" + ($order|tostring)),
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             hold_reason:metadata($rest; "hold"),
             hold_kind:metadata($rest; "hold-kind"),
             hold_until:metadata($rest; "hold-until"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,available:true,reason:null,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,key:(.section + "-" + (.order|tostring)),state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | .records |= (
        reduce .[] as $record ({counts:{},records:[]};
          (if $record.structured then $record.id else $record.raw end) as $identity
          | (($record.state + ":" + $identity) | @base64) as $base
          | (.counts[$base] // 0) as $occurrence
          | .counts[$base] = ($occurrence + 1)
          | .records += [$record + {key:($base + ":" + ($occurrence | tostring))}])
        | .records)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .captain_actionable =
              (.state == "queued" and .hold_kind == "captain"
               and .hold_reason != null and (.unresolved_blocker_ids | length) == 0
               and (.hold_until == null or .hold_until <= $today))
          | .deferred_marker =
              ((((.hold_reason // "") + " " + (.body_excerpt // ""))
                | test("SUPERSEDED|NOT REQUIRED|NOT-REQUIRED|DEFERRED"; "i")))
        else . end)
    | del(.section,.order)
  '
}

task_json_lines() {
  local meta id kind harness mode yolo project worktree home projects spawn_gen backend recorded_backend target status_log report_path
  local remote_host remote_root remote_state remote_rc remote_home_present remote_identity_valid
  local pr pr_source event_json current_json endpoint_exists endpoint_status agent_alive meta_json status_json report_json worktree_json home_json
  local endpoint_rc agent_alive_rc local_identity_valid
  local last_event_raw current_state current_source pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    endpoint_freshness=unknown
    endpoint_reason=''
    endpoint_probe_output=''
    endpoint_probe_status=1
    if ! meta_text=$(snapshot_record_text "$meta" "$FM_SNAPSHOT_META_BYTES" "$STATE" "$DATA" "$CONFIG" "$PROJECTS"); then
      meta_reason=$(printf '%s' "$meta_text" | tail -1)
      [ -n "$meta_reason" ] || meta_reason='could not read task metadata'
      echo "fm-fleet-snapshot: unsafe task metadata unavailable $meta: $meta_reason" >&2
      return 1
    fi
    kind=$(meta_value_text "$meta_text" kind)
    [ -n "$kind" ] || kind=ship
    harness=$(meta_value_text "$meta_text" harness)
    model=$(meta_value_text "$meta_text" model)
    effort=$(meta_value_text "$meta_text" effort)
    mode=$(meta_value_text "$meta_text" mode)
    yolo=$(meta_value_text "$meta_text" yolo)
    project=$(meta_value_text "$meta_text" project)
    worktree=$(meta_value_text "$meta_text" worktree)
    home=$(meta_value_text "$meta_text" home)
    projects=$(meta_value_text "$meta_text" projects)
    spawn_gen=$(meta_value_text "$meta_text" spawn_gen)
    remote_host=$(meta_value_text "$meta_text" remote_host)
    remote_root=$(meta_value_text "$meta_text" remote_root)
    remote_home_present=null
    local_identity_valid=1
    remote_identity_valid=1
    if [ -n "$remote_host" ]; then
      backend=$(fm_backend_meta_recorded_backend "$meta" remote_backend 2>/dev/null || true)
      case "$backend" in
        herdr)
          if ! fm_backend_validate_remote_task_endpoint "$meta" "$id" fm-remote >/dev/null 2>&1; then
            remote_identity_valid=2
            backend="invalid:$backend"
          fi
          ;;
        absent|tmux|zellij|orca|cmux)
          remote_identity_valid=0
          backend="legacy:${backend:-unrecorded}"
          ;;
        ambiguous|'')
          remote_identity_valid=2
          backend="ambiguous:${backend:-unrecorded}"
          ;;
        *)
          remote_identity_valid=2
          backend="invalid:$backend"
          ;;
      esac
      target=$(meta_value "$meta" remote_target)
    else
      # A legacy (absent or non-herdr) backend identity is displayed as recorded
      # with a marker, never dispatched on (hard rule 6); the snapshot is a view.
      recorded_backend=$(fm_backend_meta_recorded_backend "$meta" 2>/dev/null || true)
      if [ "$recorded_backend" = herdr ] && fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
        backend=$FM_BACKEND_VALIDATED_BACKEND
        target=$FM_BACKEND_VALIDATED_TARGET
      else
        if [ "$recorded_backend" = herdr ]; then
          local_identity_valid=2
          backend="invalid:$recorded_backend"
        elif [ "$recorded_backend" = ambiguous ]; then
          local_identity_valid=2
          backend="ambiguous:$recorded_backend"
        else
          local_identity_valid=0
          backend="legacy:${recorded_backend:-absent}"
        fi
        target=
      fi
    fi
    status_log="$STATE/$id.status"
    report_path="$DATA/$id/report.md"
    pr=$(meta_value_text "$meta_text" pr)
    pr_source=meta
    local pr_available=true pr_reason=''
    if [ -z "$pr" ]; then
      if pr_from_status=$(first_pr_url_in_file "$status_log"); then
        pr=$pr_from_status
        pr_source=status_event
      else
        pr_reason=$(printf '%s' "$pr_from_status" | tail -1)
        [ -n "$pr_reason" ] || pr_reason='could not read the status log'
        if [ "$pr_reason" = 'not present' ]; then
          pr_reason=''
          pr_source=absent
        else
          pr_available=false
          pr_source=status_event
        fi
      fi
    fi
    if [ -z "$pr" ] && [ "$pr_available" = true ]; then
      pr_source=absent
    fi

    if [ "$remote_identity_valid" -eq 0 ] || [ "$local_identity_valid" -eq 0 ]; then
      if [ -n "$remote_host" ]; then
        recorded_backend=$(meta_value "$meta" remote_backend)
      else
        recorded_backend=$(meta_value "$meta" backend)
      fi
      current_json=$(jq -n --arg detail "legacy-record: backend=${recorded_backend:-absent} is not herdr; record is read-only" '{state:"unknown",source:"legacy-backend",detail:$detail,raw:""}')
    elif [ "$remote_identity_valid" -eq 2 ] || [ "$local_identity_valid" -eq 2 ]; then
      current_json=$(jq -n --arg detail "remote backend identity is ambiguous or invalid; repair or explicitly migrate the record through docs/configuration.md \"Legacy task records\"" '{state:"unknown",source:"backend-identity",detail:$detail,raw:""}')
    else
      current_json=$(crew_state_json "$id")
    fi
    event_json=$(status_event_json "$status_log")
    last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
    current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
    current_source=$(printf '%s' "$current_json" | jq -r '.source // ""')
    current_freshness=$(printf '%s' "$current_json" | jq -r '.freshness // "unknown"')

    # Durable keyed open-decision set: fold the WHOLE status stream
    # (fm-classify-lib.sh's status_open_decisions) so a later unrelated event can
    # never mask a still-open captain decision. The set is derived purely from the
    # keyed fold - never from report bodies or decision-like prose - and then
    # reconciled against the crew LIFECYCLE, which only clears a stale decision the
    # crew has provably moved past. Two lifecycle signals clear it, neither of which
    # reads any report content:
    #   - a live activity read (run-step or busy pane) that is working/done, so a
    #     crew that resumed past a gate is not still reported as parked; and
    #   - a TERMINAL done/failed state on a single-owner task (scout or ship), whose
    #     deliverable is its report or PR, so a COMPLETED scout surfaces only as a
    #     report POINTER, never as a reopened pending decision.
    # Secondmates are excluded from lifecycle clearing: they are persistent and
    # multiplex many concerns onto one stream, so activity on one concern must
    # never clear another concern's keyed decision. A parked/blocked state, or a
    # non-authoritative status-log/none read on a still-live task, keeps the fold's
    # open decision surfacing.
    if status_text=$(snapshot_record_text "$status_log" "$FM_SNAPSHOT_STATUS_BYTES"); then
      if ! open_decisions_tsv=$(printf '%s' "$status_text" | status_open_decisions -); then
        status_reason='could not fold the status log into open decisions'
        open_decisions_available=false
        open_decisions_reason=$status_reason
        open_decisions_tsv=''
      fi
    else
      status_reason=$(printf '%s' "$status_text" | tail -1)
      open_decisions_available=false
      open_decisions_reason=${status_reason:-'could not read the status log'}
      open_decisions_tsv=''
    fi
    if [ "$kind" != secondmate ] && \
       { { { [ "$current_source" = run-step ] || [ "$current_source" = pane ]; } \
           && [ "$current_state" != parked ] && [ "$current_state" != blocked ]; } \
         || { [ "$current_state" = "done" ] || [ "$current_state" = "failed" ]; }; }; then
      open_decisions_tsv=""
    fi
    open_decisions_json=$(printf '%s' "$open_decisions_tsv" | jq -R -s '
      [ splits("\n") | select(length > 0)
        | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
        | select(. != null) ]')
    pending_decision=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "needs-decision") then 1 else 0 end')
    blocked_event=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "blocked") then 1 else 0 end')

    endpoint_exists=null
    endpoint_status=unknown
    agent_alive=not_checked
    if [ -n "$remote_host" ] && [ "$remote_identity_valid" -eq 1 ]; then
      if remote_state=$(fm_run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" \
        "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" --typed < /dev/null); then
        remote_rc=0
      else
        remote_rc=$?
      fi
      if [ "$remote_rc" -eq 0 ]; then
        remote_home_present=true
        remote_state=$(printf '%s\n' "$remote_state" | tail -1)
        case "$remote_state" in
          alive) endpoint_exists=true; agent_alive=alive ;;
          dead) endpoint_exists=true; agent_alive=dead ;;
          missing) endpoint_exists=false; agent_alive=dead ;;
          capability-failure)
            endpoint_exists=null
            endpoint_status=capability-failure
            agent_alive=capability-failure
            ;;
          legacy-record|endpoint-refused)
            endpoint_exists=null
            endpoint_status=refused
            agent_alive=not_checked
            ;;
          *) endpoint_exists=null; agent_alive=unknown ;;
        esac
      else
        endpoint_exists=null
        case "$remote_rc" in
          2)
            endpoint_status=capability-failure
            agent_alive=capability-failure
            ;;
          3)
            endpoint_status=refused
            agent_alive=not_checked
            ;;
          *)
            agent_alive=unknown
            ;;
        esac
      fi
    elif [ -n "$remote_host" ]; then
      endpoint_exists=null
      if [ "$remote_identity_valid" -eq 2 ]; then
        endpoint_status=identity-failure
        agent_alive=identity-failure
      else
        agent_alive=unknown
      fi
    elif [ "$local_identity_valid" -eq 1 ]; then
      if [ -n "$target" ]; then
        if fm_backend_target_exists "$backend" "$target" "fm-$id" \
          "${FM_BACKEND_HERDR_EXPECTED_WORKSPACE_ID:-}" \
          "${FM_BACKEND_HERDR_EXPECTED_TAB_ID:-}" \
          "${FM_BACKEND_HERDR_EXPECTED_TERMINAL_ID:-}"; then
          endpoint_exists=true
          endpoint_status=alive
        else
          endpoint_rc=$?
          if [ "$endpoint_rc" -eq 2 ]; then
            endpoint_exists=null
            endpoint_status=capability-failure
          else
            endpoint_exists=false
            endpoint_status=absent
          fi
        fi
      else
        endpoint_reason='no endpoint target recorded'
      fi
      if [ "$kind" = secondmate ] && [ -n "$target" ]; then
        if agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null); then
          :
        else
          agent_alive_rc=$?
          if [ "$agent_alive_rc" -eq 2 ]; then
            agent_alive=capability-failure
            endpoint_status=capability-failure
            endpoint_exists=null
          else
            agent_alive=unknown
          fi
        fi
        if [ "$endpoint_status" = capability-failure ]; then
          agent_alive=capability-failure
        fi
      fi
    else
      endpoint_exists=null
      if [ "$local_identity_valid" -eq 0 ]; then
        endpoint_status=refused
        agent_alive=not_checked
      else
        endpoint_status=identity-failure
        agent_alive=identity-failure
      fi
    fi

    meta_json=$(path_present_json "$meta")
    status_json=$event_json
    report_json=$(regular_file_present_json "$report_path")
    if [ "$(printf '%s' "$report_json" | jq -r '.present // false')" = true ]; then
      report_present=1
    else
      report_present=0
    fi
    if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$home" ] && [ -n "$remote_host" ]; then
      home_json=$(jq -n --arg path "$home" --argjson present "$remote_home_present" '{path:$path,present:$present}')
    elif [ -n "$home" ]; then
      home_json=$(path_present_json "$home")
    else
      home_json=$(jq -n '{path:null,present:false}')
    fi

    jq -n \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg harness "$harness" \
      --arg model "$model" \
      --arg effort "$effort" \
      --arg mode "$mode" \
      --arg yolo "$yolo" \
      --arg project "$project" \
      --arg worktree "$worktree" \
      --arg home "$home" \
      --arg projects "$projects" \
      --arg spawn_gen "$spawn_gen" \
      --arg backend "$backend" \
      --arg target "$target" \
      --arg remote_host "$remote_host" \
      --arg remote_root "$remote_root" \
      --arg remote_reason "$remote_reason" \
      --arg pr "$pr" \
      --arg pr_source "$pr_source" \
      --arg agent_alive "$agent_alive" \
      --arg endpoint_status "$endpoint_status" \
      --arg observed_at "$SNAPSHOT_NOW" \
      --arg last_event_raw "$last_event_raw" \
      --arg current_freshness "$current_freshness" \
      --argjson current_state "$current_json" \
      --argjson meta_path "$meta_json" \
      --argjson status_log "$status_json" \
      --argjson report "$report_json" \
      --argjson worktree_path "$worktree_json" \
      --argjson home_path "$home_json" \
      --argjson endpoint_exists "$endpoint_exists" \
      --argjson remote_unavailable "$remote_unavailable" \
      --argjson open_decisions "$open_decisions_json" \
      --argjson open_decisions_available "$open_decisions_available" \
      --arg open_decisions_reason "$open_decisions_reason" \
      --argjson pending_decision "$(bool_json "$pending_decision")" \
      --argjson blocked_event "$(bool_json "$blocked_event")" \
      --argjson report_present "$(bool_json "$report_present")" \
      '{
        id:$id,
        kind:$kind,
        harness:($harness // ""),
        model:($model | if . == "" then null else . end),
        effort:($effort | if . == "" then null else . end),
        mode:($mode // ""),
        yolo:($yolo // ""),
        project:($project // ""),
        spawn_gen:($spawn_gen | if . == "" then null else . end),
        backend:$backend,
        remote:(if $remote_host == "" then null else {host:$remote_host,root:$remote_root} +
          (if $remote_unavailable then {evidence:"unavailable",reason:$remote_reason} else {} end) end),
        paths:{
          meta:$meta_path,
          status_log:$status_log,
          worktree:$worktree_path,
          home:$home_path,
          report:$report
        },
        secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
        current_state:($current_state + {observed_at:$observed_at,freshness:$current_freshness}),
        endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive,
          status:(if $endpoint_status == "capability-failure" then "capability-failure"
                  elif $endpoint_exists == false then "absent"
                  elif $agent_alive == "alive" or $agent_alive == "dead" then $agent_alive
                  else "unknown" end),
          observed_at:$observed_at,freshness:$endpoint_freshness,
          reason:($endpoint_reason | if . == "" then null else . end)},
        pr:{url:($pr | if . == "" then null else . end),source:$pr_source,
          available:$pr_available,reason:($pr_reason | if . == "" then null else . end)},
        hints:{
          pending_decision:$pending_decision,
          blocked_event:$blocked_event,
          open_decisions:$open_decisions,
          open_decisions_available:$open_decisions_available,
          open_decisions_reason:(if $open_decisions_reason == "" then null else $open_decisions_reason end),
          scout_report_present:$report_present,
          last_event_text:$last_event_raw
        },
        actions:(
          if $kind == "secondmate" then
            {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
             watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
             return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
          else
            {watch:"bin/fm-peek.sh fm-\($id)",
             steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
             return_channel_note:null}
          end)
      }'
  done | jq -s 'sort_by(.id)'
}

# Main-home current-inventory validity: same orphan / unstructured-current checks
# used by secondmate_home_summary_json, without inventing live task rows.
# Meta inventory remains the sole source of live workers; this object only
# discloses backlog↔task inconsistency for renderers (Bearings omitted/gates).
main_inventory_json() {  # <backlog-json> <tasks-json>
  jq -n \
    --argjson backlog "$1" \
    --argjson tasks "$2" '
    ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]?
         | select(.state == "in_flight" and .structured and .requires_child_metadata) ]) as $owned_in_flight
    | ([ $owned_in_flight[]
         | select(.id as $id | [$tasks[].id] | index($id) | not)
         | .id ]) as $orphan_in_flight
    | (($unstructured_current | length) == 0
       and ($orphan_in_flight | length) == 0) as $valid
    | (if ($unstructured_current | length) > 0 then "unstructured current backlog row"
       elif ($orphan_in_flight | length) > 0 then "in-flight backlog item has no child metadata"
       else null end) as $reason
    | {
        valid:$valid,
        reason:$reason,
        orphan_in_flight:$orphan_in_flight,
        unstructured_current_count:($unstructured_current | length)
      }'
}

# Project one home's canonical structured inventory into the bounded shape a
# validated parent read needs.
# This mode never reads parent events or terminal text and never aggregates
# nested secondmates.
secondmate_home_summary_json() {  # <backlog-json> <tasks-json>
  jq -n \
    --arg generated "$SNAPSHOT_NOW" \
    --argjson generated_epoch "$SNAPSHOT_EPOCH" \
    --arg home "$FM_HOME" \
    --argjson child_n "$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
    --argjson queued_n "$FM_SNAPSHOT_SECONDMATE_QUEUED" \
    --argjson decisions_n "$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
    --argjson landed_n "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
    --argjson backlog "$1" \
    --argjson tasks "$2" '
    def trunc($n):
      tostring | gsub("\\s+"; " ")
      | if length > $n then .[:$n] + "…" else . end;
    ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]? | select(.state == "in_flight" and .structured) ]) as $owned_in_flight
    | ([ $backlog.records[]?
         | select(.structured and
             (.state == "queued" or
              (.state == "in_flight" and .current_role == "held"
               and (.id as $id
                    | any($tasks[]; .id == $id and .current_state.state == "working") | not)))) ]) as $queued_all
    | ([ $queued_all[]
         | select(.captain_actionable == true)
         | {id,key:.id,verb:"captain-hold",summary:(.title | trunc(160)),
            reason:(.hold_reason | trunc(160)),
            hold_until:(.hold_until // null),
            deferred_marker:(.deferred_marker // false),source:"backlog"} ]) as $captain_holds_all
    | ([ $backlog.records[]? | select(.state == "done" and .structured and .hold_kind != "captain")
         | {id:(.id | trunc(120)),title:(.title | trunc(120)),
            pr_url:((.pr_url // null) | if . == null then null else trunc(500) end),
            report_path:((.report_path // null) | if . == null then null else trunc(500) end),
            local_note:((.local_note // null) | if . == null then null else trunc(120) end),completion} ]
       | sort_by([(.completion.date // ""), .id]) | reverse) as $landed_all
    | ([ $tasks[] | select(.current_state.state == "unknown") ]) as $unknown_children
    | ([ $owned_in_flight[]
         | select(.requires_child_metadata)
         | select(.id as $id | [$tasks[].id] | index($id) | not) ]) as $orphan_in_flight
    | ([ $tasks[]
         | select(.id as $id | [$owned_in_flight[].id] | index($id) | not)
         | {id,state:.current_state.state} ]) as $unowned_children
    | ([ $owned_in_flight[] as $work
         | $tasks[]
         | select(.id == $work.id and (.current_state.state == "done" or .current_state.state == "failed"))
         | {id,state:.current_state.state} ]) as $terminal_in_flight
    | ([if $backlog.present != true then
          {kind:"missing_backlog",ids:[],reason:"missing structured backlog"}
        else empty end,
        if ($unstructured_current | length) > 0 then
          {kind:"unstructured_current",ids:[],reason:"unstructured current backlog row"}
        else empty end,
        if ($orphan_in_flight | length) > 0 then
          {kind:"orphan_in_flight",ids:($orphan_in_flight | map(.id)),
           reason:("in-flight backlog item has no child metadata: " + ($orphan_in_flight | map(.id) | join(", ")))}
        else empty end,
        if ($unowned_children | length) > 0 then
          {kind:"unowned_current",ids:($unowned_children | map(.id)),
           reason:("live child state has no in-flight backlog item: " +
                   ($unowned_children | map(.id + "=" + .state) | join(", ")))}
        else empty end,
        if ($terminal_in_flight | length) > 0 then
          {kind:"terminal_in_flight",ids:($terminal_in_flight | map(.id)),
           reason:("in-flight backlog item has terminal child state: " +
                   ($terminal_in_flight | map(.id + "=" + .state) | join(", ")))}
        else empty end]) as $strict_invalidities
    | ([ $owned_in_flight[] as $work
         | select($work.current_role != "program")
         | $tasks[]
         | select(.id == $work.id and .current_state.state == "working")
         | {id,kind,state:.current_state.state,source:.current_state.source,
            doing:((.current_state.detail // "") | trunc(120))} ]) as $active_all
    | ($captain_holds_all
       + ([ $tasks[] as $t | ($t.hints.open_decisions // [])[]
            | {id:$t.id,key,verb,summary:(.summary | trunc(160)),reason:null,source:"status"} ])) as $decisions_all
    | ([ $queued_all[]
         | select((.unresolved_blocker_ids | length) > 0 or (.hold_reason != null and .hold_kind != null))
         | {id:(.id | trunc(120)),title:(.title | trunc(90)),
            blocked_by:((.unresolved_blocker_ids | join(",")) | if . == "" then null else trunc(120) end),
            blocked_by_ids:(.blocked_by_ids | map(trunc(120))),
            unresolved_blocker_ids:(.unresolved_blocker_ids | map(trunc(120))),
            reason:((.hold_reason // .blocked_reason // "blocked") | trunc(120)),source:"backlog"} ]
       + [ $owned_in_flight[] as $work
           | $tasks[]
           | select(.id == $work.id and (.current_state.state == "parked" or .current_state.state == "paused" or .current_state.state == "blocked"))
           | select(($work.hold_reason != null and $work.hold_kind != null) | not)
           | {id,title:((.backlog.title // .id) | trunc(90)),blocked_by:null,
              blocked_by_ids:[],unresolved_blocker_ids:[],
              reason:((.current_state.detail // .current_state.state) | trunc(120)),source:"child-state"} ]) as $holds_all
    | ($backlog.present == true
       and ($unstructured_current | length) == 0
       and ($unknown_children | length) == 0
       and ($orphan_in_flight | length) == 0
       and ($unowned_children | length) == 0
       and ($terminal_in_flight | length) == 0) as $valid
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0].reason
       elif ($unknown_children | length) > 0 then
         "child current state unavailable: " + ($unknown_children | map(.id) | join(", "))
       else null end) as $reason
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0] | del(.reason)
       elif ($unknown_children | length) > 0 then {kind:"child_current_unavailable",ids:($unknown_children | map(.id))}
       else {kind:null,ids:[]} end) as $invalidity
    | (if ($valid | not)
          and (($unknown_children | length) > 0
               or (["orphan_in_flight","unowned_current","terminal_in_flight"]
                   | index($invalidity.kind) | not))
       then "unknown"
       elif any($decisions_all[]; .verb == "needs-decision" or .verb == "captain-hold") then "captain_decision"
       elif ($active_all | length) > 0 then "active_child_work"
       elif ($holds_all | length) > 0 then "externally_held"
       else "no_active_work" end) as $state
    | {
        schema:"fm-secondmate-home-summary.v1",
        generated:$generated,
        generated_epoch:$generated_epoch,
        home:$home,
        valid:$valid,
        reason:$reason,
        invalidity:$invalidity,
        state:$state,
        active_children:$active_all[:$child_n],
        decisions_open:$decisions_all[:$decisions_n],
        holds:$holds_all[:$queued_n],
        queued:([$queued_all[] | {id:(.id | trunc(120)),title:(.title | trunc(120)),
          blocked_by:((.blocked_by // null) | if . == null then null else trunc(120) end),
          blocked_by_ids:((.blocked_by_ids // []) | map(trunc(120))),
          unresolved_blocker_ids:((.unresolved_blocker_ids // []) | map(trunc(120))),
          blocked_reason:((.blocked_reason // null) | if . == null then null else trunc(160) end),
          hold_reason:((.hold_reason // null) | if . == null then null else trunc(160) end),
          hold_kind:((.hold_kind // null) | if . == null then null else trunc(40) end),
          hold_until:((.hold_until // null) | if . == null then null else trunc(40) end),
          deferred_marker:(.deferred_marker // false),
          captain_actionable:(.captain_actionable // false),
          repo:((.repo // null) | if . == null then null else trunc(120) end),
          kind:((.kind // null) | if . == null then null else trunc(40) end)}][:$queued_n]),
        landed:(if $landed_n == 0 then $landed_all else $landed_all[:$landed_n] end),
        endpoints:([$tasks[] | {id,state:.current_state.state,source:.current_state.source,
          endpoint:(.endpoint + {target:((.endpoint.target // null) | if . == null then null else trunc(240) end)})}][:$child_n]),
        counts:{
          active_children:($active_all | length),
          decisions_open:($decisions_all | length),
          holds:($holds_all | length),
          queued:($queued_all | length),
          landed:($landed_all | length),
          endpoints:($tasks | length)
        },
        omitted:[
          (if ($active_all | length) > $child_n then {surface:"active_children",count:(($active_all | length) - $child_n)} else empty end),
          (if ($decisions_all | length) > $decisions_n then {surface:"decisions_open",count:(($decisions_all | length) - $decisions_n)} else empty end),
          (if ($queued_all | length) > $queued_n then {surface:"queued",count:(($queued_all | length) - $queued_n)} else empty end),
          (if ($tasks | length) > $child_n then {surface:"endpoints",count:(($tasks | length) - $child_n)} else empty end),
          (if $landed_n > 0 and ($landed_all | length) > $landed_n then {surface:"landed",count:(($landed_all | length) - $landed_n)} else empty end)
        ]
      }'
}

# Current registered-secondmate aggregation.
# The validated home summary is canonical.
# Parent status and bounded terminal capture remain untrusted supplemental evidence
# with explicit provenance, and can only produce a contradiction or unknown fallback.
FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=${FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME:-10}
case "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" in ''|*[!0-9]*) FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=10 ;; esac

# GNU stat treats -f as a filesystem-report command, so a BSD-first fallback can
# pollute arithmetic input before failing. Select the platform syntax once.
# shellcheck disable=SC2034 # Probed once and read by the stat helpers below.
SNAPSHOT_STAT_STYLE=descriptor
file_mtime_epoch() {
  local info
  info=$(snapshot_record_info "$1") || return 1
  printf '%s\n' "$info" | jq -r '.mtime_seconds | floor'
}
file_mode_octal() {
  local info mode
  info=$(snapshot_record_info "$1") || return 1
  mode=$(printf '%s\n' "$info" | jq -r '.mode % 4096') || return 1
  printf '%03o\n' "$mode"
}

registry_secondmates_json() {
  local reg="$DATA/secondmates.md" out rc reason mode script parse_filter output_filter
  local reg_info input reg_size
  if [ "$LOCAL_ONLY" -eq 1 ] && [ -L "$reg" ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      '{present:true,available:false,complete:false,reason:"refused: the path is a symlink",provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:["refused: the path is a symlink"],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  if [ -e "$reg" ] || [ -L "$reg" ]; then
    if [ ! -f "$reg" ]; then
      jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
        '{present:true,available:false,complete:false,reason:"refused: the path is not a regular file",provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:["refused: the path is not a regular file"],lines_in_window:0,records_in_window:0}'
      return 0
    fi
  fi
  if [ ! -f "$reg" ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      '{present:false,available:true,complete:true,reason:null,provenance:"registered-table",path:$path,freshness:{status:"fresh",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  if [ "$LOCAL_ONLY" -eq 1 ] && ! snapshot_local_file_safe "$reg"; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" --arg reason "$SNAPSHOT_FILE_REASON" \
      '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  # shellcheck disable=SC2034 # Bound by the read loop and consumed by the registry builder.
  reg_info=$(snapshot_record_info "$reg") || {
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      --arg reason "registered secondmate table is unreadable" \
      '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    return 0
  }
  mode=$(file_mode_octal "$reg")
  if [ -z "$mode" ] || [ $((8#$mode & 0444)) -eq 0 ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      --arg reason "registered secondmate table is unreadable" \
      '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    max_lines=$1
    max_bytes=$2
    max_records=$3
    path=$4
    observed=$5
    parse_filter=$6
    output_filter=$7
    content=$8
    size=$9
    # Truncation is decided by the RECORD's own size, never by counting the
    # bytes that survived this hand-off: a window whose cut lands on a newline
    # loses that byte in transit, so a byte count here reported a bounded read
    # of a much larger table as complete.
    byte_truncated=false
    if [ "$size" -gt "$max_bytes" ]; then
      byte_truncated=true
      complete=${content%$'\n'*}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines=0
    fi
    line_truncated=false
    if [ "$lines" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C head -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | jq -Rn "$parse_filter") || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    records_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then records_truncated=true; fi
    printf "%s" "$records" | jq \
      --arg path "$path" --arg observed "$observed" \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson records_truncated "$records_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" "$output_filter"
BASH
  )
  parse_filter=$(cat <<'JQ'
      [ inputs
        | select(startswith("- "))
        | (capture("^- (?<id>[^[:space:]]+)")?) as $id
        | select($id != null)
        | ([capture("^.*\\(host:[[:space:]]*(?<host>[^;)]*);[[:space:]]*root:[[:space:]]*(?<root>[^;)]*);[[:space:]]*home:[[:space:]]*(?<home>[^;)]*);[[:space:]]*scope:[[:space:]]*.*;[[:space:]]*projects:[[:space:]]*[^;)]*;[[:space:]]*added[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$")?][0] // null) as $remote
        | ([capture("^.*\\(home:[[:space:]]*(?<home>[^;)]*);[[:space:]]*scope:[[:space:]]*.*;[[:space:]]*projects:[[:space:]]*[^;)]*;[[:space:]]*added[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$")?][0] // null) as $local
        | ($local // $remote) as $route
        | (($local == null) and ($remote != null)) as $is_remote
        | {id:$id.id,home:($route.home // null),host:(if $is_remote then $remote.host else null end),root:(if $is_remote then $remote.root else null end),
           remote:$is_remote,registered:true,
           registry_error:(if $route == null or ($route.home | length) == 0 then "registry entry has no home" else null end)} ]
      | group_by(.id)
      | map(if length > 1 then .[0] + {registry_error:"duplicate secondmate id in registry"} else .[0] end)
JQ
  )
  output_filter=$(cat <<'JQ'
      {present:true,available:true,reason:null,provenance:"registered-table",path:$path,
       freshness:{status:"fresh",observed_at:$observed},
       records:(if length > $max_records then .[:$max_records] else . end),
       input_truncated:($byte_truncated or $line_truncated),records_truncated:$records_truncated,
       complete:(($byte_truncated or $line_truncated or $records_truncated) | not),
       reasons:[
         (if $byte_truncated then "byte_limit" else empty end),
         (if $line_truncated then "line_limit" else empty end),
         (if $records_truncated then "record_limit" else empty end)
       ],lines_in_window:$lines_in_window,records_in_window:$records_in_window}
JQ
  )
  reg_size=$(printf '%s\n' "$reg_info" | jq -r '.bytes') || reg_size=
  case "$reg_size" in
    ''|*[!0-9]*)
      jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
        --arg reason "registered secondmate table is unreadable" \
        '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
      return 0
      ;;
  esac
  input=$(snapshot_record_bytes "$reg" "$FM_SNAPSHOT_REGISTRY_BYTES") || {
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      --arg reason "registered secondmate table is unreadable" \
      '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    return 0
  }
  out=$(fm_run_timed "$FM_SNAPSHOT_REGISTRY_TIMEOUT" bash -c "$script" \
    fm-secondmate-registry "$FM_SNAPSHOT_REGISTRY_LINES" \
    "$FM_SNAPSHOT_REGISTRY_BYTES" "$FM_SNAPSHOT_REGISTRY_RECORDS" "$reg" "$SNAPSHOT_NOW" \
    "$parse_filter" "$output_filter" "$input" "$reg_size" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    .available == true and (.records | type) == "array"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="registered secondmate table read timed out" \
    || reason="registered secondmate table is unreadable"
  jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
    '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

bounded_parent_activities_json() {  # <status-file>
  # The status log is always this home's own record, so it is read against this
  # home's roots. There is no caller-supplied containment root: passing another
  # home's root here refused every read as resolving outside it.
  local f=$1 out rc reason script info size input window_file
  if ! info=$(snapshot_record_info "$f"); then
    reason=$(printf '%s' "$info" | tail -1)
    info=
  fi
  if [ -z "$info" ]; then
    if [ "$reason" = 'not present' ] || [ ! -e "$f" ]; then
      jq -n '{records:[],available:true,input_truncated:false,retained_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    else
      jq -n --arg reason "${reason:-record is unavailable}" \
        '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    fi
    return 0
  fi
  size=$(printf '%s\n' "$info" | jq -r '.bytes') || {
    jq -n '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:["record metadata is unreadable"],lines_in_window:0,records_in_window:0}'
    return 0
  }
  input=$(snapshot_record_tail_bytes "$f" "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES") || input=
  if [ -z "$input" ] && [ "$size" -gt 0 ]; then
    jq -n '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:["record could not be read"],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  if [ "$size" -eq 0 ]; then
    jq -n '{records:[],available:true,input_truncated:false,retained_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    classify=$1
    max_lines=$2
    max_bytes=$3
    max_records=$4
    size=$5
    window_file=$6
    . "$classify"
    content=$(cat "$window_file") || exit 3
    byte_truncated=false
    if [ "$size" -gt "$max_bytes" ]; then
      byte_truncated=true
      complete=${content#*$'\n'}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines_in_chunk=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines_in_chunk=0
    fi
    line_truncated=false
    if [ "$lines_in_chunk" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C tail -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | status_open_activities - \
      | jq -R -s '[splits("\n") | select(length > 0)
          | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
          | select(. != null)]') || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    retained_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then retained_truncated=true; fi
    printf "%s" "$records" | jq \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson retained_truncated "$retained_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" '
        {records:(if length > $max_records then .[-$max_records:] else . end),
         available:true,
         input_truncated:($byte_truncated or $line_truncated),
         retained_truncated:$retained_truncated,
         reasons:[
           (if $byte_truncated then "byte_limit" else empty end),
           (if $line_truncated then "line_limit" else empty end),
           (if $retained_truncated then "activity_limit" else empty end)
         ],
         lines_in_window:$lines_in_window,
         records_in_window:$records_in_window}'
BASH
  )
  # The classifier runs on the bytes the descriptor-anchored reader already
  # returned - it must never reopen the record path itself - and they are handed
  # over in a file this collector owns rather than on stdin. The shared timeout
  # helper runs its command asynchronously, and stdin delivery across that is not
  # dependable: an isolated call through its external-timeout or bash mechanism
  # delivers nothing, while its perl fallback delivers the bytes. An empty window
  # is indistinguishable from a successful read of nothing, so this hand-off is
  # made explicit rather than left to depend on which mechanism a host picks.
  window_file=$(mktemp "${TMPDIR:-/tmp}/fm-parent-activities.XXXXXX" 2>/dev/null) || {
    jq -n '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:["the activity window could not be staged"],lines_in_window:0,records_in_window:0}'
    return 0
  }
  printf '%s' "$input" > "$window_file" || {
    rm -f -- "$window_file"
    jq -n '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:["the activity window could not be staged"],lines_in_window:0,records_in_window:0}'
    return 0
  }
  out=$(fm_run_timed "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT" bash -c "$script" \
    fm-parent-activities "$SCRIPT_DIR/fm-classify-lib.sh" \
    "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES" "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES" \
    "$FM_SNAPSHOT_PARENT_ACTIVITIES" "$size" "$window_file" 2>/dev/null)
  rc=$?
  rm -f -- "$window_file"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    (.records | type) == "array" and (.available | type) == "boolean"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="timeout" || reason="read_failed"
  jq -n --arg reason "$reason" \
    '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

terminal_evidence_json() {  # <parent-task-json> <event-note> <evidence-contradicts>
  local task=$1 note=$2 evidence_contradicts=$3 backend target exists expected out rc clean bytes lines seen=false contradiction=false reason='' remote_host
  backend=$(printf '%s' "$task" | jq -r '.backend // ""')
  target=$(printf '%s' "$task" | jq -r '.endpoint.target // ""')
  exists=$(printf '%s' "$task" | jq -r '.endpoint.exists // "unknown"')
  remote_host=$(printf '%s' "$task" | jq -r '.remote.host // ""')
  if [ -n "$remote_host" ]; then
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "remote terminal evidence is not collected by the primary" \
      '{provenance:"remote-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  expected=$(printf '%s' "$task" | jq -r '"fm-" + (.id // "")')
  if [ -z "$target" ] || [ "$exists" = false ]; then
    [ "$exists" = false ] && reason="recorded endpoint is absent" || reason="no recorded endpoint"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  # shellcheck disable=SC2016 # Positional parameters expand inside the child bash, not here.
  out=$(fm_run_timed "$FM_SNAPSHOT_TERMINAL_TIMEOUT" bash -c \
    '. "$1"; fm_backend_capture "$2" "$3" "$4" "$5" | LC_ALL=C head -c "$6"; rc=${PIPESTATUS[0]}; [ "$rc" -eq 141 ] && rc=0; exit "$rc"' \
    fm-terminal-capture "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$FM_SNAPSHOT_TERMINAL_LINES" "$expected" "$FM_SNAPSHOT_TERMINAL_BYTES" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 124 ] && reason="terminal capture timed out" || reason="terminal capture unavailable"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  clean=$(printf '%s' "$out" | tail -n "$FM_SNAPSHOT_TERMINAL_LINES" | LC_ALL=C head -c "$FM_SNAPSHOT_TERMINAL_BYTES")
  if command -v perl >/dev/null 2>&1; then
    clean=$(printf '%s' "$clean" | perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g; s/[^\x09\x0A\x0D\x20-\x7E]//g')
  else
    clean=$(printf '%s' "$clean" | LC_ALL=C tr -cd '\11\12\15\40-\176')
  fi
  bytes=$(printf '%s' "$clean" | LC_ALL=C wc -c | tr -d ' ')
  if [ -n "$clean" ]; then
    lines=$(printf '%s\n' "$clean" | wc -l | tr -d ' ')
  else
    lines=0
  fi
  if [ -n "$note" ]; then
    case "$clean" in *"$note"*) seen=true ;; esac
  fi
  if [ "$seen" = true ] && [ "$evidence_contradicts" = true ]; then contradiction=true; fi
  jq -n \
    --arg observed "$SNAPSHOT_NOW" \
    --argjson lines "$lines" \
    --argjson bytes "$bytes" \
    --argjson seen "$seen" \
    --argjson contradiction "$contradiction" \
    '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:true,observed_at:$observed,freshness:"fresh",reason:null,lines:$lines,bytes:$bytes,event_note_seen:$seen,contradiction:$contradiction}'
}

parent_evidence_reconciliation_json() {  # <summary-json> <activities-json> <decisions-json>
  jq -n --argjson summary "$1" --argjson activities "$2" --argjson decisions "$3" '
    def keyed: . != null and . != "" and . != "default";
    def result($e; $matches; $complete; $surface):
      $e + {
        verdict:(if ($e.key | keyed | not) then "inconclusive"
                 elif ($matches | length) > 0 then "corroborates"
                 elif $complete then "contradicts"
                 else "inconclusive" end),
        compared_to:$surface,
        matched:(if ($e.key | keyed) then ($matches[0] // null) else null end)
      };
    ([ $activities[] as $e
       | if $e.verb == "working" then
           ([ $summary.active_children[]
              | select(if ($e.key | keyed) then .id == $e.key else true end)
              | {surface:"active_children",id,key:null,verb:"working"}]) as $matches
           | result($e; $matches;
               $summary.counts.active_children == ($summary.active_children | length);
               "active_children")
         elif $e.verb == "paused" then
           ([ $summary.holds[]
              | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
              | {surface:"holds",id,key:(.blocked_by // null),verb:"paused"}]) as $matches
           | result($e; $matches;
               $summary.counts.holds == ($summary.holds | length);
               "holds")
         else
           $e + {verdict:"inconclusive",compared_to:null,matched:null}
         end ]) as $activity_results
    | ([ $decisions[] as $e
         | if $e.verb == "needs-decision" then
             ([ $summary.decisions_open[]
                | select(.verb == "needs-decision")
                | select(if ($e.key | keyed) then .key == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]) as $matches
             | result($e; $matches;
                 $summary.counts.decisions_open == ($summary.decisions_open | length);
                 "decisions_open")
           elif $e.verb == "blocked" then
             ([ $summary.decisions_open[]
                | select(.verb == "blocked")
                | select(if ($e.key | keyed) then .key == $e.key or .id == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]
              + [ $summary.holds[]
                  | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
                  | {surface:"holds",id,key:(.blocked_by // null),verb:"blocked"}]) as $matches
             | result($e; $matches;
                 ($summary.counts.decisions_open == ($summary.decisions_open | length)
                  and $summary.counts.holds == ($summary.holds | length));
                 "decisions_open_or_holds")
           else
             $e + {verdict:"inconclusive",compared_to:null,matched:null}
           end ]) as $decision_results
    | {provenance:"parent-status-keyed-fold",trust:"untrusted-supplement",
       activities:$activity_results,decisions:$decision_results,
       contradiction:any(($activity_results + $decision_results)[]; .verdict == "contradicts"),
       inconclusive:any(($activity_results + $decision_results)[]; .verdict == "inconclusive")}'
}

secondmate_current_json() {  # <parent-tasks-json>
  local tasks=$1 registry union rows total_registered total shown truncated
  local row id home host remote registered registry_error task sampled_spawn_gen status_file event_raw event_note event_epoch event_age
  local activity_scan activities decisions reconciliation provenance freshness reason summary summary_rc summary_bytes summary_sampled summary_valid summary_reason summary_invalidity state current_reason terminal terminal_contradiction contradiction
  local records='[]' seen_homes=''
  registry=$(registry_secondmates_json) || return 1
  union=$(jq -n --argjson registry "$registry" --argjson tasks "$tasks" '
    ($registry.records // []) as $registered
    | (($registered | map(.id)) // []) as $registered_ids
    | ([ $registered[] as $r
         | $r + {parent_task:([$tasks[] | select(.id == $r.id)][0] // null)} ]
       + [ $tasks[] | select(.kind == "secondmate") as $t
           | select(($registered_ids | index($t.id)) == null)
           | {id:$t.id,home:($t.paths.home.path // null),
              registered:(if $registry.complete == true then false else null end),
              registry_error:(if $registry.complete == true
                              then "secondmate metadata is not registered"
                              else "secondmate registration is unknown because the registry read is incomplete or unavailable" end),
              parent_task:$t} ])
    | sort_by(.id)
    | {registry:$registry,records:.}') || return 1
  total_registered=$(printf '%s' "$union" | jq '[.records[] | select(.registered)] | length')
  total=$(printf '%s' "$union" | jq '.records | length')
  rows=$(printf '%s' "$union" | jq -c --argjson cap "$FM_SNAPSHOT_SECONDMATES" '(if $cap == 0 then .records else .records[:$cap] end)[]')
  shown=$(printf '%s\n' "$rows" | grep -c . || true)
  truncated=$((total - shown))

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    home=$(printf '%s' "$row" | jq -r '.home // ""')
    host=$(printf '%s' "$row" | jq -r '.host // ""')
    remote=$(printf '%s' "$row" | jq -r '.remote // false')
    registered=$(printf '%s' "$row" | jq -r '.registered')
    registry_error=$(printf '%s' "$row" | jq -r '.registry_error // ""')
    task=$(printf '%s' "$row" | jq -c '.parent_task // {}')
    sampled_spawn_gen=$(printf '%s' "$task" | jq -r '.spawn_gen // ""')
    status_file=$(printf '%s' "$task" | jq -r '.paths.status_log.path // ""')
    event_raw=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.raw // ""')
    event_note=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.note // ""')
    # This is the PARENT's own status log, so it is read against the parent's
    # roots. Bounding it by the registered child home refused every read as
    # resolving outside that home, which silently classified an empty activity
    # window - and an empty window can never contradict the child's own state.
    activity_scan=$(bounded_parent_activities_json "$status_file")
    activities=$(printf '%s' "$activity_scan" | jq -c '.records')
    decisions=$(printf '%s' "$task" | jq -c '.hints.open_decisions // []')
    event_epoch=$(file_mtime_epoch "$status_file") || event_epoch=
    event_age=null
    if [ -n "$event_epoch" ]; then
      event_age=$((SNAPSHOT_EPOCH - event_epoch))
      [ "$event_age" -lt 0 ] && event_age=0
    fi

    reason=$registry_error
    summary='{}'
    summary_sampled=false
    summary_valid=false
    if [ "$LOCAL_ONLY" -eq 1 ] && [ "$remote" = true ]; then
      reason="remote evidence unavailable in local-only snapshot"
    elif [ -z "$reason" ] && [ -z "$home" ]; then
      reason="no recorded secondmate home"
    fi
    if [ -z "$reason" ]; then
      case "$home" in
        /*) : ;;
        *) reason="invalid home: registered path is not absolute" ;;
      esac
    fi
    if [ -z "$reason" ]; then
      if [ "$remote" = true ] && [ "$LOCAL_ONLY" -eq 0 ]; then
        [ -n "$host" ] || reason="invalid remote route: missing SSH host"
        case " $seen_homes " in
          *" $host:$home "*) reason="invalid home: duplicate resolved remote route" ;;
          *) seen_homes="$seen_homes $host:$home" ;;
        esac
      elif ! validate_secondmate_home "$id" "$home" 2>/dev/null; then
        reason="invalid home: $VALIDATION_ERROR"
      else
        home=$VALIDATED_HOME
        case " $seen_homes " in
          *" local:$home "*) reason="invalid home: duplicate resolved home route" ;;
          *) seen_homes="$seen_homes local:$home" ;;
        esac
      fi
    fi
    if [ -z "$reason" ]; then
      if [ "$remote" = true ]; then
        summary=$(fm_run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" \
          "$SCRIPT_DIR/fm-on.sh" "$id" fm-fleet-snapshot.sh --secondmate-home-summary < /dev/null 2>/dev/null)
        summary_rc=$?
      else
        summary=$(fm_run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" env \
          FM_ROOT_OVERRIDE="$FM_ROOT" \
          FM_HOME="$home" \
          FM_STATE_OVERRIDE="$home/state" \
          FM_DATA_OVERRIDE="$home/data" \
          FM_CONFIG_OVERRIDE="$home/config" \
          FM_PROJECTS_OVERRIDE="$home/projects" \
          FM_SNAPSHOT_NOW="$SNAPSHOT_NOW" \
          FM_SNAPSHOT_NOW_EPOCH="$SNAPSHOT_EPOCH" \
          FM_SNAPSHOT_SECONDMATE_CHILDREN="$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
          FM_SNAPSHOT_SECONDMATE_QUEUED="$FM_SNAPSHOT_SECONDMATE_QUEUED" \
          FM_SNAPSHOT_SECONDMATE_DECISIONS="$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
          FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME="$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
          "$SCRIPT_DIR/fm-fleet-snapshot.sh" --local-only --secondmate-home-summary 2>/dev/null)
        summary_rc=$?
      fi
      if [ "$summary_rc" -ne 0 ]; then
        summary='{}'
        [ "$summary_rc" -eq 124 ] && reason="structured home snapshot timed out" || reason="structured home snapshot failed"
      else
        summary_bytes=$(printf '%s' "$summary" | LC_ALL=C wc -c | tr -d ' ')
        if [ "$summary_bytes" -gt "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES" ]; then
          reason="structured home snapshot exceeded byte limit"
        elif ! printf '%s' "$summary" | jq -e --arg home "$home" --arg generated "$SNAPSHOT_NOW" --argjson remote "$remote" '
          .schema == "fm-secondmate-home-summary.v1" and .home == $home
          and (($remote == true) or .generated == $generated)
          and (.valid | type) == "boolean" and (.state | type) == "string"
          and (.invalidity | type) == "object" and (.invalidity.ids | type) == "array"
          and (.active_children | type) == "array" and (.decisions_open | type) == "array"
          and (.holds | type) == "array" and (.queued | type) == "array"
          and (.landed | type) == "array" and (.endpoints | type) == "array"
          and (.counts | type) == "object" and (.omitted | type) == "array"
        ' >/dev/null 2>&1; then
          reason="structured home snapshot was malformed or stale"
        else
          summary_sampled=true
          summary_valid=$(printf '%s' "$summary" | jq -r '.valid')
          if [ "$summary_valid" != true ]; then
            summary_reason=$(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')
            summary_invalidity=$(printf '%s' "$summary" | jq -r '.invalidity.kind // "unknown"')
            case "$summary_invalidity" in
              child_current_unavailable|orphan_in_flight|unowned_current|terminal_in_flight) : ;;
              *) reason="structured home state invalid: $summary_reason" ;;
            esac
          fi
        fi
      fi
    fi

    if [ -z "$reason" ]; then
      state=$(printf '%s' "$summary" | jq -r '.state')
      current_reason=
      if [ "$summary_valid" != true ]; then
        current_reason="structured home state invalid: $(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')"
      fi
      reconciliation=$(parent_evidence_reconciliation_json "$summary" "$activities" "$decisions")
      contradiction=$(printf '%s' "$reconciliation" | jq -r '.contradiction')
      terminal_contradiction=$(printf '%s' "$reconciliation" | jq -r --arg note "$event_note" '
        any(.activities[]; .verdict == "contradicts" and .summary == $note)')
      if [ "$terminal_contradiction" = true ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" true)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no useful contradiction check",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      if printf '%s' "$terminal" | jq -e '.contradiction == true' >/dev/null; then contradiction=true; fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg host "$host" --argjson remote "$remote" --arg state "$state" --arg current_reason "$current_reason" --arg observed "$SNAPSHOT_NOW" \
        --arg spawn_gen "$sampled_spawn_gen" \
        --argjson registered "$registered" --argjson summary "$summary" --argjson summary_valid "$summary_valid" --argjson decisions "$decisions" \
        --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson reconciliation "$reconciliation" --argjson terminal "$terminal" --argjson contradiction "$contradiction" \
        --arg event_raw "$event_raw" --arg event_note "$event_note" --argjson event_age "$event_age" '
        {id:$id,home:$home,host:($host | if . == "" then null else . end),remote:$remote,registered:$registered,
         spawn_gen:($spawn_gen | if . == "" then null else . end),
         current:{state:$state,reason:($current_reason | if . == "" then null else . end)},invalidity:$summary.invalidity,
         reconcile_inventory:$summary.invalidity,
         provenance:{selected:"structured-home",structured_home:$home,summary_valid:$summary_valid,
           trust:(if $summary_valid then "complete" else "partial-structured" end),parent_event_role:"historical-only"},
         freshness:{status:"fresh",observed_at:$observed,age_seconds:0},
         active_children:$summary.active_children,
         decisions_open:$summary.decisions_open,holds:$summary.holds,queued:$summary.queued,
         landed:$summary.landed,endpoints:$summary.endpoints,counts:$summary.counts,omitted:$summary.omitted,
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan,reconciliation:$reconciliation},
         terminal_evidence:$terminal,contradiction:$contradiction}')
    else
      if [ -n "$event_raw" ]; then
        provenance='parent-event-fallback'
        freshness=historical-event
      else
        provenance=unknown
        freshness=unknown
      fi
      if [ -n "$event_raw" ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" false)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no parent event to compare",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg host "$host" --argjson remote "$remote" --arg reason "$reason" --arg observed "$SNAPSHOT_NOW" \
        --arg spawn_gen "$sampled_spawn_gen" \
        --arg provenance "$provenance" --arg freshness "$freshness" --arg event_raw "$event_raw" --arg event_note "$event_note" \
        --argjson registered "$registered" --argjson event_age "$event_age" --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson decisions "$decisions" --argjson terminal "$terminal" --argjson summary "$summary" --argjson summary_sampled "$summary_sampled" '
        {id:$id,home:($home | if . == "" then null else . end),host:($host | if . == "" then null else . end),remote:$remote,registered:$registered,
         spawn_gen:($spawn_gen | if . == "" then null else . end),
         current:{state:"unknown",reason:$reason},invalidity:null,
         reconcile_inventory:(if $summary_sampled then $summary.invalidity else null end),
         provenance:{selected:$provenance,structured_home:($home | if . == "" then null else . end),parent_event_role:"fallback-only-not-current"},
         freshness:{status:$freshness,observed_at:$observed,age_seconds:$event_age},
         active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[],
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan},
         terminal_evidence:$terminal,contradiction:false}')
    fi
    records=$(jq -n --argjson records "$records" --argjson record "$record" '$records + [$record]')
  done <<EOF
$rows
EOF
  jq -n \
    --argjson registry "$(printf '%s' "$union" | jq '.registry')" \
    --argjson records "$records" \
    --argjson total_registered "$total_registered" \
    --argjson total "$total" \
    --argjson shown "$shown" \
    --argjson truncated "$truncated" \
    '{registry:$registry,records:$records,total_registered:$total_registered,total:$total,shown:$shown,truncated:$truncated}'
}

secondmate_landed_from_current_json() {  # <secondmate-current-json>
  jq -n --argjson current "$1" '
    {records:[ $current.records[]
      | select(.provenance.selected == "structured-home") as $mate
      | $mate.landed[]
      | . + {home:$mate.home,home_id:$mate.id}],
     truncated:[ $current.records[]
       | select(.provenance.selected == "structured-home" and (.counts.landed > (.landed | length)))
       | .home],
     unreadable:[ $current.records[]
       | select(.current.state == "unknown" and .provenance.selected != "structured-home")
       | .home // ("<" + .id + ": unavailable>")],
     partial:[ $current.records[]
       | select(.provenance.selected == "structured-home" and .provenance.trust == "partial-structured")
       | .home // ("<" + .id + ": partial>")]}
    | .records |= sort_by([(.completion.date // ""), .id]) | .records |= reverse'
}

scout_report_lines() {
  local report id json status=0 limit=${1:-$FM_SNAPSHOT_REPORTS} overflow=false
  local overflow_count=0 discovery_error_count=0 discovery_limit=$limit
  local SNAPSHOT_REPORT_EXCLUDE_PATHS=${2:-}
  if [ "$limit" -le 0 ]; then
    discovery_limit=$FM_SNAPSHOT_REPORTS
  fi
  [ "$discovery_limit" -gt 0 ] || { jq -n '[]'; return 0; }
  if [ ! -d "$DATA" ] || { [ "$LOCAL_ONLY" -eq 1 ] && [ -L "$DATA" ]; }; then
    jq -n '[]'
    return 0
  fi
  json=$(snapshot_record_read "$DATA" report_paths "$discovery_limit" "$DATA") || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$json" >&2
    return "$status"
  fi
  # No discovery output is not an early exit: every report already linked to a
  # task is excluded from discovery, so a home whose only reports are linked
  # produces nothing here and still owes those pointers below.
  {
    while IFS= read -r report_json; do
      [ -n "$report_json" ] || continue
      if [ "$(printf '%s' "$report_json" | jq -r '.overflow // false')" = true ]; then
        overflow=true
        overflow_count=$((overflow_count + $(printf '%s' "$report_json" | jq -r '.count // 0')))
        continue
      fi
      if [ "$(printf '%s' "$report_json" | jq -r '.discovery_errors // false')" = true ]; then
        discovery_error_count=$(printf '%s' "$report_json" | jq -r '.count // 0')
        continue
      fi
      if [ "$(printf '%s' "$report_json" | jq -r '.error // false')" = true ]; then
        report=$(printf '%s' "$report_json" | jq -r '.path')
        id=$(basename "$(dirname "$report")")
        jq -n --arg id "$id" --arg path "$report" \
          --arg reason "$(printf '%s' "$report_json" | jq -r '.reason // "report discovery failed"')" \
          '{id:$id,path:$path,error:true,available:false,reason:$reason}'
        continue
      fi
      report=$(printf '%s' "$report_json" | jq -r '.path')
      if [ "$limit" -le 0 ]; then
        overflow_count=$((overflow_count + 1))
        continue
      fi
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path}'
    done <<< "$json"
    # A report already linked to a task is excluded from the BOUNDED discovery
    # above so the report bound can spend itself on task-linked reports first.
    # It is still a present report pointer, which is what this field promises
    # every consumer, so it is listed here rather than disappearing from the
    # snapshot entirely. A consumer that also reads .tasks[].paths.report
    # deduplicates by path.
    while IFS= read -r report; do
      [ -n "$report" ] || continue
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path,linked:true}'
    done <<EOF
$SNAPSHOT_REPORT_EXCLUDE_PATHS
EOF
    if [ "$overflow" = true ] || [ "$overflow_count" -gt 0 ]; then
      jq -n --argjson count "$overflow_count" \
        '{id:"__scout_report_overflow__",path:"",overflow:true,count:$count}'
    fi
    if [ "$discovery_error_count" -gt 0 ]; then
    jq -n --argjson count "$discovery_error_count" \
        '{id:"__scout_report_discovery_errors__",path:"",discovery_errors:true,count:$count}'
    fi
  } | jq -s 'sort_by(.id)'
}

# --- freshness ---------------------------------------------------------------
# ONE owner of the freshness stamp, in the one command that reads the evidence.
# Two rules make it an authority rather than a guess:
#   - Its inputs are resolved ONCE per run: the bounded fingerprint roots (this
#     home plus every validated registered secondmate home) and the registry
#     half of the live inputs.
#   - `--json` computes its stamp BEFORE it reads a single record. A stamp taken
#     afterwards would describe a home the payload never saw, so a record that
#     changed mid-collection would leave pre-change evidence under a post-change
#     stamp and every later check would match it and reuse the stale payload.
#     Publishing the pre-read stamp inverts that: the change no longer matches,
#     so the next check rebuilds.
# A consumer never derives freshness itself. It reads .freshness.stamp from this
# document, or asks this command for the current one - both come from here.
STAMP_INPUTS_READY=0
STAMP_ROOTS_JSON=
STAMP_REGISTRY_INPUTS=

# Inert unless a test sets it, exactly like the wake drain's commit-window hook.
# It widens the window the pre-read stamp exists to survive, which cannot be
# driven deterministically from outside this command.
snapshot_test_delay_after_stamp() {
  case "${FM_SNAPSHOT_TEST_DELAY_AFTER_STAMP:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_SNAPSHOT_TEST_DELAY_AFTER_STAMP" ;;
  esac
}

collector_stamp_inputs() {
  [ "$STAMP_INPUTS_READY" -eq 0 ] || return 0
  local registry registry_status id home remote
  STAMP_ROOTS_JSON=$(jq -cn --arg state "$STATE" --arg data "$DATA" \
    --arg config "$CONFIG" --arg projects "$PROJECTS" \
    '[{root:$state,label:"state"},{root:$data,label:"data"},
      {root:$config,label:"config"},{root:$projects,label:"projects"}]') || return 1
  registry=$(registry_secondmates_json) || return 1
  registry_status=$(printf '%s' "$registry" | jq -c \
    '{available,complete,reason,records:(.records | map({id,home,remote}))}') || return 1
  STAMP_REGISTRY_INPUTS=$(printf 'registry:%s\n' "$registry_status")
  while IFS=$'\t' read -r id home remote; do
    [ -n "$id" ] || continue
    if [ "$remote" = false ] && [ -n "$home" ] && \
       validate_secondmate_home "$id" "$home" 2>/dev/null; then
      STAMP_ROOTS_JSON=$(printf '%s' "$STAMP_ROOTS_JSON" | jq -c --arg root "$home" \
        --arg label "secondmate:$id" '. + [{root:$root,label:$label}]')
    else
      STAMP_REGISTRY_INPUTS=$(printf '%s\nregistry-home:%s:unavailable' \
        "$STAMP_REGISTRY_INPUTS" "$id")
    fi
  done < <(printf '%s' "$registry" | jq -r '.records[]? | [.id, (.home // ""), (.remote // false)] | @tsv')
  STAMP_INPUTS_READY=1
}

# The bounded filesystem fingerprint half, on its own so `--json` can take it
# before its reads and compare it again afterwards to say whether the evidence
# it published moved underneath it.
collector_local_stamp() {
  collector_stamp_inputs || return 1
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - \
    "$STAMP_ROOTS_JSON" "$FM_DASHBOARD_STAMP_DEPTH" "$FM_DASHBOARD_STAMP_MAX_ENTRIES" <<'PY'
import json
import sys
from fm_dashboard_io import bounded_stamp

roots = [(item["root"], item["label"]) for item in json.loads(sys.argv[1])]
print(bounded_stamp(roots, int(sys.argv[2]), int(sys.argv[3])))
PY
}

collector_stamp() {
  # shellcheck disable=SC2034 # Bound by the read loop and consumed per home below.
  local local_stamp live_inputs='' meta meta_text
  local meta_reason id backend target kind state_result agent_result rc
  collector_stamp_inputs || return 1
  live_inputs=$STAMP_REGISTRY_INPUTS

  if [ -n "${FM_DASHBOARD_STAMP_LIVE_INPUTS:-}" ]; then
    live_inputs=$(printf '%s\n%s' "$live_inputs" "$FM_DASHBOARD_STAMP_LIVE_INPUTS")
  else
    while IFS= read -r meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      id=$(basename "$meta" .meta)
      if ! meta_text=$(snapshot_record_text "$meta" "$FM_SNAPSHOT_META_BYTES" \
        "$STATE" "$DATA" "$CONFIG" "$PROJECTS"); then
        meta_reason=$(printf '%s' "$meta_text" | tail -1)
        live_inputs=$(printf '%s\ntask:%s:metadata:%s' "$live_inputs" "$id" \
          "${meta_reason:-unavailable}")
        continue
      fi
      kind=$(meta_value_text "$meta_text" kind)
      if [ -n "$(meta_value_text "$meta_text" remote_host)" ]; then
        continue
      fi
      backend=$(meta_value_text "$meta_text" backend)
      [ "$backend" = herdr ] || continue
      if [ "$(meta_value_text "$meta_text" backend)" = herdr ]; then
        target=$(meta_value_text "$meta_text" window)
        [ -n "$target" ] || continue
        if state_result=$(snapshot_herdr_target_state "$target" "fm-$id" 2>&1); then
          live_inputs=$(printf '%s\ntask:%s:endpoint:ok:%s' "$live_inputs" "$id" "$state_result")
        else
          rc=$?
          live_inputs=$(printf '%s\ntask:%s:endpoint:failed:%s' "$live_inputs" "$id" "$state_result")
        fi
        if [ "$kind" = secondmate ]; then
          if agent_result=$(snapshot_herdr_agent_alive "$target" 2>&1); then
            live_inputs=$(printf '%s\ntask:%s:agent:ok:%s' "$live_inputs" "$id" "$agent_result")
          else
            rc=$?
            live_inputs=$(printf '%s\ntask:%s:agent:failed:%s' "$live_inputs" "$id" "$agent_result")
          fi
        fi
      fi
    done < <(printf '%s\n' "$STATE"/*.meta)
  fi

  # A pre-read fingerprint taken by this same run is pinned here, so one
  # authority still produces the stamp from both halves.
  if [ -n "${FM_DASHBOARD_STAMP_LOCAL:-}" ]; then
    local_stamp=$FM_DASHBOARD_STAMP_LOCAL
  else
    local_stamp=$(collector_local_stamp) || return 1
  fi
  printf '%s\n%s\n' "$local_stamp" "$live_inputs" | python3 -c \
    'import hashlib, sys; print(hashlib.sha256("\\0".join(sorted(sys.stdin.read().splitlines())).encode()).hexdigest())'
}

if [ "$OUTPUT_MODE" = stamp ]; then
  collector_stamp || { echo "fm-fleet-snapshot: freshness stamp failed" >&2; exit 1; }
  exit 0
fi

# Resolved once, then fingerprinted BEFORE the first record read below.
collector_stamp_inputs \
  || { echo "fm-fleet-snapshot: freshness inputs failed" >&2; exit 1; }
FRESHNESS_LOCAL_BEFORE=$(collector_local_stamp) \
  || { echo "fm-fleet-snapshot: freshness fingerprint failed" >&2; exit 1; }
FRESHNESS_STAMP=$(FM_DASHBOARD_STAMP_LOCAL="$FRESHNESS_LOCAL_BEFORE" collector_stamp) \
  || { echo "fm-fleet-snapshot: freshness stamp failed" >&2; exit 1; }
snapshot_test_delay_after_stamp

BACKLOG_JSON=$(backlog_json) || { echo "fm-fleet-snapshot: backlog read failed" >&2; exit 1; }
TASKS_JSON=$(task_json_lines) || { echo "fm-fleet-snapshot: task snapshot failed" >&2; exit 1; }

FRESHNESS_LOCAL_AFTER=$(collector_local_stamp) \
  || { echo "fm-fleet-snapshot: freshness fingerprint failed" >&2; exit 1; }
FRESHNESS_TORN=false
if [ "$FRESHNESS_LOCAL_BEFORE" != "$FRESHNESS_LOCAL_AFTER" ]; then
  FRESHNESS_TORN=true
fi

if [ "$OUTPUT_MODE" = secondmate-home-summary ]; then
  secondmate_home_summary_json "$BACKLOG_JSON" "$TASKS_JSON" \
    || { echo "fm-fleet-snapshot: secondmate home summary failed" >&2; exit 1; }
  exit 0
fi

linked_report_paths=$(printf '%s' "$TASKS_JSON" | jq -r '[.[]
  | select((.paths.report.path // "") != "" and (.paths.report.present // false))
  | .paths.report.path] | unique | .[]?') \
  || { echo "fm-fleet-snapshot: linked report count failed" >&2; exit 1; }
linked_report_count=$(printf '%s\n' "$linked_report_paths" | awk 'NF { count++ } END { print count + 0 }')
scout_report_limit=$((FM_SNAPSHOT_REPORTS - linked_report_count))
SCOUT_REPORTS_JSON=$(scout_report_lines "$scout_report_limit" "$linked_report_paths") \
  || { echo "fm-fleet-snapshot: scout report discovery failed" >&2; exit 1; }
MAIN_INVENTORY_JSON=$(main_inventory_json "$BACKLOG_JSON" "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: main inventory summary failed" >&2; exit 1; }
SECONDMATE_CURRENT_JSON=$(secondmate_current_json "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: registered secondmate aggregation failed" >&2; exit 1; }
SECONDMATE_LANDED_JSON=$(secondmate_landed_from_current_json "$SECONDMATE_CURRENT_JSON") \
  || { echo "fm-fleet-snapshot: secondmate landed projection failed" >&2; exit 1; }

jq -n \
  --arg generated "$SNAPSHOT_NOW" \
  --arg freshness_stamp "$FRESHNESS_STAMP" \
  --argjson freshness_torn "$FRESHNESS_TORN" \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --argjson backlog "$BACKLOG_JSON" \
  --argjson tasks "$TASKS_JSON" \
  --argjson main_inventory "$MAIN_INVENTORY_JSON" \
  --argjson scout_reports "$SCOUT_REPORTS_JSON" \
  --argjson secondmate_current "$SECONDMATE_CURRENT_JSON" \
  --argjson secondmate_landed "$SECONDMATE_LANDED_JSON" \
  'def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     generated:$generated,
     freshness:{stamp:$freshness_stamp, taken:"before-reads", torn:$freshness_torn},
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     main_inventory:$main_inventory,
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
     secondmate_current:$secondmate_current,
     secondmate_landed:$secondmate_landed,
     secondmate_guidance:{
       note:"For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority."
     }
   }'
