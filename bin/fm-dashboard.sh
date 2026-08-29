#!/usr/bin/env bash
# fm-dashboard.sh - local, observational control-plane dashboard.
#
# One read-only view of everything this firstmate home knows about its own
# agent activity: workers and secondmates, backlog and captain holds, status
# and wake events, durable scout reports, recorded delivery evidence, and the
# local model and startup-memory records.
#
# NOT A CONTROL PLANE. The dashboard renders evidence and never acts: it
# spawns nothing, steers nothing, merges nothing, tears down nothing, and
# acknowledges no wake. Firstmate remains the only prompt and control-plane
# interface, so every command the page shows is displayed as copyable text for
# a human to run, never wired to a control.
#
# Authority. This command is a RENDERER, not a second parser of fleet state.
# Fleet truth comes verbatim from `bin/fm-fleet-snapshot.sh --local-only --json`
# (schema `fm-fleet-snapshot.v1`) and is embedded unchanged. Supervision health
# comes from `fm-wake-lib.sh`'s `fm_watcher_supervision_verdict`, status-line
# verbs and notes from `fm-classify-lib.sh`, and the token estimate from
# `bin/fm-startup-memory-budget.sh report`. What this command adds is only the
# bounded presentation evidence the canonical snapshot deliberately does not
# project: status-log tails, queued wake records, and report bodies - each read
# from a path the snapshot itself supplies.
#
# LOCAL-ONLY. Nothing here makes a network, GitHub, or authentication call.
# PR evidence is whatever was already recorded locally, so the page labels it
# as recorded rather than live, and never claims a live CI verdict.
#
# Reads are bounded, path-safe, and symlink-safe: a status log or report is
# read only when it is a regular file, is not itself a symlink, and resolves
# inside this home's state or data root. Anything refused is disclosed in the
# payload's `degraded[]` array and on the page, so a missing surface is never
# silently rendered as an empty one.
#
# Not read-only in exactly one respect, disclosed rather than hidden: sourcing
# `fm-wake-lib.sh` creates this home's `state/` directory when it is absent.
# Nothing else on any path writes to `data/`, `state/`, or `projects/`. The
# built page is written under `$FM_HOME/.dashboard/`, which is gitignored, with
# a 077 umask and mode 0600.
#
# Usage:
#   fm-dashboard.sh json                 print the fm-dashboard.v1 payload
#   fm-dashboard.sh build [--out <path>] build the page (`--out -` to stdout)
#   fm-dashboard.sh serve [--port <n>] [--owner-digest <hex>]
#                                        serve the page on 127.0.0.1 only
#   fm-dashboard.sh render <payload.json> [--out <path>]
#                                        rebuild the page from a saved payload
#   fm-dashboard.sh path                 print this home's stable page path
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
#   FM_DASHBOARD_PORT          default serve port (default 8787)
# FM_DASHBOARD_TEMPLATE overrides the shipped template path (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

TEMPLATE="${FM_DASHBOARD_TEMPLATE:-$SCRIPT_DIR/../assets/dashboard-template.html}"
PLACEHOLDER='__FM_DASHBOARD_DATA__'
DASH_SCHEMA=fm-dashboard.v1
SNAPSHOT_SCHEMA=fm-fleet-snapshot.v1

