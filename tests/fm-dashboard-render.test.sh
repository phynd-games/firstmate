#!/usr/bin/env bash
# Behavior tests for the shipped control-plane dashboard renderer
# (assets/dashboard-template.html), exercised through a real
# `fm-dashboard.sh render` and then executed under the minimal DOM shim in
# tests/assets/dashboard-render-harness.mjs. Every assertion is on what the
# page renders - badges, notices, rows, the report reader - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
HARNESS="$ROOT/tests/assets/dashboard-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# One fresh home per case. A counter would not work here: the call site is
# `home=$(new_case)`, whose subshell throws away any variable this function
# sets, so the uniqueness has to come from the filesystem.
new_case() {
  mktemp -d "$TMP_ROOT/case.XXXXXX" || fail "could not create a fixture home"
}

# payload <home> <overrides-json> - a minimal valid fm-dashboard.v1 document
# with <overrides-json> merged over it, written to <home>/payload.json.
payload() {
  local home=$1 overrides=$2 file="$1/payload.json"
  jq -n --argjson overrides "$overrides" '
    {
      schema: "fm-dashboard.v1",
      generated: "2026-08-01T00:10:00Z",
      fm_home: "/homes/sample",
      snapshot: {
        schema: "fm-fleet-snapshot.v1",
        generated: "2026-08-01T00:10:00Z",
        fm_home: "/homes/sample",
        roots: {state: "/homes/sample/state", data: "/homes/sample/data",
                config: "/homes/sample/config", projects: "/homes/sample/projects"},
        backlog: {path: "/homes/sample/data/backlog.md", present: true, records: []},
        tasks: [],
        scout_reports: [],
        main_inventory: {valid: true, reason: null, orphan_in_flight: []}
      },
      supervision: {
        model: "autoarm", healthy: true, reason: "ok",
        beacon_present: true, beacon_age_seconds: 12,
        away_mode: false, recovery_marker: false,
        wakes: {records: [], total: 0, shown: 0, truncated: 0, available: true, reason: null}
      },
      events: [],
      reports: {records: [], total: 0, shown: 0, truncated: 0},
      usage: {budget: {available: true, reason: null, effective_budget_tokens: 7500,
                       total_estimated_tokens: 100, status: "within-budget", files: []},
              agents: []},
      degraded: []
    } * $overrides' > "$file" || fail "the fixture payload could not be composed"
  printf '%s\n' "$file"
}

render() {  # <home> <payload-file> [harness-args...]
  local home=$1 file=$2
  shift 2
  FM_HOME="$home" "$DASH" render "$file" --out "$home/page.html" >/dev/null \
    || fail "the page could not be rendered"
  node "$HARNESS" "$home/page.html" "$@" \
    || fail "the rendered page could not be executed"
}

# A worker record shaped like the canonical snapshot's task row.
task_json() {  # <id> <state> [extra-json]
  local extra=${3:-}
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg id "$1" --arg state "$2" --argjson extra "$extra" '
    {id: $id, kind: "ship", harness: "claude", model: "opus", effort: "xhigh",
     mode: "no-mistakes", yolo: "off", project: "/homes/sample/projects/sample",
     spawn_gen: null, backend: "tmux", remote: null,
     paths: {meta: {path: "/homes/sample/state/\($id).meta", present: true},
             status_log: {path: "/homes/sample/state/\($id).status", present: true,
                          kind: "event_history", last_event: {state: "", note: "", raw: ""}},
             worktree: {path: "/homes/sample/wt", present: true},
             home: {path: null, present: false},
             report: {path: null, present: false}},
     current_state: {state: $state, source: "run-step", detail: "validating (running)",
                     raw: "", observed_at: "2026-08-01T00:09:00Z", freshness: "fresh"},
     endpoint: {target: "firstmate:fm-\($id)", exists: true, agent_alive: "not_checked",
                status: "unknown", observed_at: "2026-08-01T00:09:00Z", freshness: "fresh"},
     pr: {url: null, source: "absent"},
     hints: {pending_decision: false, blocked_event: false, open_decisions: [],
             scout_report_present: false, last_event_text: ""},
     actions: {watch: "bin/fm-peek.sh fm-\($id)", steer: "bin/fm-send.sh fm-\($id) <instruction>",
               return_channel_note: null},
     backlog: null} * $extra'
}

