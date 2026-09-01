#!/usr/bin/env bash
# fm-dashboard.sh - the read-only control-plane evidence collector and server.
#
# Two jobs, one command:
#   `json`  collects this home's durable text records into one bounded,
#           path-safe, symlink-safe evidence document. This is the ONLY thing
#           that opens a record path, which is what lets every consumer share a
#           single audited read boundary.
#   `serve` runs the dashboard: the React client from assets/dashboard plus the
#           versioned read-only API it calls (bin/fm_dashboard_server.py).
#
# NOT A CONTROL PLANE. Nothing here spawns, steers, merges, tears down, or
# acknowledges. The server refuses every mutating HTTP method before routing.
# Firstmate remains the only prompt and control-plane interface.
#
# LOCAL-ONLY. No network, GitHub, or authentication call on any path, and the
# served client loads nothing remote. Recorded PR facts are labelled recorded,
# never live.
#
# Reads are bounded, path-safe, and symlink-safe: a status log or report is read
# only when it is a regular file, is not itself a symlink, and resolves inside
# this home's state or data root. Anything refused is disclosed in `degraded[]`
# so a missing surface is never silently rendered as an empty one.
#
# The browser never reads a filesystem path. It calls the API, and the API is
# served by this command from evidence collected here.
#
# Usage:
#   fm-dashboard.sh json                 print the fm-dashboard.v1 payload
#   fm-dashboard.sh serve [--port <n>] [--owner-digest <hex>]
#                                        serve the page on 127.0.0.1 only
#
# `render` replays a payload captured earlier by `json`, which is how a page is
# rebuilt from evidence that has since changed, and how the shipped renderer is
# tested against payloads no live home would produce. It refuses any file that
# is not a readable fm-dashboard.v1 document.
#
# `build` with no --out writes the stable path and prints `dashboard: <path>`;
# open that file directly, no server required. `serve` is the explicit opt-in
# refresh mechanism: it binds 127.0.0.1 and nothing else, rebuilds the payload
# on each request so a reload shows current evidence, answers only `/` and
# `/healthz`, serves no other file, and fails closed with a plain-text 500 when
# a rebuild fails. It needs python3 and refuses with that requirement named
# when python3 is absent.
#
# `/healthz` answers one fm-dashboard-health.v1 JSON object naming this home and
# the owner digest passed in with --owner-digest, which is how a caller proves
# the process answering a port is the exact dashboard it started for this exact
# home rather than an unrelated local listener. Only the digest is ever passed
# in or published; bin/fm-dashboard-start.sh keeps the token itself private.
#
# Bounds (every one is disclosed in the payload when it truncates):
#   FM_DASHBOARD_EVENT_LINES   status-log lines kept per task (default 40)
#   FM_DASHBOARD_WAKES         queued wake records kept (default 50)
#   FM_DASHBOARD_REPORTS       report bodies read (default 40)
#   FM_DASHBOARD_REPORT_BYTES  bytes read per report body (default 65536)
#   FM_DASHBOARD_BUILD_TIMEOUT seconds allowed for each complete build (default 120)
#   FM_DASHBOARD_PORT          default serve port (default 8787)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

DASH_SCHEMA=fm-dashboard.v1
SNAPSHOT_SCHEMA=fm-fleet-snapshot.v1

FM_DASHBOARD_EVENT_LINES=${FM_DASHBOARD_EVENT_LINES:-40}
FM_DASHBOARD_WAKES=${FM_DASHBOARD_WAKES:-50}
FM_DASHBOARD_REPORTS=${FM_DASHBOARD_REPORTS:-40}
FM_DASHBOARD_REPORT_BYTES=${FM_DASHBOARD_REPORT_BYTES:-65536}
FM_DASHBOARD_BUILD_TIMEOUT=${FM_DASHBOARD_BUILD_TIMEOUT:-120}
FM_DASHBOARD_PORT=${FM_DASHBOARD_PORT:-8787}
FM_DASHBOARD_STAMP_DEPTH=${FM_DASHBOARD_STAMP_DEPTH:-2}
FM_DASHBOARD_STAMP_MAX_ENTRIES=${FM_DASHBOARD_STAMP_MAX_ENTRIES:-512}

fail() {
  printf 'fm-dashboard: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

validate_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) fail "$1 must be a positive integer" ;;
  esac
}
validate_bound FM_DASHBOARD_EVENT_LINES "$FM_DASHBOARD_EVENT_LINES"
validate_bound FM_DASHBOARD_WAKES "$FM_DASHBOARD_WAKES"
validate_bound FM_DASHBOARD_REPORTS "$FM_DASHBOARD_REPORTS"
validate_bound FM_DASHBOARD_REPORT_BYTES "$FM_DASHBOARD_REPORT_BYTES"
validate_bound FM_DASHBOARD_BUILD_TIMEOUT "$FM_DASHBOARD_BUILD_TIMEOUT"
validate_bound FM_DASHBOARD_STAMP_DEPTH "$FM_DASHBOARD_STAMP_DEPTH"
validate_bound FM_DASHBOARD_STAMP_MAX_ENTRIES "$FM_DASHBOARD_STAMP_MAX_ENTRIES"