FM_DASHBOARD_EVENT_LINES=${FM_DASHBOARD_EVENT_LINES:-40}
FM_DASHBOARD_WAKES=${FM_DASHBOARD_WAKES:-50}
FM_DASHBOARD_REPORTS=${FM_DASHBOARD_REPORTS:-40}
FM_DASHBOARD_REPORT_BYTES=${FM_DASHBOARD_REPORT_BYTES:-65536}
FM_DASHBOARD_PORT=${FM_DASHBOARD_PORT:-8787}

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
  jq -e '
    def has_type($o; $k; $t): ($o | has($k)) and ($o[$k] | type == $t);
    def has_nullable($o; $k; $t): ($o | has($k)) and (($o[$k] == null) or ($o[$k] | type == $t));
    def path_ref($v):
      ($v | type == "object" and has_nullable(.; "path"; "string")
       and has_type(.; "present"; "boolean"));
    def decision:
      type == "object" and has_type(.; "key"; "string") and has_type(.; "verb"; "string")
      and has_type(.; "summary"; "string");
    def backlog_record:
      type == "object" and has_type(.; "state"; "string") and has_type(.; "structured"; "boolean")
      and has_nullable(.; "id"; "string") and has_nullable(.; "title"; "string")
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
      and (if .structured then has_type(.; "captain_actionable"; "boolean")
           and has_type(.; "deferred_marker"; "boolean")
           and has_type(.; "current_role"; "string")
           and has_type(.; "requires_child_metadata"; "boolean")
           else true end);
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
      and has_type(.; "total"; "number") and has_type(.; "shown"; "number")
      and has_type(.; "truncated"; "number") and has_type(.; "lines"; "array")
      and all(.lines[]; type == "object" and has_type(.; "verb"; "string")
        and has_type(.; "note"; "string") and has_type(.; "raw"; "string"));
    def report:
      type == "object" and has_type(.; "id"; "string") and has_type(.; "path"; "string")
      and has_type(.; "readable"; "boolean") and has_nullable(.; "reason"; "string")
      and has_type(.; "bytes"; "number") and has_type(.; "truncated"; "boolean")
      and has_nullable(.; "modified"; "string") and has_type(.; "body"; "string");
    def wake:
      type == "object" and has_nullable(.; "epoch"; "number") and has_nullable(.; "seq"; "string")
      and has_nullable(.; "kind"; "string") and has_nullable(.; "key"; "string")
      and has_type(.; "payload"; "string") and has_type(.; "malformed"; "boolean");
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
      and all(.main_inventory.orphan_in_flight[]; type == "string");
    (.schema == "fm-dashboard.v1")
    and ((.generated | type) == "string")
    and ((.fm_home | type) == "string")
    and (.snapshot | snapshot)
    and ((.supervision | type) == "object")
    and has_type(.supervision; "model"; "string") and has_type(.supervision; "healthy"; "boolean")
    and has_type(.supervision; "reason"; "string") and has_type(.supervision; "beacon_present"; "boolean")
    and has_nullable(.supervision; "beacon_age_seconds"; "number")
    and has_type(.supervision; "away_mode"; "boolean") and has_type(.supervision; "recovery_marker"; "boolean")
    and has_type(.supervision; "wakes"; "object")
    and has_type(.supervision.wakes; "total"; "number")
    and has_type(.supervision.wakes; "shown"; "number")
    and has_type(.supervision.wakes; "truncated"; "number")
    and has_type(.supervision.wakes; "available"; "boolean")
    and has_nullable(.supervision.wakes; "reason"; "string")
    and has_type(.supervision.wakes; "records"; "array")
    and all(.supervision.wakes.records[]; wake)
    and has_type(.; "events"; "array") and all(.events[]; event)
    and has_type(.; "reports"; "object")
    and has_type(.reports; "total"; "number") and has_type(.reports; "shown"; "number")
    and has_type(.reports; "truncated"; "number") and has_type(.reports; "records"; "array")
    and all(.reports.records[]; report)
    and has_type(.; "usage"; "object") and has_type(.usage; "budget"; "object")
    and has_type(.usage.budget; "available"; "boolean") and has_nullable(.usage.budget; "reason"; "string")
    and has_nullable(.usage.budget; "effective_budget_tokens"; "number")
    and has_nullable(.usage.budget; "total_estimated_tokens"; "number")
    and has_nullable(.usage.budget; "status"; "string") and has_type(.usage.budget; "files"; "array")
    and all(.usage.budget.files[]; type == "object" and has_type(.; "file"; "string")
      and has_nullable(.; "bytes"; "number") and has_nullable(.; "estimated_tokens"; "number")
      and has_type(.; "status"; "string"))
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
    (.schema == "fm-fleet-snapshot.v1")
    and ((.generated | type) == "string")
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
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"  # fm_watcher_supervision_verdict, fm_path_age