test_a_healthy_fleet_renders_its_counts_and_sections() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" "$(jq -cn --argjson t "$(task_json worker-one working)" '
    {snapshot: {tasks: [$t]},
     reports: {records: [], total: 3, shown: 0, truncated: 3}}')")
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the page rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    ([.stats[] | select(.label == "workers") | .n] | first) == 1
    and ([.stats[] | select(.label == "reports") | .n] | first) == 3
    and ([.tabs[] | .label] | index("Workers")) == 0
    and (.tabs[0].active == true)
    and (.workers | length) == 1
    and .workers[0].id == "worker-one"' >/dev/null \
    || fail "the fleet counts or sections did not render: $out"
  pass "a healthy fleet renders its counts and its sections"
}

test_reconciled_state_is_labelled_apart_from_event_history() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" "$(jq -cn --argjson t "$(task_json worker-one working)" '
    {snapshot: {tasks: [$t]},
     events: [{task_id: "worker-one", path: "/homes/sample/state/worker-one.status",
               readable: true, reason: null, total: 3, shown: 2, truncated: 1,
               lines: [{verb: "working", note: "first", raw: "working: first"},
                       {verb: "done", note: "second", raw: "done: second"}]}]}')")
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    (.workers[0].state.value | test("working"))
    and (.workers[0].state.details | join(" ") | test("validating"))
    and (.workers[0].foldSummaries | join(" ") | test("Event history \\(2 of 3\\)"))
    and (.workers[0].events | length) == 2
    and .workers[0].events[0].verb == "done"
    and .workers[0].events[1].verb == "working"
    and (.workers[0].eventNotes | join(" ") | test("1 older events not shown"))
    and (.workers[0].eventNotes | join(" ") | test("worker-one.status"))' >/dev/null \
    || fail "reconciled state and event history were not kept apart: $out"
  pass "reconciled current state renders apart from newest-first event history"
}

test_a_worker_whose_event_log_was_refused_says_why() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" "$(jq -cn --argjson t "$(task_json worker-one working)" '
    {snapshot: {tasks: [$t]},
     events: [{task_id: "worker-one", path: "/homes/sample/state/worker-one.status",
               readable: false, reason: "refused: the path is a symlink",
               total: 0, shown: 0, truncated: 0, lines: []}],
     degraded: [{source: "status log for worker-one",
                 path: "/homes/sample/state/worker-one.status",
                 reason: "refused: the path is a symlink"}]}')")
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    (.workers[0].eventNotes | join(" ") | test("symlink"))
    and ([.notices[] | select(.title | test("Evidence not shown"))] | length) == 1
    and ([.stats[] | select(.label == "evidence gaps") | .n] | first) == 1' >/dev/null \
    || fail "a refused event log was not surfaced as a named gap: $out"
  pass "a worker whose event log was refused says why, and the gap is counted"
}

test_unconfirmed_supervision_is_reported_without_claiming_a_repair() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" '{"supervision": {"healthy": false, "reason": "no-watcher",
    "beacon_present": false, "beacon_age_seconds": null, "away_mode": true}}')
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    ([.notices[] | select(.title | test("Supervision is not confirmed"))] | length) == 1
    and ([.notices[] | select(.title | test("Supervision")) | .detail] | first
      | test("no-watcher") and test("never recorded"))
    and ([.notices[] | select(.title | test("Away mode"))] | length) == 1
    and ([.navMeta[] | select(test("no monitor running"))] | length) == 1' >/dev/null \
    || fail "unconfirmed supervision was not reported plainly: $out"
  pass "unconfirmed supervision is reported plainly without claiming a repair"
}