DASH_ROOT_REASON=
HOME_REAL=$(cd "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")
evidence_root_safe() {  # <label> <root>
  local label=$1 root=$2 parent base real
  DASH_ROOT_REASON=
  if [ -L "$root" ]; then
    DASH_ROOT_REASON="$label is a symlink"
    return 1
  fi
  if [ -e "$root" ]; then
    [ -d "$root" ] || { DASH_ROOT_REASON="$label is not a directory"; return 1; }
    real=$(cd "$root" 2>/dev/null && pwd -P) || {
      DASH_ROOT_REASON="$label could not be resolved"
      return 1
    }
  else
    parent=${root%/*}
    [ "$parent" = "$root" ] && parent=.
    base=${root##*/}
    real=$(cd "$parent" 2>/dev/null && pwd -P) || {
      DASH_ROOT_REASON="$label parent could not be resolved"
      return 1
    }
    real="$real/$base"
  fi
  case "$real" in
    "$HOME_REAL"|"$HOME_REAL"/*) return 0 ;;
    *) DASH_ROOT_REASON="$label resolves outside this home"; return 1 ;;
  esac
}

evidence_root_safe state "$STATE" || fail "unsafe evidence root: $DASH_ROOT_REASON"
evidence_root_safe data "$DATA" || fail "unsafe evidence root: $DASH_ROOT_REASON"
evidence_root_safe config "$CONFIG" || fail "unsafe evidence root: $DASH_ROOT_REASON"

payload_is_valid() {  # <payload-file>
  jq -e --arg expected_home "$FM_HOME" '
    def has_type($o; $k; $t): ($o | has($k)) and ($o[$k] | type == $t);
    def has_nullable($o; $k; $t): ($o | has($k)) and (($o[$k] == null) or ($o[$k] | type == $t));
    def nonneg_int: if type == "number" then isfinite and floor == . and . >= 0 and . <= 9007199254740991 else false end;
    def safe_epoch:
      type == "number" and isfinite and floor == .
      and . >= -8640000000000 and . <= 8640000000000;
    def valid_timestamp:
      if type != "string" then false
      elif (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then false
      else (try fromdateiso8601 catch null) as $epoch
        | $epoch != null and $epoch >= -8640000000000 and $epoch <= 8640000000000
      end;
    def bounded_counts:
      type == "object" and has_type(.; "total"; "number")
      and has_type(.; "shown"; "number") and has_type(.; "truncated"; "number")
      and (.total | nonneg_int) and (.shown | nonneg_int) and (.truncated | nonneg_int)
      and (.shown <= .total) and (.truncated == (.total - .shown));
    def usage_budget:
      type == "object" and has_type(.; "available"; "boolean")
      and has_nullable(.; "reason"; "string")
      and has_nullable(.; "effective_budget_tokens"; "number")
      and has_nullable(.; "total_estimated_tokens"; "number")
      and has_nullable(.; "status"; "string") and has_type(.; "files"; "array")
      and all(.files[]; type == "object" and has_type(.; "file"; "string")
        and has_nullable(.; "bytes"; "number")
        and (if .bytes == null then true else (.bytes | nonneg_int) end)
        and has_nullable(.; "estimated_tokens"; "number")
        and (if .estimated_tokens == null then true else (.estimated_tokens | nonneg_int) end)
        and has_type(.; "status"; "string"))
      and (if .available then
        (.effective_budget_tokens | nonneg_int)
        and (.total_estimated_tokens | nonneg_int)
        and (.status == "within-budget" or .status == "over-budget")
        and (([.files[] | .estimated_tokens] | map(select(. != null))) as $est
          | if (.files | length) == 0 then
              .total_estimated_tokens == 0 and .status == "within-budget"
            else ($est | length) == (.files | length)
              and .total_estimated_tokens == ($est | add)
            end)
        and (if .status == "within-budget" then .total_estimated_tokens <= .effective_budget_tokens
             else .total_estimated_tokens > .effective_budget_tokens end)
      else
        .effective_budget_tokens == null and .total_estimated_tokens == null
        and .status == null and (.files | length) == 0
      end);
    def path_ref($v):
      ($v | type == "object" and has_nullable(.; "path"; "string")
       and has_nullable(.; "present"; "boolean"));
    def decision:
      type == "object" and has_type(.; "key"; "string") and has_type(.; "verb"; "string")
      and has_type(.; "summary"; "string");
    def backlog_record:
      type == "object" and has_type(.; "state"; "string") and has_type(.; "key"; "string")
      and has_type(.; "structured"; "boolean")
      and (if .structured then
        has_type(.; "id"; "string") and has_type(.; "title"; "string")
        and has_nullable(.; "raw"; "string") and has_nullable(.; "repo"; "string")
        and has_nullable(.; "kind"; "string") and has_nullable(.; "priority"; "string")
        and has_nullable(.; "hold_reason"; "string") and has_nullable(.; "hold_kind"; "string")
        and has_nullable(.; "hold_until"; "string") and has_nullable(.; "blocked_reason"; "string")
        and has_nullable(.; "since"; "string") and has_nullable(.; "merged"; "string")
        and has_nullable(.; "reported"; "string") and has_nullable(.; "done"; "string")
        and has_nullable(.; "local_note"; "string") and has_nullable(.; "pr_url"; "string")
        and has_nullable(.; "report_path"; "string") and has_nullable(.; "body_excerpt"; "string")
        and has_type(.; "blocked_by_ids"; "array") and all(.blocked_by_ids[]; type == "string")
        and has_type(.; "unresolved_blocker_ids"; "array") and all(.unresolved_blocker_ids[]; type == "string")
        and has_type(.; "completion"; "object")
        and has_nullable(.completion; "verb"; "string") and has_nullable(.completion; "date"; "string")
        and has_type(.; "links"; "array") and all(.links[]; type == "string")
        and has_type(.; "captain_actionable"; "boolean")
        and has_type(.; "deferred_marker"; "boolean")
        and has_type(.; "current_role"; "string")
        and has_type(.; "requires_child_metadata"; "boolean")
      else has_type(.; "raw"; "string") and has_nullable(.; "id"; "string") end);
    def task:
      type == "object" and has_type(.; "id"; "string") and (.id | length) > 0
      and has_type(.; "kind"; "string") and has_type(.; "harness"; "string")
      and has_nullable(.; "model"; "string") and has_nullable(.; "effort"; "string")
      and has_type(.; "mode"; "string") and has_type(.; "yolo"; "string")
      and has_type(.; "project"; "string") and has_nullable(.; "spawn_gen"; "string")
      and has_type(.; "backend"; "string") and has_nullable(.; "remote"; "object")
      and (if .remote == null then true
           else has_type(.remote; "host"; "string") and has_type(.remote; "root"; "string")
             and has_nullable(.remote; "evidence"; "string") and has_nullable(.remote; "reason"; "string") end)
      and has_type(.; "paths"; "object")
      and path_ref(.paths.meta) and path_ref(.paths.status_log) and path_ref(.paths.worktree)
      and path_ref(.paths.home) and path_ref(.paths.report)
      and has_type(.; "current_state"; "object")
      and has_type(.current_state; "state"; "string") and has_type(.current_state; "source"; "string")
      and has_type(.current_state; "detail"; "string") and has_type(.current_state; "raw"; "string")
      and has_type(.current_state; "observed_at"; "string") and has_type(.current_state; "freshness"; "string")
      and has_type(.; "endpoint"; "object") and has_nullable(.endpoint; "target"; "string")
      and has_nullable(.endpoint; "exists"; "boolean") and has_type(.endpoint; "agent_alive"; "string")
      and has_type(.endpoint; "status"; "string") and has_type(.endpoint; "observed_at"; "string")
      and has_type(.endpoint; "freshness"; "string")
      and has_type(.; "pr"; "object") and has_nullable(.pr; "url"; "string")
      and has_type(.pr; "source"; "string") and has_type(.; "hints"; "object")
      and has_type(.hints; "pending_decision"; "boolean") and has_type(.hints; "blocked_event"; "boolean")
      and has_type(.hints; "open_decisions"; "array") and all(.hints.open_decisions[]; decision)
      and has_type(.hints; "scout_report_present"; "boolean") and has_type(.hints; "last_event_text"; "string")
      and has_type(.; "actions"; "object") and has_type(.actions; "watch"; "string")
      and (has_type(.actions; "steer"; "string") or has_type(.actions; "send"; "string"))
      and has_nullable(.actions; "return_channel_note"; "string")
      and ((.backlog == null) or (.backlog | backlog_record));
    def event:
      type == "object" and has_type(.; "task_id"; "string") and has_type(.; "path"; "string")
      and has_type(.; "readable"; "boolean") and has_nullable(.; "reason"; "string")
      and bounded_counts and has_type(.; "total_exact"; "boolean") and has_type(.; "lines"; "array")
      and (.shown == (.lines | length))
      and all(.lines[]; type == "object" and has_type(.; "verb"; "string")
        and has_type(.; "note"; "string") and has_type(.; "raw"; "string"));
    def report:
      type == "object" and has_type(.; "id"; "string") and has_type(.; "path"; "string")
      and has_type(.; "readable"; "boolean") and has_nullable(.; "reason"; "string")
      and has_type(.; "bytes"; "number") and (.bytes | nonneg_int)
      and has_type(.; "truncated"; "boolean")
      and has_nullable(.; "modified"; "string") and has_type(.; "body"; "string");
    def wake:
      type == "object" and has_nullable(.; "epoch"; "number") and has_nullable(.; "seq"; "string")
      and has_nullable(.; "kind"; "string") and has_nullable(.; "key"; "string")
      and has_type(.; "payload"; "string") and has_type(.; "malformed"; "boolean")
      and (.epoch == null or (.epoch | safe_epoch))
      and (if .malformed then true else
        (.epoch | safe_epoch) and has_type(.; "seq"; "string")
        and has_type(.; "kind"; "string") and has_type(.; "key"; "string")
      end);
    def evidence: type == "object";
    def secondmate:
      type == "object" and has_type(.; "id"; "string") and has_nullable(.; "home"; "string")
      and has_nullable(.; "host"; "string") and has_type(.; "remote"; "boolean")
      and has_nullable(.; "spawn_gen"; "string") and has_nullable(.; "registered"; "boolean")
      and has_type(.; "current"; "object") and has_type(.current; "state"; "string")
      and has_nullable(.current; "reason"; "string") and has_type(.; "provenance"; "object")
      and has_type(.provenance; "selected"; "string")
      and has_type(.provenance; "parent_event_role"; "string")
      and has_type(.; "freshness"; "object") and has_type(.freshness; "status"; "string")
      and has_type(.freshness; "observed_at"; "string")
      and has_nullable(.freshness; "age_seconds"; "number")
      and has_type(.; "active_children"; "array") and all(.active_children[]; evidence)
      and has_type(.; "decisions_open"; "array") and all(.decisions_open[]; evidence)
      and has_type(.; "holds"; "array") and all(.holds[]; evidence)
      and has_type(.; "queued"; "array") and all(.queued[]; evidence)
      and has_type(.; "landed"; "array") and all(.landed[]; evidence)
      and has_type(.; "endpoints"; "array") and all(.endpoints[]; evidence)
      and has_type(.; "counts"; "object")
      and has_type(.counts; "active_children"; "number") and (.counts.active_children | nonneg_int)
      and has_type(.counts; "decisions_open"; "number") and (.counts.decisions_open | nonneg_int)
      and has_type(.counts; "holds"; "number") and (.counts.holds | nonneg_int)
      and has_type(.counts; "queued"; "number") and (.counts.queued | nonneg_int)
      and has_type(.counts; "landed"; "number") and (.counts.landed | nonneg_int)
      and has_type(.counts; "endpoints"; "number") and (.counts.endpoints | nonneg_int)
      and (.counts.active_children >= (.active_children | length))
      and (.counts.decisions_open >= (.decisions_open | length))
      and (.counts.holds >= (.holds | length)) and (.counts.queued >= (.queued | length))
      and (.counts.landed >= (.landed | length)) and (.counts.endpoints >= (.endpoints | length))
      and has_type(.; "omitted"; "array") and all(.omitted[]; evidence)
      and has_type(.; "parent_event"; "object") and has_type(.; "terminal_evidence"; "object")
      and has_type(.; "contradiction"; "boolean");
    def snapshot:
      type == "object" and .schema == "fm-fleet-snapshot.v1"
      and has_type(.; "generated"; "string") and has_type(.; "fm_home"; "string")
      and has_type(.; "roots"; "object") and has_type(.roots; "state"; "string")
      and has_type(.roots; "data"; "string") and has_type(.roots; "config"; "string")
      and has_type(.roots; "projects"; "string") and has_type(.; "backlog"; "object")
      and has_type(.backlog; "path"; "string") and has_type(.backlog; "present"; "boolean")
      and has_type(.backlog; "available"; "boolean") and has_nullable(.backlog; "reason"; "string")
      and has_type(.backlog; "records"; "array") and all(.backlog.records[]; backlog_record)
      and has_type(.; "tasks"; "array") and all(.tasks[]; task)
      and has_type(.; "scout_reports"; "array")
      and all(.scout_reports[]; type == "object" and has_type(.; "id"; "string")
        and has_type(.; "path"; "string") and has_type(.; "kind"; "string"))
      and has_type(.; "main_inventory"; "object") and has_type(.main_inventory; "valid"; "boolean")
      and has_nullable(.main_inventory; "reason"; "string")
      and has_type(.main_inventory; "orphan_in_flight"; "array")
      and all(.main_inventory.orphan_in_flight[]; type == "string")
      and has_type(.; "secondmate_current"; "object")
      and (.secondmate_current | bounded_counts)
      and has_type(.secondmate_current; "registry"; "object")
      and has_type(.secondmate_current.registry; "path"; "string")
      and has_type(.secondmate_current.registry; "present"; "boolean")
      and has_type(.secondmate_current.registry; "available"; "boolean")
      and has_type(.secondmate_current.registry; "complete"; "boolean")
      and has_nullable(.secondmate_current.registry; "reason"; "string")
      and has_type(.secondmate_current; "records"; "array")
      and (.secondmate_current.shown == (.secondmate_current.records | length))
      and all(.secondmate_current.records[]; secondmate)
      and has_type(.; "secondmate_landed"; "object")
      and has_type(.secondmate_landed; "records"; "array")
      and all(.secondmate_landed.records[]; evidence)
      and has_type(.secondmate_landed; "truncated"; "array")
      and all(.secondmate_landed.truncated[]; type == "string")
      and has_type(.secondmate_landed; "unreadable"; "array")
      and all(.secondmate_landed.unreadable[]; type == "string")
      and has_type(.secondmate_landed; "partial"; "array")
      and all(.secondmate_landed.partial[]; type == "string")
      and has_type(.; "secondmate_guidance"; "object")
      and has_type(.secondmate_guidance; "note"; "string");
    (.schema == "fm-dashboard.v1")
    and (.generated | valid_timestamp)
    and has_type(.; "freshness_stamp"; "string") and (.freshness_stamp | length) > 0
    and ((.fm_home | type) == "string")
    and (.fm_home == $expected_home)
    and (.snapshot | snapshot)
    and (.snapshot.fm_home == .fm_home)
    and ((.supervision | type) == "object")
    and has_type(.supervision; "model"; "string") and has_type(.supervision; "healthy"; "boolean")
    and has_type(.supervision; "reason"; "string") and has_type(.supervision; "beacon_present"; "boolean")
    and has_nullable(.supervision; "beacon_age_seconds"; "number")
    and has_type(.supervision; "away_mode"; "boolean") and has_type(.supervision; "recovery_marker"; "boolean")
    and has_type(.supervision; "wakes"; "object")
    and (.supervision.wakes | bounded_counts)
    and has_type(.supervision.wakes; "total_exact"; "boolean")
    and has_type(.supervision.wakes; "available"; "boolean")
    and has_nullable(.supervision.wakes; "reason"; "string")
    and has_type(.supervision.wakes; "records"; "array")
    and (.supervision.wakes.shown == (.supervision.wakes.records | length))
    and all(.supervision.wakes.records[]; wake)
    and has_type(.; "events"; "array") and all(.events[]; event)
    and has_type(.; "reports"; "object")
    and (.reports | bounded_counts) and has_type(.reports; "records"; "array")
    and (.reports.shown == (.reports.records | length))
    and all(.reports.records[]; report)
    and has_type(.; "usage"; "object") and has_type(.usage; "budget"; "object")
    and (.usage.budget | usage_budget)
    and has_type(.usage; "agents"; "array")
    and all(.usage.agents[]; type == "object" and has_type(.; "task_id"; "string")
      and has_type(.; "kind"; "string") and has_type(.; "harness"; "string")
      and has_nullable(.; "model"; "string") and has_nullable(.; "effort"; "string")
      and has_type(.; "backend"; "string") and has_type(.; "mode"; "string")
      and has_type(.; "yolo"; "string"))
    and has_type(.; "degraded"; "array")
    and all(.degraded[]; type == "object" and has_type(.; "source"; "string")
      and has_type(.; "path"; "string") and has_type(.; "reason"; "string"))
  ' "$1" >/dev/null 2>&1
}

snapshot_is_valid() {  # <snapshot-file>
  jq -e '
    def valid_timestamp:
      if type != "string" then false
      elif (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then false
      else (try fromdateiso8601 catch null) as $epoch
        | $epoch != null and $epoch >= -8640000000000 and $epoch <= 8640000000000
      end;
    (.schema == "fm-fleet-snapshot.v1")
    and (.generated | valid_timestamp)
    and ((.fm_home | type) == "string")
    and ((.roots | type) == "object")
    and ((.roots.state | type) == "string")
    and ((.roots.data | type) == "string")
    and ((.roots.config | type) == "string")
    and ((.roots.projects | type) == "string")
    and ((.backlog | type) == "object")
    and ((.backlog.path | type) == "string")
    and ((.backlog.present | type) == "boolean")
    and ((.backlog.available | type) == "boolean")
    and ((.backlog.reason == null) or ((.backlog.reason | type) == "string"))
    and ((.backlog.records | type) == "array")
    and all(.tasks[]; type == "object" and (.id | type) == "string")
    and ((.tasks | type) == "array")
    and ((.scout_reports | type) == "array")
    and all(.scout_reports[]; type == "object" and (.id | type) == "string"
      and (.path | type) == "string" and (.kind | type) == "string")
    and ((.main_inventory | type) == "object")
  ' "$1" >/dev/null 2>&1
}

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"  # status_line_verb / status_line_note
TMP=
cleanup() { [ -n "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT INT TERM

make_tmp() {
  [ -n "$TMP" ] && return 0
  TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX") \
    || fail "cannot create a working directory"
}

# --- bounded, path-safe, symlink-safe reads -------------------------------
# A file is readable evidence only when it is a regular file, is not itself a
# symlink, and resolves inside one of this home's evidence roots. An
# intermediate symlinked directory is allowed only while it still resolves
# inside those roots, which is what `pwd -P` decides.

DASH_REASON=
DASH_REAL=
DASH_MTIME=
DASH_BYTES=0
DASH_LINES=0
DASH_LINES_EXACT=true
DASH_TRUNCATED=false
STATE_REAL=$(cd "$STATE" 2>/dev/null && pwd -P || printf '%s' "$STATE")
DATA_REAL=$(cd "$DATA" 2>/dev/null && pwd -P || printf '%s' "$DATA")

evidence_root_safe state "$STATE" || fail "unsafe evidence root: $DASH_ROOT_REASON"
evidence_root_safe data "$DATA" || fail "unsafe evidence root: $DASH_ROOT_REASON"
evidence_root_safe config "$CONFIG" || fail "unsafe evidence root: $DASH_ROOT_REASON"
STATE_REAL=$(cd "$STATE" 2>/dev/null && pwd -P || printf '%s' "$STATE")
DATA_REAL=$(cd "$DATA" 2>/dev/null && pwd -P || printf '%s' "$DATA")

inside_roots() {  # <resolved-path>
  case "$1" in
    "$STATE_REAL"/*|"$DATA_REAL"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"  # supervision model and process identity helpers

secure_record() {  # <path> <mode> <limit> <output> <metadata>
  local p=$1 mode=$2 limit=$3 output=$4 metadata=$5 error
  DASH_REASON=
  DASH_REAL=
  DASH_MTIME=
  DASH_BYTES=0
  DASH_LINES=0
  DASH_LINES_EXACT=true
  DASH_TRUNCATED=false
  error="$metadata.error"
  : > "$metadata"
  : > "$error"
  if ! python3 "$SCRIPT_DIR/fm-dashboard-read.py" "$p" "$STATE_REAL" "$DATA_REAL" \
      "$mode" "$limit" "$output" "$metadata" 2> "$error"; then
    DASH_REASON=$(tr '\n' ' ' < "$error" | sed 's/[[:space:]]*$//')
    [ -n "$DASH_REASON" ] || DASH_REASON='could not read the record'
    return 1
  fi
  DASH_REAL=$(jq -r '.path' "$metadata")
  DASH_MTIME=$(jq -r '.mtime_seconds' "$metadata")
  DASH_BYTES=$(jq -r '.bytes // 0' "$metadata")
  DASH_LINES=$(jq -r '.total_lines // 0' "$metadata")
  DASH_LINES_EXACT=$(jq -r '.total_lines_exact // true' "$metadata")
  DASH_TRUNCATED=$(jq -r '.truncated // false' "$metadata")
  return 0
}

state_entry_safe() {  # <path> -> 0 when absent or contained and non-symlink
  local p=$1 dir base real
  DASH_REASON=
  if [ -L "$p" ]; then DASH_REASON='refused: the path is a symlink'; return 1; fi
  [ -e "$p" ] || return 0
  dir=${p%/*}
  [ "$dir" = "$p" ] && dir=.
  base=${p##*/}
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    DASH_REASON='refused: the directory could not be resolved'; return 1; }
  real="$real/$base"
  case "$real" in
    "$STATE_REAL"/*) return 0 ;;
    *) DASH_REASON='refused: resolves outside this state root'; return 1 ;;
  esac
}

DEGRADED=
note_degraded() {  # <source> <path> <reason>
  jq -cn --arg source "$1" --arg path "$2" --arg reason "$3" \
    '{source:$source,path:$path,reason:$reason}' >> "$DEGRADED"
}

# --- collectors -----------------------------------------------------------

supervision_field() {  # <path> <output> <metadata>
  local path=$1 output=$2 metadata=$3
  SUPERVISION_FIELD_REASON=
  if ! secure_record "$path" text 4096 "$output" "$metadata"; then
    SUPERVISION_FIELD_REASON=$DASH_REASON
    return 1
  fi
  SUPERVISION_FIELD_VALUE=$(tr -d '\r\n' < "$output")
  return 0
}

supervision_extension_owns() {  # <state> <root>
  local state=$1 root=$2 session_pid marker version marker_version marker_pid
  if ! supervision_field "$state/.lock" "$TMP/supervision-session" \
      "$TMP/supervision-session.meta"; then
    return 1
  fi
  session_pid=$SUPERVISION_FIELD_VALUE
  for marker in fm-primary-pi-watch.ts:.pi-watch-extension-loaded \
                fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded; do
    version=$(fm_pi_extension_version "$root/.pi/extensions/${marker%%:*}" 2>/dev/null) \
      || return 1
    if ! secure_record "$state/${marker#*:}" lines 2 "$TMP/supervision-marker" \
        "$TMP/supervision-marker.meta"; then
      return 1
    fi
    marker_version=$(sed -n '1p' "$TMP/supervision-marker")
    marker_pid=$(sed -n '2p' "$TMP/supervision-marker")
    [ "$marker_version" = "$version" ] || return 1
    [ "$marker_pid" = "$session_pid" ] || return 1
  done
  fm_pid_alive "$session_pid"
}

collect_supervision() {  # -> JSON object on stdout
  local verdict_ok=false reason model age away recovery beat present lock marker
  local lock_pid lock_home lock_path lock_identity current_identity fresh=false
  local lock_bad=false field_reason grace=${FM_GUARD_GRACE:-300}
  case "$grace" in ''|*[!0-9]*|0) grace=300 ;; esac
  model=$(fm_supervision_model)
  lock="$STATE/.watch.lock"
  for field in pid fm-home watcher-path pid-identity; do
    if ! supervision_field "$lock/$field" "$TMP/supervision-$field" \
        "$TMP/supervision-$field.meta"; then
      field_reason=$SUPERVISION_FIELD_REASON
      if [ "$field_reason" != 'not present' ]; then
        lock_bad=true
        note_degraded supervision "$lock/$field" "$field_reason"
      fi
      continue
    fi
    case "$field" in
      pid) lock_pid=$SUPERVISION_FIELD_VALUE ;;
      fm-home) lock_home=$SUPERVISION_FIELD_VALUE ;;
      watcher-path) lock_path=$SUPERVISION_FIELD_VALUE ;;
      pid-identity) lock_identity=$SUPERVISION_FIELD_VALUE ;;
    esac
  done
  beat="$STATE/.last-watcher-beat"
  present=false
  age=null
  if secure_record "$beat" stat 1 "$TMP/heartbeat" "$TMP/heartbeat.meta"; then
    present=true
    age=$(( $(date +%s) - ${DASH_MTIME%.*} ))
    [ "$age" -lt 0 ] && age=0
    case "$age" in ''|*[!0-9]*) age=null ;; esac
    case "$age" in ''|null) ;; *) [ "$age" -lt "$grace" ] && fresh=true ;; esac
  elif [ "$DASH_REASON" != 'not present' ]; then
    note_degraded 'watcher heartbeat' "$beat" "$DASH_REASON"
  fi
  reason=stale-beacon
  if [ "$lock_bad" = true ]; then
    reason="unsafe supervision source"
  elif [ "$model" = autoarm ]; then
    [ "$fresh" = true ] && { verdict_ok=true; reason=ok; }
  elif [ -n "${lock_pid:-}" ] && fm_pid_alive "$lock_pid" \
      && [ "${lock_home:-}" = "$FM_HOME" ] \
      && [ "${lock_path:-}" = "$lock" ] \
      && [ -n "${lock_identity:-}" ] \
      && current_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null) \
      && [ "$current_identity" = "$lock_identity" ] \
      && [ "$fresh" = true ]; then
    verdict_ok=true
    reason=ok
  elif [ "$model" = extension ] && [ -z "${lock_pid:-}" ] \
      && [ "$fresh" = true ] && supervision_extension_owns "$STATE" "$FM_ROOT"; then
    verdict_ok=true
    reason=ok
  elif [ "$fresh" = true ]; then
    reason=no-watcher
  fi
  away=false
  marker="$STATE/.afk"
  secure_record "$marker" stat 1 "$TMP/away" "$TMP/away.meta" && away=true \
    || { [ "$DASH_REASON" = 'not present' ] || note_degraded 'away marker' "$marker" "$DASH_REASON"; }
  recovery=false
  marker="$STATE/.watcher-down"
  secure_record "$marker" stat 1 "$TMP/recovery" "$TMP/recovery.meta" && recovery=true \
    || { [ "$DASH_REASON" = 'not present' ] || note_degraded 'recovery marker' "$marker" "$DASH_REASON"; }
  jq -n \
    --arg model "$model" --arg reason "$reason" \
    --argjson healthy "$verdict_ok" --argjson age "$age" \
    --argjson present "$present" \
    --argjson away "$away" --argjson recovery "$recovery" \
    --argjson wakes "$(collect_wakes)" \
    '{model:$model, healthy:$healthy, reason:$reason,
      beacon_present:$present, beacon_age_seconds:$age, away_mode:$away,
      recovery_marker:$recovery, wakes:$wakes}'
}

collect_wakes() {  # -> JSON object on stdout
  local queue="$STATE/.wake-queue" total=0 tail_file="$TMP/wakes.txt"
  if [ ! -e "$queue" ] && [ ! -L "$queue" ]; then
    jq -n '{records:[], total:0, shown:0, truncated:0, total_exact:true, available:true, reason:"no queued notifications"}'
    return 0
  fi
  if ! secure_record "$queue" lines "$FM_DASHBOARD_WAKES" "$tail_file" "$TMP/wakes.meta"; then
    note_degraded 'wake queue' "$queue" "$DASH_REASON"
    jq -n --arg reason "$DASH_REASON" \
      '{records:[], total:0, shown:0, truncated:0, total_exact:true, available:false, reason:$reason}'
    return 0
  fi
  total=$DASH_LINES
  local total_exact=$DASH_LINES_EXACT
  # Fields are tab-separated and each was sanitized of tabs by the queue writer
  # (fm-wake-lib.sh's fm_wake_clean_field), so a record that does not split into
  # five fields is a hand-edited or torn line and is surfaced as malformed
  # rather than parsed into the wrong columns.
  jq -Rn --argjson total "$total" --argjson total_exact "$total_exact" --argjson shown_cap "$FM_DASHBOARD_WAKES" '
    [inputs
      | select(length > 0)
      | split("\t")
      | if length == 5 and (.[0] | test("^[0-9]+$"))
        then {epoch:(.[0]|tonumber), seq:.[1], kind:.[2], key:.[3], payload:.[4], malformed:false}
        else {epoch:null, seq:null, kind:null, key:null, payload:(. | join("\t")), malformed:true}
        end] as $records
    | {records:$records, total:$total, shown:($records|length), total_exact:$total_exact,
       truncated:(if $total > $shown_cap then $total - $shown_cap else 0 end),
       available:true,
       reason:(if ($records|length) == 0 then "no queued notifications" else null end)}
  ' < "$tail_file"
}

collect_events() {  # <snapshot-file> -> JSON array on stdout
  local id path total tail_file="$TMP/status.txt" triples="$TMP/triples.txt"
  local out="$TMP/events.jsonl" line verb note
  : > "$out"
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] || continue
    if ! secure_record "$path" lines "$FM_DASHBOARD_EVENT_LINES" "$tail_file" "$TMP/events.meta"; then
      if [ "$DASH_REASON" != 'not present' ] && [ "$DASH_REASON" != 'no recorded path' ]; then
        note_degraded "status log for $id" "$path" "$DASH_REASON"
      fi
      jq -cn --arg id "$id" --arg path "$path" --arg reason "$DASH_REASON" \
        '{task_id:$id, path:$path, readable:false, reason:$reason,
          total:0, shown:0, truncated:0, total_exact:true, lines:[]}' >> "$out"
      continue
    fi
    total=$DASH_LINES
    local total_exact=$DASH_LINES_EXACT
    : > "$triples"
    while IFS= read -r line || [ -n "$line" ]; do
      verb=$(status_line_verb "$line")
      note=$(status_line_note "$line")
      printf '%s\n%s\n%s\n' "$verb" "$note" "$line" >> "$triples"
    done < "$tail_file"
    jq -cRn --arg id "$id" --arg path "$DASH_REAL" \
      --argjson total "$total" --argjson total_exact "$total_exact" --argjson cap "$FM_DASHBOARD_EVENT_LINES" '
      [inputs] as $l
      | [range(0; ($l | length) / 3 | floor)
         | {verb:$l[. * 3], note:$l[. * 3 + 1], raw:$l[. * 3 + 2]}] as $lines
      | {task_id:$id, path:$path, readable:true, reason:null, total_exact:$total_exact,
         total:$total, shown:($lines|length),
         truncated:(if $total > $cap then $total - $cap else 0 end),
         lines:$lines}
    ' < "$triples" >> "$out"
  done <<EOF
$(jq -r '.tasks[] | [.id, (.paths.status_log.path // "")] | @tsv' "$1")
EOF
  jq -s '.' "$out"
}

collect_reports() {  # <snapshot-file> -> JSON object on stdout
  local id path total kept=0 body="$TMP/report.md" out="$TMP/reports.jsonl" list="$TMP/reports.list"
  local modified truncated bytes overflow=0 discovered=0 discovery_errors=0
  : > "$out"
  overflow=$(jq '[.scout_reports[] | select(.overflow == true) | (.count // 1)] | add // 0' "$1")
  if [ "$overflow" -gt 0 ]; then
    note_degraded 'scout reports' "$DATA" 'report discovery exceeded the bounded report authority'
  fi
  discovery_errors=$(jq '[.scout_reports[] | select(.discovery_errors == true) | (.count // 1)] | add // 0' "$1")
  if [ "$discovery_errors" -gt 0 ]; then
    note_degraded 'scout reports' "$DATA" 'report discovery encountered unreadable or unsafe entries'
  fi
  jq -r '
    ([.tasks[]
      | {id:.id, path:(.paths.report.path // ""), present:(.paths.report.present // false), linked:true}
      | select(.path != "" and .present)]
     + [.scout_reports[] | select((.overflow // false) != true and (.discovery_errors // false) != true)
        | {id:.id, path:.path, linked:false}])
    | reduce .[] as $item ([]; if any(.[]; .path == $item.path) then . else . + [$item] end)
    | .[] | [.id, .path, (.linked // false)] | @tsv
  ' "$1" > "$list"
  discovered=$(wc -l < "$list" | tr -d '[:space:]')
  total=$((discovered + overflow))
  while IFS=$'\t' read -r id path linked; do
    [ -n "$id" ] || continue
    if [ "$kept" -ge "$FM_DASHBOARD_REPORTS" ]; then
      continue
    fi
    kept=$((kept + 1))
    if ! secure_record "$path" bytes "$FM_DASHBOARD_REPORT_BYTES" "$body" "$TMP/report.meta"; then
      note_degraded "report for $id" "$path" "$DASH_REASON"
      jq -cn --arg id "$id" --arg path "$path" --arg reason "$DASH_REASON" \
        '{id:$id, path:$path, readable:false, reason:$reason,
          bytes:0, truncated:false, modified:null, body:""}' >> "$out"
      continue
    fi
    bytes=$DASH_BYTES
    truncated=$DASH_TRUNCATED
    modified=$(date -u -r "${DASH_MTIME%.*}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@${DASH_MTIME%.*}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || printf '')
    jq -cn --arg id "$id" --arg path "$DASH_REAL" --arg modified "$modified" \
      --argjson bytes "$bytes" --argjson truncated "$truncated" \
      --rawfile body "$body" \
      '{id:$id, path:$path, readable:true, reason:null,
        bytes:$bytes, truncated:$truncated,
        modified:(if $modified == "" then null else $modified end),
        body:$body}' >> "$out"
  done <<EOF
$(cat "$list")
EOF
  jq -s --argjson total "$total" \
    '{records:., total:$total, shown:(.|length),
      truncated:(if $total > (.|length) then $total - (.|length) else 0 end)}' "$out"
}

collect_usage() {  # <snapshot-file> -> JSON object on stdout
  local report status=0 budget
  report=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-startup-memory-budget.sh" report 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    note_degraded 'startup memory budget' "$FM_HOME/config/startup-memory-budget" \
      'the local token budget could not be read'
    budget=$(jq -n '{available:false, reason:"the local token budget could not be read",
      effective_budget_tokens:null, total_estimated_tokens:null, status:null, files:[]}')
  else
    budget=$(printf '%s\n' "$report" | jq -Rn '
      [inputs | select(length > 0)] as $lines
      | ($lines | map(select(startswith("file=")) | split(" ")
          | {file:(.[0][5:]), bytes:((.[1][6:]) | tonumber? // null),
             estimated_tokens:((.[2][17:]) | tonumber? // null),
             status:(.[3][7:])})) as $files
      | ($lines | map(select(startswith("effective_budget_tokens="))) | first) as $b
      | ($lines | map(select(startswith("total_estimated_tokens="))) | first) as $t
      | ($lines | map(select(startswith("budget_status="))) | first) as $s
      | {available:true, reason:null,
         effective_budget_tokens:(if $b then ($b[24:] | tonumber? // null) else null end),
         total_estimated_tokens:(if $t then ($t[23:] | tonumber? // null) else null end),
         status:(if $s then $s[14:] else null end),
         files:$files}')
  fi
  jq -n --argjson budget "$budget" --slurpfile snapshot "$1" '
    {budget:$budget,
     agents:($snapshot[0].tasks | map({
       task_id:.id, kind:.kind, harness:.harness,
       model:(.model // null), effort:(.effort // null),
       backend:.backend, mode:.mode, yolo:.yolo}))}'
}

command_stamp() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  FM_SNAPSHOT_REPORTS="$FM_DASHBOARD_REPORTS" \
    FM_DASHBOARD_STAMP_DEPTH="$FM_DASHBOARD_STAMP_DEPTH" \
    FM_DASHBOARD_STAMP_MAX_ENTRIES="$FM_DASHBOARD_STAMP_MAX_ENTRIES" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --local-only --stamp
}

compose() {  # -> the fm-dashboard.v1 payload on stdout
  local snapshot="$TMP/snapshot.json" generated freshness_stamp snapshot_live_inputs
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -x "$SCRIPT_DIR/fm-fleet-snapshot.sh" ] || fail "bin/fm-fleet-snapshot.sh is missing"
  DEGRADED="$TMP/degraded.jsonl"
  : > "$DEGRADED"
  FM_SNAPSHOT_REPORTS="$FM_DASHBOARD_REPORTS" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --local-only --json > "$snapshot" \
    || fail "the fleet snapshot failed, so there is nothing trustworthy to render"
  snapshot_is_valid "$snapshot" \
    || fail "the fleet snapshot did not return a $SNAPSHOT_SCHEMA document"
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  snapshot_live_inputs=$(jq -r '
    .tasks[]
    | select(.backend == "herdr" and .remote == null)
    | ("task:" + .id + ":endpoint:" +
       (if .endpoint.freshness == "degraded" then
          "failed:" + (.endpoint.reason // "endpoint probe failed")
        else
          "ok:" + (if .endpoint.exists == false then "dead"
                    elif .endpoint.status == "present" then "present"
                    else "unknown" end)
        end)),
      (if .kind == "secondmate" then
         "task:" + .id + ":agent:" +
         (if .endpoint.freshness == "degraded" and .endpoint.agent_alive == "unknown" then
            "failed:" + (.endpoint.reason // "agent probe failed")
          else "ok:" + (.endpoint.agent_alive // "unknown") end)
       else empty end)
  ' "$snapshot") \
    || fail "the collector live-input document could not be prepared"
  export FM_DASHBOARD_STAMP_LIVE_INPUTS="$snapshot_live_inputs"
  freshness_stamp=$(command_stamp) || fail "the evidence freshness stamp failed"
  unset FM_DASHBOARD_STAMP_LIVE_INPUTS
  jq -n \
    --arg schema "$DASH_SCHEMA" \
    --arg generated "$generated" \
    --arg freshness_stamp "$freshness_stamp" \
    --arg fm_home "$FM_HOME" \
    --slurpfile snapshot "$snapshot" \
    --argjson supervision "$(collect_supervision)" \
    --argjson events "$(collect_events "$snapshot")" \
    --argjson reports "$(collect_reports "$snapshot")" \
    --argjson usage "$(collect_usage "$snapshot")" \
    --slurpfile degraded "$DEGRADED" \
    '{schema:$schema, generated:$generated, freshness_stamp:$freshness_stamp, fm_home:$fm_home,
      snapshot:$snapshot[0], supervision:$supervision, events:$events,
      reports:$reports, usage:$usage, degraded:$degraded}'
}

# --- commands -------------------------------------------------------------

command_json() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  command -v python3 >/dev/null 2>&1 || fail "json needs python3 for secure record reads"
  if [ "${FM_DASHBOARD_BUILD_INNER:-0}" != 1 ]; then
    export FM_DASHBOARD_BUILD_INNER=1
    fm_run_timed "$FM_DASHBOARD_BUILD_TIMEOUT" "$SCRIPT_DIR/fm-dashboard.sh" json
    return $?
  fi
  make_tmp
  compose > "$TMP/payload.json" || exit 1
  payload_is_valid "$TMP/payload.json" \
    || fail "the composed dashboard payload is incomplete or unusable"
  cat "$TMP/payload.json"
}




command_serve() {
  local port=$FM_DASHBOARD_PORT dev_reload=0
  local digest=''
  local app_dir="${FM_DASHBOARD_APP_DIR:-$SCRIPT_DIR/../assets/dashboard}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) shift; [ "$#" -gt 0 ] || fail "--port needs a number"; port=$1; shift ;;
      --owner-digest)
        shift
        [ "$#" -gt 0 ] || fail "--owner-digest needs a value"
        digest=$1
        shift
        ;;
      --app-dir) shift; [ "$#" -gt 0 ] || fail "--app-dir needs a path"; app_dir=$1; shift ;;
      --dev) dev_reload=1; shift ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$digest" in
    '') ;;
    *[!0-9a-f]*) fail "--owner-digest must be lowercase hex" ;;
  esac
  # Refuse rather than serve a partial application: a shell with no built assets
  # would otherwise answer every view with a 503 that looks like a server fault.
  [ -d "$app_dir" ] && [ ! -L "$app_dir" ] \
    || fail "the dashboard application directory is missing: $app_dir (build it with bin/fm-dashboard-build.sh)"
  [ -f "$app_dir/index.html" ] && [ ! -L "$app_dir/index.html" ] \
    || fail "the dashboard application is not built: $app_dir/index.html is absent"
  case "$port" in
    ''|*[!0-9]*) fail "--port must be a number: $port" ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail "--port must be 1-65535: $port"
  command -v python3 >/dev/null 2>&1 \
    || fail "serve needs python3 to run the dashboard server"
  make_tmp
  # The rebuilding child must resolve the SAME home this invocation resolved,
  # so export the resolved home and every override rather than letting the
  # child re-derive them from a different ambient environment.
  export FM_HOME
  [ -n "${FM_ROOT_OVERRIDE:-}" ] && export FM_ROOT_OVERRIDE
  [ -n "${FM_STATE_OVERRIDE:-}" ] && export FM_STATE_OVERRIDE
  [ -n "${FM_DATA_OVERRIDE:-}" ] && export FM_DATA_OVERRIDE
  [ -n "${FM_CONFIG_OVERRIDE:-}" ] && export FM_CONFIG_OVERRIDE
  [ -n "${FM_PROJECTS_OVERRIDE:-}" ] && export FM_PROJECTS_OVERRIDE
  export FM_DASHBOARD_EVENT_LINES FM_DASHBOARD_WAKES
  export FM_DASHBOARD_REPORTS FM_DASHBOARD_REPORT_BYTES
  export FM_DASHBOARD_BUILD_TIMEOUT
  export FM_DASHBOARD_STAMP_DEPTH FM_DASHBOARD_STAMP_MAX_ENTRIES
  export FM_DASHBOARD_BUILD_INNER=1
  # shellcheck disable=SC2034 # Consumed by fm_dashboard_server.py from its environment.
  FM_DASHBOARD_SELF="$SCRIPT_DIR/fm-dashboard.sh" FM_DASHBOARD_BIND_PORT="$port" \
    FM_DASHBOARD_OWNER_DIGEST="$digest" FM_DASHBOARD_HEALTH_HOME="$FM_HOME" \
  # The server itself now lives in bin/fm_dashboard_server.py. It is a real API,
  # asset and stream server rather than a one-route shim, and a program that size
  # belongs in a file that can be read, linted and tested on its own.
  FM_DASHBOARD_SELF="$SCRIPT_DIR/fm-dashboard.sh" FM_DASHBOARD_BIND_PORT="$port" \
    FM_DASHBOARD_OWNER_DIGEST="$digest" FM_DASHBOARD_HEALTH_HOME="$FM_HOME" \
    FM_DASHBOARD_APP_DIR="$app_dir" FM_DASHBOARD_DEV_RELOAD="$dev_reload" \
    exec python3 "$SCRIPT_DIR/fm_dashboard_server.py"
}

case "${1-}" in
  stamp) shift; command_stamp "$@" ;;
  json) shift; command_json "$@" ;;
  serve) shift; command_serve "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