TMP=
cleanup() { [ -n "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT INT TERM

make_tmp() {
  [ -n "$TMP" ] && return 0
  TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX") \
    || fail "cannot create a working directory"
}

dashboard_path() { printf '%s/.dashboard/control-plane.html\n' "$FM_HOME"; }

# --- bounded, path-safe, symlink-safe reads -------------------------------
# A file is readable evidence only when it is a regular file, is not itself a
# symlink, and resolves inside one of this home's evidence roots. An
# intermediate symlinked directory is allowed only while it still resolves
# inside those roots, which is what `pwd -P` decides.

DASH_REASON=
DASH_REAL=
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

safe_file() {  # <path> -> 0 with DASH_REAL set, else 1 with DASH_REASON set
  local p=$1 dir base real
  DASH_REASON=
  DASH_REAL=
  case "$p" in
    ''|-) DASH_REASON='no recorded path'; return 1 ;;
  esac
  if [ -L "$p" ]; then DASH_REASON='refused: the path is a symlink'; return 1; fi
  if [ ! -e "$p" ]; then DASH_REASON='not present'; return 1; fi
  if [ ! -f "$p" ]; then DASH_REASON='refused: not a regular file'; return 1; fi
  dir=${p%/*}
  [ "$dir" = "$p" ] && dir=.
  base=${p##*/}
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    DASH_REASON='refused: the directory could not be resolved'; return 1; }
  real="$real/$base"
  if ! inside_roots "$real"; then
    DASH_REASON='refused: resolves outside this home'
    return 1
  fi
  if [ ! -r "$real" ]; then DASH_REASON='not readable'; return 1; fi
  DASH_REAL=$real
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

DASH_BYTES=0
DASH_TRUNCATED=false
read_bounded() {  # <resolved-path> <max-bytes> <out-file>
  local size
  DASH_BYTES=0
  DASH_TRUNCATED=false
  size=$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  head -c "$2" "$1" 2>/dev/null | LC_ALL=C tr -d '\000' > "$3" || return 1
  DASH_BYTES=$size
  [ "$size" -gt "$2" ] && DASH_TRUNCATED=true
  return 0
}

DEGRADED=
note_degraded() {  # <source> <path> <reason>
  jq -cn --arg source "$1" --arg path "$2" --arg reason "$3" \
    '{source:$source,path:$path,reason:$reason}' >> "$DEGRADED"
}

# --- collectors -----------------------------------------------------------

collect_supervision() {  # -> JSON object on stdout
  local verdict_ok reason model age away recovery beat present lock marker
  model=$(fm_supervision_model)
  lock="$STATE/.watch.lock"
  if state_entry_safe "$lock" \
    && state_entry_safe "$lock/pid" \
    && state_entry_safe "$lock/fm-home" \
    && state_entry_safe "$lock/watcher-path" \
    && state_entry_safe "$lock/pid-identity" \
    && state_entry_safe "$STATE/.last-watcher-beat"; then
    fm_watcher_supervision_verdict "$STATE" "$lock" >/dev/null 2>&1
    verdict_ok=${FM_WATCHER_VERDICT_OK:-false}
    reason=${FM_WATCHER_VERDICT_REASON:-unknown}
    [ "$verdict_ok" = true ] && reason=ok
  else
    verdict_ok=false
    reason="unsafe supervision source: $DASH_REASON"
    note_degraded supervision "$lock" "$reason"
  fi
  beat="$STATE/.last-watcher-beat"
  # fm_path_age answers 999999 for a file it cannot stat, so an absent beacon is
  # reported as absent rather than as an implausible age.
  if [ -e "$beat" ] && safe_file "$beat"; then
    present=true
    age=$(fm_path_age "$DASH_REAL" 2>/dev/null)
    case "$age" in ''|*[!0-9]*) age=null ;; esac
  elif [ -e "$beat" ] || [ -L "$beat" ]; then
    present=false
    age=null
    note_degraded 'watcher heartbeat' "$beat" "$DASH_REASON"
  else
    present=false
    age=null
  fi
  away=false
  marker="$STATE/.afk"
  if state_entry_safe "$marker"; then
    [ -e "$marker" ] && away=true
  else
    note_degraded 'away marker' "$marker" "$DASH_REASON"
  fi
  recovery=false
  marker="$STATE/.watcher-down"
  if state_entry_safe "$marker"; then
    [ -e "$marker" ] && recovery=true
  else
    note_degraded 'recovery marker' "$marker" "$DASH_REASON"
  fi
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
  if [ ! -e "$queue" ]; then
    jq -n '{records:[], total:0, shown:0, truncated:0, available:true, reason:"no queued notifications"}'
    return 0
  fi
  if ! safe_file "$queue"; then
    note_degraded 'wake queue' "$queue" "$DASH_REASON"
    jq -n --arg reason "$DASH_REASON" \
      '{records:[], total:0, shown:0, truncated:0, available:false, reason:$reason}'
    return 0
  fi
  total=$(wc -l < "$DASH_REAL" 2>/dev/null | tr -d '[:space:]')
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  tail -n "$FM_DASHBOARD_WAKES" "$DASH_REAL" 2>/dev/null > "$tail_file" || : > "$tail_file"
  # Fields are tab-separated and each was sanitized of tabs by the queue writer
  # (fm-wake-lib.sh's fm_wake_clean_field), so a record that does not split into
  # five fields is a hand-edited or torn line and is surfaced as malformed
  # rather than parsed into the wrong columns.
  jq -Rn --argjson total "$total" --argjson shown_cap "$FM_DASHBOARD_WAKES" '
    [inputs
      | select(length > 0)
      | split("\t")
      | if length == 5 and (.[0] | test("^[0-9]+$"))
        then {epoch:(.[0]|tonumber), seq:.[1], kind:.[2], key:.[3], payload:.[4], malformed:false}
        else {epoch:null, seq:null, kind:null, key:null, payload:(. | join("\t")), malformed:true}
        end] as $records
    | {records:$records, total:$total, shown:($records|length),
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
    if ! safe_file "$path"; then
      if [ "$DASH_REASON" != 'not present' ] && [ "$DASH_REASON" != 'no recorded path' ]; then
        note_degraded "status log for $id" "$path" "$DASH_REASON"
      fi
      jq -cn --arg id "$id" --arg path "$path" --arg reason "$DASH_REASON" \
        '{task_id:$id, path:$path, readable:false, reason:$reason,
          total:0, shown:0, truncated:0, lines:[]}' >> "$out"
      continue
    fi
    total=$(wc -l < "$DASH_REAL" 2>/dev/null | tr -d '[:space:]')
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    tail -n "$FM_DASHBOARD_EVENT_LINES" "$DASH_REAL" 2>/dev/null > "$tail_file" \
      || : > "$tail_file"
    : > "$triples"
    while IFS= read -r line; do
      verb=$(status_line_verb "$line")
      note=$(status_line_note "$line")
      printf '%s\n%s\n%s\n' "$verb" "$note" "$line" >> "$triples"
    done < "$tail_file"
    jq -cRn --arg id "$id" --arg path "$DASH_REAL" \
      --argjson total "$total" --argjson cap "$FM_DASHBOARD_EVENT_LINES" '
      [inputs] as $l
      | [range(0; ($l | length) / 3 | floor)
         | {verb:$l[. * 3], note:$l[. * 3 + 1], raw:$l[. * 3 + 2]}] as $lines
      | {task_id:$id, path:$path, readable:true, reason:null,
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
  local id path total kept=0 body="$TMP/report.md" out="$TMP/reports.jsonl"
  local modified truncated bytes
  : > "$out"
  total=0
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] || continue
    total=$((total + 1))
    if [ "$kept" -ge "$FM_DASHBOARD_REPORTS" ]; then
      continue
    fi
    kept=$((kept + 1))
    if ! safe_file "$path"; then
      note_degraded "report for $id" "$path" "$DASH_REASON"
      jq -cn --arg id "$id" --arg path "$path" --arg reason "$DASH_REASON" \
        '{id:$id, path:$path, readable:false, reason:$reason,
          bytes:0, truncated:false, modified:null, body:""}' >> "$out"
      continue
    fi
    if ! read_bounded "$DASH_REAL" "$FM_DASHBOARD_REPORT_BYTES" "$body"; then
      note_degraded "report for $id" "$path" 'could not be read'
      jq -cn --arg id "$id" --arg path "$DASH_REAL" \
        '{id:$id, path:$path, readable:false, reason:"could not be read",
          bytes:0, truncated:false, modified:null, body:""}' >> "$out"
      continue
    fi
    bytes=$DASH_BYTES
    truncated=$DASH_TRUNCATED
    modified=$(file_mtime_iso "$DASH_REAL")
    jq -cn --arg id "$id" --arg path "$DASH_REAL" --arg modified "$modified" \
      --argjson bytes "$bytes" --argjson truncated "$truncated" \
      --rawfile body "$body" \
      '{id:$id, path:$path, readable:true, reason:null,
        bytes:$bytes, truncated:$truncated,
        modified:(if $modified == "" then null else $modified end),
        body:$body}' >> "$out"
  done <<EOF