test_captain_calls_carry_the_decision_summary_the_snapshot_recorded() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" "$(jq -cn --argjson t "$(task_json worker-one blocked '
    {"hints": {"pending_decision": true, "blocked_event": true,
      "open_decisions": [{"key": "pick-one", "verb": "needs-decision",
        "summary": "two provenance options remain"}],
      "scout_report_present": false, "last_event_text": ""}}')" '
    {snapshot: {tasks: [$t]}}')")
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    (.calls | length) == 1
    and (.calls[0].title == "two provenance options remain")
    and (.calls[0].sub | test("worker-one") and test("pick-one"))
    and (.calls[0].badges[0].tone == "danger")
    and ([.stats[] | select(.label == "captain'"'"'s calls") | .n] | first) == 1' >/dev/null \
    || fail "an open captain's call did not render its recorded summary: $out"
  pass "a captain's call renders the decision summary the snapshot recorded"
}

test_recorded_delivery_evidence_is_not_presented_as_a_live_check() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" "$(jq -cn --argjson t "$(task_json worker-one working '
    {"pr": {"url": "https://example.invalid/pr/7", "source": "status_event"}}')" '
    {snapshot: {tasks: [$t]}}')")
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    ([.delivery[] | select(.[0] == "worker-one")] | length) == 1
    and ([.delivery[] | select(.[0] == "worker-one") | .[1]] | first
      | test("example.invalid/pr/7"))
    and ([.delivery[] | select(.[0] == "worker-one") | .[2]] | first) == "status_event"
    and (.workers[0].kv | map(select(.[0] == "pr")) | .[0][1] | test("not a live check"))
    and (.deliveryHrefs | index("https://example.invalid/pr/7")) != null
    and (.workerHrefs | index("https://example.invalid/pr/7")) != null' \
    >/dev/null || fail "recorded delivery evidence was presented as more than it is: $out"
  pass "recorded delivery evidence is labelled as recorded, never as a live check"
}

test_a_malformed_queued_notification_renders_as_unreadable() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" '{"supervision": {"wakes": {"total": 2, "shown": 2, "truncated": 0,
    "available": true, "reason": null, "records": [
      {"epoch": 1750000000, "seq": "7", "kind": "check", "key": "worker-one",
       "payload": "PR merged", "malformed": false},
      {"epoch": null, "seq": null, "kind": null, "key": null,
       "payload": "hand edited line", "malformed": true}]}}}')
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    ([.wakes[] | select(.[4] == "PR merged")] | length) == 1
    and ([.wakes[] | select(.[4] == "hand edited line") | .[2]] | first) == "unreadable"' \
    >/dev/null || fail "a malformed queued notification did not render as unreadable: $out"
  pass "a malformed queued notification renders as unreadable rather than as data"
}

test_a_report_renders_as_text_and_never_as_executable_html() {
  local home file out body
  home=$(new_case)
  body='# Findings

A <script>alert(1)</script> tag and an <img src=x onerror=alert(2)> tag.

An [evil link](javascript:alert(3)) and a [good link](https://example.invalid/ok).

| finding | severity |
| ------- | -------- |
| one     | P1       |

```
raw </script> inside a fence
```

- first
- second
'
  file=$(payload "$home" "$(jq -cn --arg body "$body" '
    {reports: {total: 1, shown: 1, truncated: 0, records: [
      {id: "scout-one", path: "/homes/sample/data/scout-one/report.md",
       readable: true, reason: null, bytes: 400, truncated: false,
       modified: "2026-08-01T00:00:00Z", body: $body}]}}')")
  out=$(render "$home" "$file" --open-report scout-one)
  printf '%s' "$out" | jq -e '
    .drawer.open == true
    and .drawer.title == "scout-one"
    and .drawer.counts.script == 0
    and .drawer.counts.img == 0
    and .drawer.counts.iframe == 0' >/dev/null \
    || fail "a report body produced live markup instead of text: $out"
  printf '%s' "$out" | jq -e '
    (.drawer.text | test("alert\\(1\\)"))
    and (.drawer.text | test("onerror"))
    and (.drawer.text | test("raw </script> inside a fence"))' >/dev/null \
    || fail "the report text was dropped instead of being shown literally: $out"
  printf '%s' "$out" | jq -e '
    (.drawer.hrefs | length) == 1
    and .drawer.hrefs[0] == "https://example.invalid/ok"
    and (.drawer.text | test("evil link"))' >/dev/null \
    || fail "a javascript: link was turned into a live link: $out"
  printf '%s' "$out" | jq -e '
    .drawer.counts.table == 1
    and .drawer.counts.pre == 1
    and .drawer.counts.heading == 1
    and .drawer.counts.li == 2' >/dev/null \
    || fail "the report markdown structure did not render: $out"
  pass "a report renders as structured text and never as executable HTML"
}

# Two independent layers keep a non-http URL from becoming a live link: the
# markdown link pattern only matches an http(s) target, and externalLink
# re-checks the protocol for every link the page builds from payload fields
# that never pass through markdown at all. This case drives the second layer,
# which a report body cannot reach.
test_a_recorded_url_that_is_not_http_never_becomes_a_live_link() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" "$(jq -cn --argjson t "$(task_json worker-one working '
    {"pr": {"url": "javascript:alert(1)", "source": "status_event"}}')" '
    {snapshot: {tasks: [$t]}}')")
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    ([.delivery[] | select(.[0] == "worker-one") | .[1]] | first) == "javascript:alert(1)"
    and (.workers[0].kv | map(select(.[0] == "pr")) | .[0][1] | test("javascript:alert"))' \
    >/dev/null || fail "the recorded url was dropped instead of shown as plain text: $out"
  printf '%s' "$out" | jq -e '
    (.deliveryHrefs | length) == 0 and (.workerHrefs | length) == 0' >/dev/null \
    || fail "a non-http recorded url became a live link: $out"
  pass "a recorded url that is not http(s) renders as plain text, never as a live link"
}

test_a_truncated_report_says_so_in_its_reader() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" '{"reports": {"total": 1, "shown": 1, "truncated": 0, "records": [
    {"id": "scout-one", "path": "/homes/sample/data/scout-one/report.md",
     "readable": true, "reason": null, "bytes": 90000, "truncated": true,
     "modified": "2026-08-01T00:00:00Z", "body": "# partial\n"}]}}')
  out=$(render "$home" "$file" --open-report scout-one)
  printf '%s' "$out" | jq -e '
    (.drawer.text | test("Shown truncated"))
    and (.drawer.text | test("90000 bytes"))
    and ([.reports[] | .badges[] | .text] | index("truncated")) != null' >/dev/null \
    || fail "a truncated report did not disclose the truncation: $out"
  pass "a truncated report says so in its reader and in its row"
}

test_an_unreadable_report_reader_states_the_reason() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" '{"reports": {"total": 1, "shown": 1, "truncated": 0, "records": [
    {"id": "scout-one", "path": "/homes/sample/data/scout-one/report.md",
     "readable": false, "reason": "refused: the path is a symlink",
     "bytes": 0, "truncated": false, "modified": null, "body": ""}]}}')
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    ([.reports[] | .badges[] | .text] | index("unavailable")) != null
    and ([.reports[] | .sub] | first | test("symlink"))' >/dev/null \
    || fail "an unreadable report did not state why: $out"
  pass "an unreadable report states its reason instead of showing an empty reader"
}

test_the_report_filter_hides_only_what_does_not_match() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" '{"reports": {"total": 2, "shown": 2, "truncated": 0, "records": [
    {"id": "audit-alpha", "path": "/homes/sample/data/audit-alpha/report.md",
     "readable": true, "reason": null, "bytes": 10, "truncated": false,
     "modified": null, "body": "# a"},
    {"id": "design-beta", "path": "/homes/sample/data/design-beta/report.md",
     "readable": true, "reason": null, "bytes": 10, "truncated": false,
     "modified": null, "body": "# b"}]}}')
  out=$(render "$home" "$file" --filter design)
  printf '%s' "$out" | jq -e '
    ([.reports[] | select(.id == "audit-alpha") | .hidden] | first) == true
    and ([.reports[] | select(.id == "design-beta") | .hidden] | first) == false' >/dev/null \
    || fail "the report filter hid the wrong rows: $out"
  pass "the report filter hides only the rows that do not match"
}

test_escape_closes_the_report_reader() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" '{"reports": {"total": 1, "shown": 1, "truncated": 0, "records": [
    {"id": "scout-one", "path": "/homes/sample/data/scout-one/report.md",
     "readable": true, "reason": null, "bytes": 10, "truncated": false,
     "modified": null, "body": "# a"}]}}')
  out=$(render "$home" "$file" --open-report scout-one --press-escape)
  printf '%s' "$out" | jq -e '.drawer.open == false' >/dev/null \
    || fail "Escape did not close the report reader: $out"
  pass "Escape closes the report reader"
}