$(jq -r '.scout_reports[] | [.id, .path] | @tsv' "$1")
EOF
  jq -s --argjson total "$total" --argjson cap "$FM_DASHBOARD_REPORTS" \
    '{records:., total:$total, shown:(.|length),
      truncated:(if $total > $cap then $total - $cap else 0 end)}' "$out"
}

file_mtime_iso() {  # <path>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$(stat -c %Y "$1" 2>/dev/null)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf ''
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

compose() {  # -> the fm-dashboard.v1 payload on stdout
  local snapshot="$TMP/snapshot.json" generated
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -x "$SCRIPT_DIR/fm-fleet-snapshot.sh" ] || fail "bin/fm-fleet-snapshot.sh is missing"
  DEGRADED="$TMP/degraded.jsonl"
  : > "$DEGRADED"
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --local-only --json > "$snapshot" \
    || fail "the fleet snapshot failed, so there is nothing trustworthy to render"
  snapshot_is_valid "$snapshot" \
    || fail "the fleet snapshot did not return a $SNAPSHOT_SCHEMA document"
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg schema "$DASH_SCHEMA" \
    --arg generated "$generated" \
    --arg fm_home "$FM_HOME" \
    --slurpfile snapshot "$snapshot" \
    --argjson supervision "$(collect_supervision)" \
    --argjson events "$(collect_events "$snapshot")" \
    --argjson reports "$(collect_reports "$snapshot")" \
    --argjson usage "$(collect_usage "$snapshot")" \
    --slurpfile degraded "$DEGRADED" \
    '{schema:$schema, generated:$generated, fm_home:$fm_home,
      snapshot:$snapshot[0], supervision:$supervision, events:$events,
      reports:$reports, usage:$usage, degraded:$degraded}'
}