test_every_source_path_is_listed_for_checking() {
  local home file out
  home=$(new_case)
  file=$(payload "$home" '{"events": [{"task_id": "worker-one",
      "path": "/homes/sample/state/worker-one.status", "readable": true, "reason": null,
      "total": 1, "shown": 1, "truncated": 0,
      "lines": [{"verb": "working", "note": "go", "raw": "working: go"}]}],
    "reports": {"total": 1, "shown": 1, "truncated": 0, "records": [
      {"id": "scout-one", "path": "/homes/sample/data/scout-one/report.md",
       "readable": true, "reason": null, "bytes": 10, "truncated": false,
       "modified": null, "body": "# a"}]}}')
  out=$(render "$home" "$file")
  printf '%s' "$out" | jq -e '
    ([.sources[] | .[1]] | index("/homes/sample/state/worker-one.status")) != null
    and ([.sources[] | .[1]] | index("/homes/sample/data/scout-one/report.md")) != null
    and ([.sources[] | .[1]] | index("/homes/sample/data/backlog.md")) != null
    and (.provenance | test("fm-dashboard.v1") and test("fm-fleet-snapshot.v1")
      and test("no network call"))' >/dev/null \
    || fail "the exact sources were not listed for checking: $out"
  pass "every path the page read is listed so any claim can be checked at its source"
}

test_a_page_whose_data_is_corrupt_fails_closed() {
  local home file page line
  home=$(new_case)
  file=$(payload "$home" '{}')
  FM_HOME="$home" "$DASH" render "$file" --out "$home/page.html" >/dev/null \
    || fail "the page could not be rendered"
  page="$home/page.html"
  line=$(grep -n '<script id="fm-dashboard-data"' "$page" | cut -d: -f1)

  awk -v n=$((line + 1)) 'NR == n { print "{ not json"; next } { print }' "$page" \
    > "$home/broken.html"
  node "$HARNESS" "$home/broken.html" | jq -e '
    (.error | test("not readable JSON")) and (.stats | length) == 0' >/dev/null \
    || fail "a page with unreadable data did not fail closed"

  awk -v n=$((line + 1)) 'NR == n { print "{\"schema\":\"something-else\"}"; next } { print }' \
    "$page" > "$home/wrong.html"
  node "$HARNESS" "$home/wrong.html" | jq -e '
    (.error | test("fm-dashboard.v1")) and (.stats | length) == 0' >/dev/null \
    || fail "a page carrying the wrong schema did not fail closed"
  pass "a page whose data is corrupt or wrong-schema fails closed instead of reading as empty"
}

test_render_refuses_a_payload_that_is_not_a_dashboard_document() {
  local home out status=0
  home=$(new_case)
  printf '{"schema":"something-else"}\n' > "$home/wrong.json"
  out=$(FM_HOME="$home" "$DASH" render "$home/wrong.json" --out "$home/page.html" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "render accepted a payload that is not a dashboard document"
  assert_contains "$out" "fm-dashboard.v1" "the refusal did not name the required schema"
  [ ! -e "$home/page.html" ] || fail "a refused render still published a page"
  pass "render refuses a payload that is not a readable dashboard document"
}

test_render_refuses_a_dashboard_document_with_a_null_task() {
  local home file out status=0
  home=$(new_case)
  file=$(payload "$home" '{"snapshot":{"tasks":[null]}}')
  out=$(FM_HOME="$home" "$DASH" render "$file" --out "$home/page.html" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "render accepted a null task element"
  assert_contains "$out" "complete readable" "the refusal did not identify the malformed task"
  [ ! -e "$home/page.html" ] || fail "render published a page for a null task"
  pass "render refuses a dashboard document with a null task"
}

test_a_healthy_fleet_renders_its_counts_and_sections
test_reconciled_state_is_labelled_apart_from_event_history
test_a_worker_whose_event_log_was_refused_says_why
test_unconfirmed_supervision_is_reported_without_claiming_a_repair
test_captain_calls_carry_the_decision_summary_the_snapshot_recorded
test_recorded_delivery_evidence_is_not_presented_as_a_live_check
test_a_malformed_queued_notification_renders_as_unreadable
test_a_report_renders_as_text_and_never_as_executable_html
test_a_recorded_url_that_is_not_http_never_becomes_a_live_link
test_a_truncated_report_says_so_in_its_reader
test_an_unreadable_report_reader_states_the_reason
test_the_report_filter_hides_only_what_does_not_match
test_escape_closes_the_report_reader
test_every_source_path_is_listed_for_checking
test_a_page_whose_data_is_corrupt_fails_closed
test_render_refuses_a_payload_that_is_not_a_dashboard_document
test_render_refuses_a_dashboard_document_with_a_null_task