# --- commands -------------------------------------------------------------

command_json() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  make_tmp
  compose
}

build_html() {  # <out-file>
  local out=$1 data="$TMP/payload.json"
  compose > "$data" || exit 1
  payload_is_valid "$data" || fail "the composed dashboard payload is incomplete or unusable"
  inject_payload "$data" "$out"
}

OUTPUT_PARENT_REASON=
output_parent_safe() {  # <out-file>
  local out=$1 parent candidate anchor resolved home_real
  OUTPUT_PARENT_REASON=
  parent=${out%/*}
  [ "$parent" = "$out" ] && parent=.
  case "$parent" in
    /*) candidate=$parent ;;
    *) candidate="$PWD/$parent" ;;
  esac
  anchor=$candidate
  while [ ! -e "$anchor" ] && [ ! -L "$anchor" ]; do
    case "$anchor" in
      ''|/) OUTPUT_PARENT_REASON='the parent path could not be resolved'; return 1 ;;
    esac
    anchor=${anchor%/*}
    [ -n "$anchor" ] || anchor=/
  done
  [ ! -L "$anchor" ] || {
    OUTPUT_PARENT_REASON='an existing parent component is a symlink'
    return 1
  }
  [ -d "$anchor" ] || {
    OUTPUT_PARENT_REASON='an existing parent component is not a directory'
    return 1
  }
  resolved=$(cd "$anchor" 2>/dev/null && pwd -P) || {
    OUTPUT_PARENT_REASON='the parent could not be resolved'
    return 1
  }
  home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || {
    OUTPUT_PARENT_REASON='this home could not be resolved'
    return 1
  }
  case "$resolved" in
    "$home_real"|"$home_real"/*) ;;
    *) OUTPUT_PARENT_REASON='the parent resolves outside this home'; return 1 ;;
  esac
  mkdir -p "$candidate" || {
    OUTPUT_PARENT_REASON='the parent could not be created'
    return 1
  }
  [ ! -L "$candidate" ] && [ -d "$candidate" ] || {
    OUTPUT_PARENT_REASON='the output parent is not a directory'
    return 1
  }
  resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || {
    OUTPUT_PARENT_REASON='the created parent could not be resolved'
    return 1
  }
  case "$resolved" in
    "$home_real"|"$home_real"/*) return 0 ;;
    *) OUTPUT_PARENT_REASON='the parent resolves outside this home'; return 1 ;;
  esac
}

inject_payload() {  # <payload-file> <out-file>
  local data=$1 out=$2 json="$TMP/payload.slot" tmp extracted slot
  payload_is_valid "$data" || fail "the payload is incomplete or unusable: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "the page template is missing: $TEMPLATE"
  slot=$(grep -nxF "$PLACEHOLDER" "$TEMPLATE" | cut -d: -f1)
  case "$slot" in
    *[!0-9]*|'') fail "the page template does not carry exactly one data slot: $TEMPLATE" ;;
  esac
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  # The escape and the splice both run in tools rather than in bash string
  # expansion, which is quadratic on a payload this size.
  jq -c . "$data" | LC_ALL=C sed 's/</\\u003c/g' > "$json" \
    || fail "cannot compact the dashboard data"
  tmp=$(umask 077; mktemp "$TMP/page.XXXXXX") || fail "cannot stage the page"
  {
    sed -n "1,$((slot - 1))p" "$TEMPLATE" \
      && cat "$json" \
      && sed -n "$((slot + 1)),\$p" "$TEMPLATE"
  } > "$tmp" || fail "cannot inject the dashboard data"
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    fail "the dashboard data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a page that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="fm-dashboard-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  printf '%s\n' "$extracted" > "$TMP/extracted.json"
  payload_is_valid "$TMP/extracted.json" \
    || fail "the built page does not carry a complete readable $DASH_SCHEMA payload"
  if [ "$out" = "-" ]; then
    cat "$tmp"
    return 0
  fi
  output_parent_safe "$out" || fail "the output parent is not a safe directory inside this home: $OUTPUT_PARENT_REASON"
  if ! chmod 0600 "$tmp"; then
    fail "cannot make the page private before publishing it"
  fi
  if ! mv -f -- "$tmp" "$out"; then
    fail "cannot publish the page"
  fi
  return 0
}

command_build() {
  local out
  out=$(dashboard_path)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) shift; [ "$#" -gt 0 ] || fail "--out needs a path"; out=$1; shift ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  make_tmp
  build_html "$out"
  [ "$out" = "-" ] || printf 'dashboard: %s\n' "$out"
}

command_render() {
  local data=${1-} out
  out=$(dashboard_path)
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) shift; [ "$#" -gt 0 ] || fail "--out needs a path"; out=$1; shift ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] && [ ! -L "$data" ] || fail "the payload file does not exist: $data"
  payload_is_valid "$data" \
    || fail "the payload is not a complete readable $DASH_SCHEMA document: $data"
  make_tmp
  inject_payload "$data" "$out"
  [ "$out" = "-" ] || printf 'dashboard: %s\n' "$out"
}

command_serve() {
  local port=$FM_DASHBOARD_PORT digest=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) shift; [ "$#" -gt 0 ] || fail "--port needs a number"; port=$1; shift ;;
      --owner-digest)
        shift
        [ "$#" -gt 0 ] || fail "--owner-digest needs a value"
        digest=$1
        shift
        ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$digest" in
    '') ;;
    *[!0-9a-f]*) fail "--owner-digest must be lowercase hex" ;;
  esac
  case "$port" in
    ''|*[!0-9]*) fail "--port must be a number: $port" ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail "--port must be 1-65535: $port"
  command -v python3 >/dev/null 2>&1 \
    || fail "serve needs python3; build the page instead and open it directly"
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
  [ -n "${FM_DASHBOARD_TEMPLATE:-}" ] && export FM_DASHBOARD_TEMPLATE
  export FM_DASHBOARD_EVENT_LINES FM_DASHBOARD_WAKES
  export FM_DASHBOARD_REPORTS FM_DASHBOARD_REPORT_BYTES
  # Prove the page builds before binding a port, so serve fails closed at
  # startup rather than answering its first request with an error.
  build_html - >/dev/null || exit 1
  printf 'serving: http://127.0.0.1:%s/ (local only; Ctrl-C to stop)\n' "$port"
  FM_DASHBOARD_SELF="$SCRIPT_DIR/fm-dashboard.sh" FM_DASHBOARD_BIND_PORT="$port" \
    FM_DASHBOARD_OWNER_DIGEST="$digest" FM_DASHBOARD_HEALTH_HOME="$FM_HOME" \
    python3 - <<'PY'
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SELF = os.environ["FM_DASHBOARD_SELF"]
PORT = int(os.environ["FM_DASHBOARD_BIND_PORT"])
HTTP_IO_TIMEOUT = 5
# Only the DIGEST of the owner token reaches this process, and only the digest
# is ever published. A caller proves it started this exact server for this
# exact home by hashing the token it holds privately and comparing; the token
# itself never travels over the socket or through this process's environment.
OWNER_DIGEST = os.environ.get("FM_DASHBOARD_OWNER_DIGEST", "")
HEALTH_HOME = os.environ.get("FM_DASHBOARD_HEALTH_HOME", "")
HEALTH = json.dumps({
    "schema": "fm-dashboard-health.v1",
    "home": HEALTH_HOME,
    "owner": OWNER_DIGEST,
    "ready": True,
}).encode() + b"\n"


class Handler(BaseHTTPRequestHandler):
    server_version = "fm-dashboard"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(HTTP_IO_TIMEOUT)

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            self.close_connection = True

    def do_GET(self):
        # One page and one liveness probe. Every other path is refused: this
        # server never serves a file from disk and has no directory route.
        if self.path == "/healthz":
            self._send(200, HEALTH, "application/json; charset=utf-8")
            return
        if self.path not in ("/", "/index.html"):
            self._send(404, b"not found\n", "text/plain; charset=utf-8")
            return
        try:
            done = subprocess.run(
                [SELF, "build", "--out", "-"],
                capture_output=True, timeout=120,
            )
        except Exception as exc:  # noqa: BLE001 - reported, never swallowed
            self._send(500, ("the dashboard could not be rebuilt: %s\n" % exc).encode(),
                       "text/plain; charset=utf-8")
            return
        if done.returncode != 0 or not done.stdout:
            detail = done.stderr.decode("utf-8", "replace").strip() or "no detail"
            self._send(500, ("the dashboard could not be rebuilt: %s\n" % detail).encode(),
                       "text/plain; charset=utf-8")
            return
        self._send(200, done.stdout, "text/html; charset=utf-8")

    def log_message(self, fmt, *args):
        sys.stderr.write("fm-dashboard: %s\n" % (fmt % args))


# Loopback only. Binding 127.0.0.1 rather than 0.0.0.0 is the whole
# local-only guarantee, so it is not configurable.
with HTTPServer(("127.0.0.1", PORT), Handler) as httpd:
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
PY
}

case "${1-}" in
  json) shift; command_json "$@" ;;
  build) shift; command_build "$@" ;;
  render) shift; command_render "$@" ;;
  serve) shift; command_serve "$@" ;;
  path) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; dashboard_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
