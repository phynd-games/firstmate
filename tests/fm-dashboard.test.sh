#!/usr/bin/env bash
# Behavior tests for the read-only control-plane dashboard composer
# (bin/fm-dashboard.sh), exercised end to end against synthetic homes. Every
# assertion is on the command's own output contract - the fm-dashboard.v1
# payload and the built page - never on the script's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

containment_available() {
  [ "$(uname -s)" = Linux ] || return 1
  command -v unshare >/dev/null 2>&1 || return 1
  unshare --pid --fork --mount-proc --kill-child=9 true >/dev/null 2>&1
}

# A home with one worker, a backlog, a status log and a report. Callers add the
# malformed, missing, and oversized variants they need on top.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data/scout-one" "$home/config"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf 'Captain prefers short answers.\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux no-mistakes
  fm_write_meta "$home/state/worker-one.meta" \
    "window=firstmate:fm-worker-one" \
    "endpoint_task_id=worker-one" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=claude" \
    "model=opus" \
    "effort=xhigh" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=tmux"
  cat > "$home/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] worker-one - Build the thing (repo: sample) (kind: ship) (priority: 0) (since 2026-08-01)

## Queued

## Done
MD
  cat > "$home/data/scout-one/report.md" <<'MD'
# Scout one

## Verdict

The **thing** works. See `bin/thing.sh` and https://example.invalid/pr/1 for detail.

| finding | severity |
| ------- | -------- |
| none    | -        |
MD
  printf '%s\n' "$home"
}

file_mode() {  # <path> -> octal permission bits, portably
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null
}

run_dash() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z \
    "$DASH" "$@"
}

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

test_path_is_stable_and_inside_the_home() {
  local home out
  home=$(make_home stable-path)
  out=$(run_dash "$home" path) || fail "the dashboard could not report its page path"
  [ "$out" = "$home/.dashboard/control-plane.html" ] \
    || fail "the page path is not the stable per-home path: $out"
  pass "the page path is stable and inside the home"
}

test_the_payload_embeds_the_canonical_snapshot_unchanged() {
  local home payload canonical embedded direct
  home=$(make_home canonical)
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '.schema == "fm-dashboard.v1"' >/dev/null \
    || fail "the payload does not carry the fm-dashboard.v1 schema"
  canonical=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z \
    "$SNAPSHOT" --json) || fail "the canonical snapshot could not be produced"
  embedded=$(printf '%s' "$payload" | jq -S 'del(.snapshot.generated) | .snapshot')
  direct=$(printf '%s' "$canonical" | jq -S 'del(.generated)')
  [ "$embedded" = "$direct" ] \
    || fail "the embedded fleet snapshot is not the canonical snapshot verbatim"
  pass "the payload embeds the canonical fleet snapshot unchanged"
}

test_a_worker_carries_its_recorded_model_and_effort() {
  local home payload
  home=$(make_home runtime-record)
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    (.usage.agents | length) == 1
    and .usage.agents[0].harness == "claude"
    and .usage.agents[0].model == "opus"
    and .usage.agents[0].effort == "xhigh"' >/dev/null \
    || fail "the dispatched runtime record is missing its model or effort"
  pass "a worker carries the model and effort its spawn recorded"
}

test_a_missing_status_log_is_reported_not_degraded() {
  local home payload
  home=$(make_home no-status)
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    (.events | length) == 1
    and .events[0].readable == false
    and .events[0].reason == "not present"
    and (.events[0].lines | length) == 0
    and (.degraded | length) == 0' >/dev/null \
    || fail "a task with no event history was not reported as simply absent"
  pass "a worker with no event history reads as absent, not as a broken source"
}

test_event_history_is_bounded_and_discloses_what_it_dropped() {
  local home payload i
  home=$(make_home bounded-events)
  for i in $(seq 1 25); do
    printf 'working: step %s\n' "$i" >> "$home/state/worker-one.status"
  done
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_DASHBOARD_EVENT_LINES=10 \
    "$DASH" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .events[0].readable == true
    and .events[0].total == 25
    and .events[0].shown == 10
    and .events[0].truncated == 15
    and (.events[0].lines | length) == 10
    and .events[0].lines[9].raw == "working: step 25"' >/dev/null \
    || fail "the bounded event tail did not disclose the events it dropped"
  pass "event history is bounded and says how many older events it dropped"
}

test_status_lines_keep_their_recorded_verb_and_note() {
  local home payload
  home=$(make_home classified-events)
  {
    printf 'working: started\n'
    printf 'needs-decision [key=pick-one]: two options remain\n'
  } >> "$home/state/worker-one.status"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .events[0].lines[1].verb == "needs-decision"
    and .events[0].lines[1].note == "two options remain"
    and .events[0].lines[1].raw == "needs-decision [key=pick-one]: two options remain"' >/dev/null \
    || fail "a keyed status line lost its verb or note"
  pass "status lines keep the verb and note their own classifier assigns"
}

test_tail_collection_failure_is_disclosed_as_unavailable() {
  local home payload real_tail
  home=$(make_home tail-failure)
  printf 'working: still here\n' > "$home/state/worker-one.status"
  printf '1750000000\t7\tcheck\tworker-one\tstill queued\n' > "$home/state/.wake-queue"
  real_tail=$(command -v tail)
  printf '#!/usr/bin/env bash\ncase "$*" in *worker-one.status*|*.wake-queue*) exit 1;; esac\nexec %q "$@"\n' \
    "$real_tail" > "$home/fakebin/tail"
  chmod +x "$home/fakebin/tail"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .events[0].readable == false
    and .events[0].reason == "could not read bounded tail"
    and .supervision.wakes.available == false
    and .supervision.wakes.reason == "could not read bounded tail"
    and ([.degraded[] | select(.reason == "could not read bounded tail")] | length) == 2' >/dev/null \
    || fail "a failed bounded tail was rendered as healthy empty evidence"
  pass "tail collection failures remain explicit unavailable evidence"
}

test_a_symlinked_status_log_is_refused_and_disclosed() {
  local home payload
  home=$(make_home symlink-status)
  printf 'working: sentinel-outside-status\n' > "$TMP_ROOT/outside-status"
  ln -s "$TMP_ROOT/outside-status" "$home/state/worker-one.status"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .events[0].readable == false
    and (.events[0].reason | test("symlink"))
    and .snapshot.tasks[0].paths.status_log.last_event.raw == ""
    and (.events[0].lines | length) == 0
    and (.degraded | map(select(.source | test("status log"))) | length) == 1' >/dev/null \
    || fail "a symlinked status log was not refused and disclosed"
  pass "a symlinked event log is refused and the gap is disclosed"
}

test_the_dashboard_skips_remote_evidence_in_local_only_mode() {
  local home payload
  home=$(make_home local-only-remote)
  printf '#!/usr/bin/env bash\nprintf remote-call >> "$FM_HOME/remote-call.log"\nexit 1\n' \
    > "$home/fakebin/ssh"
  chmod +x "$home/fakebin/ssh"
  fm_write_meta "$home/state/remote-one.meta" \
    "kind=secondmate" "remote_host=remote.example" "remote_root=/srv/firstmate" \
    "home=/srv/firstmate" "remote_backend=herdr" "remote_target=default:w1:p1" \
    "harness=claude" "mode=no-mistakes" "yolo=off"
  printf '%s\n' '- remote-one (host: remote.example; root: /srv/firstmate; home: /srv/firstmate; scope: all; projects: none; added 2026-08-01)' \
    > "$home/data/secondmates.md"
  payload=$(run_dash "$home" json) || fail "the local-only dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks[0].remote.evidence == "unavailable"
    and (.snapshot.tasks[0].remote.reason | test("local-only"))
    and .snapshot.tasks[0].endpoint.exists == null
    and (.snapshot.tasks[0].current_state.detail | test("unavailable"))
    and (.snapshot.secondmate_current.records[0].current.reason | test("unavailable"))' >/dev/null \
    || fail "remote task evidence was not marked unavailable"
  [ ! -e "$home/remote-call.log" ] || fail "local-only dashboard evidence contacted a remote host"
  pass "the dashboard marks remote evidence unavailable without contacting its host"
}

# The guarantee under test is end to end - nothing outside this home's own
# evidence roots is ever read onto the page - so it is asserted on the built
# page rather than on whichever layer currently refuses first. Today the
# canonical scan excludes symlinked report paths and the composer's own
# containment check backs it up; either alone must keep this true.
test_a_report_symlinked_out_of_the_home_never_reaches_the_page() {
  local home payload page
  home=$(make_home escaping-report)
  mkdir -p "$TMP_ROOT/outside-data"
  printf '# elsewhere\n\nsentinel-outside-the-home\n' > "$TMP_ROOT/outside-data/report.md"
  rm -rf "$home/data/scout-one"
  ln -s "$TMP_ROOT/outside-data" "$home/data/scout-one"
  mkdir -p "$home/data/scout-two"
  ln -s "$TMP_ROOT/outside-data/report.md" "$home/data/scout-two/report.md"

  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '.reports.total == 0 and (.reports.records | length) == 0' >/dev/null \
    || fail "a report symlinked out of the home was read into the payload"
  printf '%s' "$payload" | jq -e '.snapshot.tasks[0].hints.scout_report_present == false' >/dev/null \
    || fail "a report symlinked out of the home was advertised as present"
  printf '%s' "$payload" | grep -q 'sentinel-outside-the-home' \
    && fail "content from outside the home leaked into the payload"

  run_dash "$home" build >/dev/null || fail "the page could not be built"
  page="$home/.dashboard/control-plane.html"
  grep -q 'sentinel-outside-the-home' "$page" \
    && fail "content from outside the home leaked into the built page"
  pass "a report symlinked out of the home never reaches the payload or the page"
}

test_a_dangling_wake_queue_is_disclosed_as_unsafe() {
  local home payload
  home=$(make_home dangling-wake-queue)
  ln -s "$TMP_ROOT/missing-wake-queue" "$home/state/.wake-queue"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .supervision.wakes.available == false
    and (.supervision.wakes.reason | test("symlink"))
    and (.degraded | map(select(.source == "wake queue")) | length) == 1' >/dev/null \
    || fail "a dangling wake queue was treated as healthy empty evidence"
  pass "a dangling wake queue is disclosed as unsafe evidence"
}

test_a_symlinked_secondmate_registry_is_disclosed_as_unsafe() {
  local home payload
  home=$(make_home symlinked-registry)
  ln -s "$TMP_ROOT/missing-secondmates" "$home/data/secondmates.md"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .snapshot.secondmate_current.registry.available == false
    and (.snapshot.secondmate_current.registry.reason | test("symlink"))' >/dev/null \
    || fail "a symlinked secondmate registry was reported as available"
  pass "a symlinked secondmate registry is disclosed as unsafe evidence"
}

test_a_large_report_is_truncated_and_says_so() {
  local home payload
  home=$(make_home large-report)
  head -c 4000 /dev/zero | LC_ALL=C tr '\0' 'x' > "$home/data/scout-one/report.md"
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_DASHBOARD_REPORT_BYTES=512 \
    "$DASH" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .reports.records[0].readable == true
    and .reports.records[0].truncated == true
    and .reports.records[0].bytes == 4000
    and (.reports.records[0].body | length) == 512' >/dev/null \
    || fail "an oversized report was not bounded and disclosed"
  pass "an oversized report is bounded to its byte cap and says it was truncated"
}

test_a_report_holding_binary_bytes_still_produces_valid_output() {
  local home payload
  home=$(make_home binary-report)
  printf '# title\n\000\000binary\000 tail\n' > "$home/data/scout-one/report.md"
  payload=$(run_dash "$home" json) || fail "a report with NUL bytes broke the payload"
  printf '%s' "$payload" | jq -e '
    .reports.records[0].readable == true
    and (.reports.records[0].body | test("binary"))
    and (.reports.records[0].body | test("\u0000") | not)' >/dev/null \
    || fail "NUL bytes were not stripped out of the rendered report body"
  pass "a report holding binary bytes still produces valid, readable output"
}

test_a_malformed_queued_notification_is_flagged_not_mis_parsed() {
  local home payload
  home=$(make_home malformed-wake)
  {
    printf '1750000000\t7\tcheck\tworker-one\tPR merged\n'
    printf 'this line was hand edited\n'
  } > "$home/state/.wake-queue"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .supervision.wakes.available == true
    and .supervision.wakes.total == 2
    and (.supervision.wakes.records | length) == 2
    and .supervision.wakes.records[0].malformed == false
    and .supervision.wakes.records[0].kind == "check"
    and .supervision.wakes.records[0].key == "worker-one"
    and .supervision.wakes.records[1].malformed == true
    and .supervision.wakes.records[1].payload == "this line was hand edited"' >/dev/null \
    || fail "a hand-edited queue line was mis-parsed instead of flagged"
  pass "a malformed queued notification is flagged rather than parsed into the wrong columns"
}

test_queued_notifications_are_bounded() {
  local home payload i
  home=$(make_home bounded-wakes)
  for i in $(seq 1 12); do
    printf '175000000%s\t%s\tsignal\tworker-one\tnote %s\n' "0" "$i" "$i" >> "$home/state/.wake-queue"
  done
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_DASHBOARD_WAKES=5 \
    "$DASH" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .supervision.wakes.total == 12
    and .supervision.wakes.shown == 5
    and .supervision.wakes.truncated == 7
    and .supervision.wakes.records[4].payload == "note 12"' >/dev/null \
    || fail "the queued-notification list was not bounded with disclosure"
  pass "queued notifications are bounded and disclose the older records they drop"
}

test_away_mode_and_missing_heartbeat_are_reported() {
  local home payload
  home=$(make_home supervision)
  : > "$home/state/.afk"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .supervision.away_mode == true
    and .supervision.beacon_present == false
    and .supervision.beacon_age_seconds == null
    and (.supervision.model | length) > 0' >/dev/null \
    || fail "away mode or an absent monitoring heartbeat was not reported honestly"
  pass "away mode and an absent monitoring heartbeat are reported, not guessed"
}

test_the_local_token_record_is_read_or_disclosed_as_missing() {
  local home payload
  home=$(make_home token-record)
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .usage.budget.available == true
    and .usage.budget.effective_budget_tokens == 7500
    and (.usage.budget.files | map(select(.file == "data/captain.md")) | length) == 1
    and (.usage.budget.files | map(select(.file == "data/captain.md")) | .[0].estimated_tokens) > 0' \
    >/dev/null || fail "the local token record was not read from its owner command"

  rm -f "$home/config/startup-memory-budget"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .usage.budget.available == false
    and (.degraded | map(select(.source == "startup memory budget")) | length) == 1' >/dev/null \
    || fail "an unreadable token record was not disclosed as a gap"
  pass "the local token record is read from its owner, or disclosed as missing"
}

test_the_built_page_carries_one_readable_payload_and_is_private() {
  local home out mode slots
  home=$(make_home build-page)
  out=$(run_dash "$home" build) || fail "the page could not be built"
  [ "$out" = "dashboard: $home/.dashboard/control-plane.html" ] \
    || fail "build did not report the stable page path: $out"
  [ -f "$home/.dashboard/control-plane.html" ] || fail "the page was not written"
  mode=$(file_mode "$home/.dashboard/control-plane.html")
  [ "$mode" = "600" ] || fail "the built page is not private to its owner: $mode"
  slots=$(grep -c '__FM_DASHBOARD_DATA__' "$home/.dashboard/control-plane.html" || true)
  [ "$slots" -eq 0 ] || fail "the page still carries its unfilled data slot"
  sed -n '/<script id="fm-dashboard-data" type="application\/json">/,/<\/script>/p' \
    "$home/.dashboard/control-plane.html" | sed '1d;$d' \
    | jq -e '.schema == "fm-dashboard.v1"' >/dev/null \
    || fail "the built page does not carry a readable fm-dashboard.v1 payload"
  pass "the built page carries exactly one readable payload and stays private"
}

test_a_payload_string_cannot_close_the_data_block_early() {
  local home page body
  home=$(make_home script-escape)
  printf '# report\n\nA literal </script><script>alert(1)</script> inside a report.\n' \
    > "$home/data/scout-one/report.md"
  run_dash "$home" build >/dev/null || fail "the page could not be built"
  page="$home/.dashboard/control-plane.html"
  body=$(sed -n '/<script id="fm-dashboard-data" type="application\/json">/,/<\/script>/p' "$page" \
    | sed '1d;$d')
  printf '%s' "$body" | jq -e '.schema == "fm-dashboard.v1"' >/dev/null \
    || fail "a report containing a closing script tag truncated the data block"
  printf '%s' "$body" | jq -e '
    .reports.records[0].body | test("alert\\(1\\)")' >/dev/null \
    || fail "the report body did not survive escaping"
  grep -q '\\u003c/script' "$page" \
    || fail "the injected payload did not escape its angle brackets"
  pass "a report containing a closing script tag cannot end the data block early"
}

test_the_build_refuses_a_template_without_a_data_slot() {
  local home out status=0
  home=$(make_home no-slot)
  printf '<html><body>no slot here</body></html>\n' > "$home/template.html"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_DASHBOARD_TEMPLATE="$home/template.html" \
    "$DASH" build 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the refusal did not name the missing data slot"
  [ ! -e "$home/.dashboard/control-plane.html" ] \
    || fail "a refused build still published a page"
  pass "the build refuses a template that carries no data slot"
}

test_the_dashboard_refuses_when_the_fleet_snapshot_fails() {
  local home out status=0
  home=$(make_home snapshot-fails)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_SECONDMATES=not-a-number "$DASH" json 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "the dashboard rendered anyway after the snapshot failed"
  assert_contains "$out" "snapshot" "the refusal did not name the failed fleet snapshot"
  pass "the dashboard refuses to render when the fleet snapshot fails"
}

test_the_dashboard_refuses_an_invalid_bound_or_port() {
  local home out status=0
  home=$(make_home invalid-bounds)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DASHBOARD_EVENT_LINES=0 \
    "$DASH" json 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a zero event bound was accepted"
  assert_contains "$out" "FM_DASHBOARD_EVENT_LINES" "the refusal did not name the invalid bound"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$DASH" serve --port 99999 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an out-of-range port was accepted"
  assert_contains "$out" "1-65535" "the refusal did not name the valid port range"
  pass "the dashboard refuses an invalid bound or an out-of-range port"
}

test_render_refuses_an_incomplete_dashboard_document() {
  local home out status=0
  home=$(make_home incomplete-payload)
  printf '{"schema":"fm-dashboard.v1"}\n' > "$home/incomplete.json"
  out=$(FM_HOME="$home" "$DASH" render "$home/incomplete.json" --out "$home/page.html" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "render accepted an incomplete dashboard document"
  assert_contains "$out" "incomplete" "the refusal did not identify the incomplete payload"
  [ ! -e "$home/page.html" ] || fail "an incomplete render still published a page"
  pass "render refuses an incomplete dashboard document"
}

test_render_refuses_an_invalid_generated_timestamp() {
  local home out status=0
  home=$(make_home invalid-generated-timestamp)
  run_dash "$home" json > "$home/valid.json" || fail "the valid payload fixture could not be composed"
  jq '.generated = "not-a-date"' "$home/valid.json" > "$home/invalid.json" \
    || fail "the invalid payload fixture could not be written"
  out=$(run_dash "$home" render "$home/invalid.json" --out "$home/page.html" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "render accepted an invalid generated timestamp"
  assert_contains "$out" "not a complete readable" \
    "the timestamp refusal did not identify the unusable payload"
  [ ! -e "$home/page.html" ] || fail "an invalid generated timestamp still published a page"
  pass "render refuses an invalid generated timestamp"
}

test_render_refuses_an_unrepresentable_wake_epoch() {
  local home out status=0
  home=$(make_home invalid-wake-epoch)
  run_dash "$home" json > "$home/valid.json" || fail "the valid payload fixture could not be composed"
  jq '
    .supervision.wakes = (.supervision.wakes
      | .total = 1
      | .shown = 1
      | .truncated = 0
      | .records = [{epoch:1e308, seq:"1", kind:"check", key:"worker-one",
                    payload:"unrepresentable", malformed:false}])
  ' "$home/valid.json" > "$home/invalid.json" || fail "the invalid payload fixture could not be written"
  out=$(run_dash "$home" render "$home/invalid.json" --out "$home/page.html" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "render accepted an unrepresentable wake epoch"
  assert_contains "$out" "not a complete readable" \
    "the wake epoch refusal did not identify the unusable payload"
  [ ! -e "$home/page.html" ] || fail "an invalid wake epoch still published a page"
  pass "render refuses a wake epoch outside the JavaScript date range"
}

test_render_refuses_an_unsafe_integer() {
  local home out status=0
  home=$(make_home unsafe-integer)
  run_dash "$home" json > "$home/valid.json" || fail "the valid payload fixture could not be composed"
  jq '
    .reports = (.reports
      | .total = 9007199254740992
      | .shown = 0
      | .truncated = 9007199254740992
      | .records = [])
  ' "$home/valid.json" > "$home/invalid.json" || fail "the unsafe integer fixture could not be written"
  out=$(run_dash "$home" render "$home/invalid.json" --out "$home/page.html" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "render accepted an integer outside JavaScript's safe range"
  assert_contains "$out" "not a complete readable" \
    "the unsafe integer refusal did not identify the unusable payload"
  [ ! -e "$home/page.html" ] || fail "an unsafe integer render still published a page"
  pass "render refuses integers outside JavaScript's safe range"
}

test_a_bare_output_filename_is_published_in_the_current_directory() {
  local home
  home=$(make_home bare-output)
  (cd "$home" && run_dash "$home" build --out page.html) >/dev/null \
    || fail "the dashboard could not publish a bare output filename"
  [ -f "$home/page.html" ] || fail "the bare output filename became a directory"
  pass "a bare output filename is published in the current directory"
}

test_an_absolute_output_outside_the_home_is_refused() {
  local home out status=0 target
  home=$(make_home absolute-output)
  target="$TMP_ROOT/absolute-output.html"
  out=$(run_dash "$home" build --out "$target" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an absolute output outside the home was accepted"
  assert_contains "$out" "safe directory" "the absolute output refusal was unclear"
  [ ! -e "$target" ] || fail "the page escaped to an absolute path outside the home"
  pass "an absolute output outside the home is refused before publication"
}

test_a_symlinked_output_parent_is_refused() {
  local home out status=0
  home=$(make_home symlink-output)
  run_dash "$home" json > "$home/payload.json" \
    || fail "the valid payload fixture could not be composed"
  mkdir -p "$TMP_ROOT/outside-output"
  ln -s "$TMP_ROOT/outside-output" "$home/publish"
  out=$(run_dash "$home" render "$home/payload.json" --out "$home/publish/page.html" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "render published through a symlinked output parent"
  assert_contains "$out" "safe directory" "the symlinked output parent refusal was unclear"
  [ ! -e "$TMP_ROOT/outside-output/page.html" ] || fail "the page escaped through a symlinked output parent"
  pass "a symlinked output parent is refused before publication"
}

test_a_symlinked_evidence_root_is_refused_before_reading_it() {
  local home outside out status=0
  home=$(make_home symlink-root)
  outside="$TMP_ROOT/outside-root"
  mkdir -p "$outside"
  printf 'outside status\n' > "$outside/worker-one.status"
  rm -rf "$home/state"
  ln -s "$outside" "$home/state"
  out=$(run_dash "$home" json 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a symlinked state root was accepted"
  assert_contains "$out" "unsafe evidence root" "the symlinked root refusal was unclear"
  [ ! -e "$outside/.wake-queue" ] || fail "the dashboard wrote through a symlinked state root"
  pass "a symlinked evidence root is refused before any outside read or write"
}

test_a_symlinked_task_metadata_is_not_silently_dropped() {
  local home outside out
  home=$(make_home unsafe-meta)
  outside="$TMP_ROOT/unsafe-meta-outside"
  printf 'kind=ship\n' > "$outside"
  ln -s "$outside" "$home/state/unsafe.meta"
  out=$(run_dash "$home" json 2>&1) && fail "unsafe task metadata was silently dropped: $out"
  assert_contains "$out" "unsafe task metadata" "unsafe task metadata was not disclosed"
  pass "unsafe task metadata blocks the canonical snapshot instead of disappearing"
}

test_a_symlinked_watcher_heartbeat_is_not_reported_as_healthy() {
  local home outside payload
  home=$(make_home symlink-heartbeat)
  outside="$TMP_ROOT/outside-heartbeat"
  printf 'fresh\n' > "$outside"
  ln -s "$outside" "$home/state/.last-watcher-beat"
  payload=$(run_dash "$home" json) || fail "the dashboard could not compose around a symlinked heartbeat"
  printf '%s' "$payload" | jq -e '
    .supervision.healthy == false
    and (.degraded | map(select(.source == "watcher heartbeat")) | length) == 1' >/dev/null \
    || fail "a symlinked heartbeat was treated as healthy or hidden"
  pass "a symlinked watcher heartbeat is disclosed and never counted as healthy"
}

test_a_herdr_backed_snapshot_times_out_its_local_probe() {
  local home payload elapsed
  home=$(make_home bounded-herdr)
  printf '#!/usr/bin/env bash\nsleep 10\n' > "$home/fakebin/herdr"
  chmod +x "$home/fakebin/herdr"
  fm_write_meta "$home/state/herdr-one.meta" \
    "kind=ship" "backend=herdr" "window=default:w1:p1" "harness=claude"
  SECONDS=0
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_SNAPSHOT_HERDR_TIMEOUT=1 \
    "$DASH" json) || fail "the dashboard failed instead of returning bounded Herdr evidence"
  elapsed=$SECONDS
  [ "$elapsed" -lt 6 ] || fail "the local Herdr snapshot probe exceeded its bound: ${elapsed}s"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks | map(select(.id == "herdr-one" and .current_state.state == "unknown")) | length == 1' >/dev/null \
    || fail "the timed-out Herdr task was not disclosed as unknown"
  pass "Herdr-backed snapshot probes are bounded and preserve unknown evidence"
}

test_a_malformed_herdr_endpoint_is_unknown_not_absent() {
  local home payload
  home=$(make_home malformed-herdr-endpoint)
  fm_write_meta "$home/state/herdr-one.meta" \
    "window=default:w1:p2:extra" \
    "endpoint_task_id=herdr-one" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=claude" \
    "kind=secondmate" \
    "backend=herdr"
  cat > "$home/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"agent get"*) printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' ;;
  *) printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2:extra"}}}' ;;
esac
SH
  chmod +x "$home/fakebin/herdr"
  payload=$(run_dash "$home" json) || fail "the dashboard refused a malformed Herdr endpoint"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks
    | map(select(.id == "herdr-one"))
    | length == 1
    and .[0].endpoint.exists == null
    and .[0].endpoint.agent_alive == "unknown"
    and .[0].endpoint.status == "unknown"' >/dev/null \
    || fail "a malformed Herdr endpoint was rendered as confirmed absence"
  pass "a malformed Herdr endpoint remains unknown instead of absent"
}

test_a_malformed_tmux_endpoint_is_unknown_not_absent() {
  local home payload
  home=$(make_home malformed-tmux-endpoint)
  fm_write_meta "$home/state/worker-one.meta" \
    "window=worker-one" \
    "endpoint_task_id=worker-one" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=claude" \
    "model=opus" \
    "effort=xhigh" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=tmux"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) exit 0 ;;
  display-message) exit 1 ;;
  list-windows) printf 'firstmate:other\n' ;;
esac
exit 0
SH
  chmod +x "$home/fakebin/tmux"
  payload=$(run_dash "$home" json) || fail "the dashboard refused a malformed endpoint instead of preserving it"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks
    | map(select(.id == "worker-one"))
    | length == 1
    and .[0].endpoint.exists == null
    and .[0].endpoint.status == "unknown"' >/dev/null \
    || fail "a malformed tmux endpoint was rendered as confirmed absence"
  pass "a malformed tmux endpoint remains unknown instead of absent"
}

test_malformed_zellij_and_cmux_endpoints_are_unknown_not_absent() {
  local home zellij_state cmux_state
  home=$(make_home malformed-nonherdr-endpoints)
  zellij_state=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_target_state zellij ":7"' _ "$ROOT") \
    || fail "zellij target-state command failed"
  cmux_state=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_target_state cmux "workspace:surface:extra"' _ "$ROOT") \
    || fail "cmux target-state command failed"
  [ "$zellij_state" = unknown ] \
    || fail "a malformed zellij endpoint was reported as $zellij_state"
  [ "$cmux_state" = unknown ] \
    || fail "a malformed cmux endpoint was reported as $cmux_state"
  pass "malformed zellij and cmux endpoints remain unknown"
}

test_initial_serve_build_is_bounded_before_binding() {
  local home port out real_jq
  containment_available || {
    pass "skip: bounded serve builds require available process containment"
    return 0
  }
  home=$(make_home bounded-initial-build)
  port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
  )
  real_jq=$(command -v jq)
  printf '#!/usr/bin/env bash\nsleep 5\nexec %q "$@"\n' "$real_jq" > "$home/fakebin/jq"
  chmod +x "$home/fakebin/jq"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DASHBOARD_BUILD_TIMEOUT=1 \
    "$DASH" serve --port "$port" --owner-digest 00000000 2>&1) && \
    fail "an unbounded initial build was reported as successful: $out"
  assert_contains "$out" "initial dashboard build exceeded" \
    "an initial build timeout did not block before binding"
  pass "the initial serve build is bounded before the dashboard binds"
}

test_serve_refuses_without_process_containment() {
  local home port out status=0
  containment_available && {
    pass "skip: this host provides process containment"
    return 0
  }
  home=$(make_home unavailable-containment)
  port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
  )
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    "$DASH" serve --port "$port" --owner-digest 00000000 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "serve succeeded without process containment: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" \
    "serve did not disclose unavailable process containment"
  assert_not_contains "$out" "serving:" \
    "serve reported a URL without process containment"
  pass "serve fails closed when process containment is unavailable"
}

test_initial_build_contains_daemonizing_descendants() {
  local home port out child status=0
  containment_available || {
    pass "skip: Linux process containment is unavailable on this platform"
    return 0
  }
  home=$(make_home contained-initial-build)
  port=$(free_port)
  cat > "$home/fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -u
marker="${FM_DASHBOARD_DESCENDANT_MARKER:?}"
if [ ! -e "$marker" ]; then
  MARKER="$marker" python3 -c '
import os
import time

first = os.fork()
if first == 0:
    second = os.fork()
    if second == 0:
        try:
            os.setsid()
        except OSError:
            pass
        with open(os.environ["MARKER"], "w", encoding="utf-8") as marker:
            marker.write(str(os.getpid()) + "\\n")
        time.sleep(30)
    os._exit(0)
os.waitpid(first, 0)
time.sleep(30)
'
fi
sleep 30
SH
  chmod +x "$home/fakebin/jq"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_DASHBOARD_BUILD_TIMEOUT=1 FM_DASHBOARD_DESCENDANT_MARKER="$home/descendant.pid" \
    "$DASH" serve --port "$port" --owner-digest 00000000 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an uncontained initial build was reported as successful: $out"
  assert_contains "$out" "initial dashboard build exceeded" \
    "an initial build timeout did not fail closed"
  for _ in $(seq 1 20); do
    [ -s "$home/descendant.pid" ] && break
    sleep 0.1
  done
  [ -s "$home/descendant.pid" ] || fail "the initial build did not create its descendant marker"
  child=$(sed -n '1p' "$home/descendant.pid")
  [ -n "$(sed -n '1p' "$home/descendant.pid")" ] \
    || fail "the initial build did not record its daemonized descendant"
  for _ in $(seq 1 20); do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "the initial build left a descendant process running"
  fi
  pass "the initial build contains and cleans daemonizing descendants"
}

test_initial_build_proves_descendant_cleanup_after_success() {
  local home port out child status=0 real_jq
  containment_available || {
    pass "skip: successful descendant checks require available process containment"
    return 0
  }
  home=$(make_home successful-descendant)
  port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
  )
  real_jq=$(command -v jq)
  cat > "$home/fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -u
marker="${FM_DASHBOARD_DESCENDANT_MARKER:?}"
if [ ! -e "$marker" ]; then
  MARKER="$marker" python3 -c '
import os
import time

child = os.fork()
if child == 0:
    os.close(1)
    os.close(2)
    with open(os.environ["MARKER"], "w", encoding="utf-8") as marker:
        marker.write(str(os.getpid()) + "\\n")
    time.sleep(30)
    os._exit(0)
os._exit(0)
'
fi
exec "${FM_DASHBOARD_REAL_JQ:?}" "$@"
SH
  chmod +x "$home/fakebin/jq"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_DASHBOARD_DESCENDANT_MARKER="$home/descendant.pid" \
    FM_DASHBOARD_REAL_JQ="$real_jq" \
    python3 - "$DASH" "$home" "$port" <<'PY'
import os
import select
import signal
import subprocess
import sys
import time

dash, home, port = sys.argv[1:]
proc = subprocess.Popen(
    [dash, "serve", "--port", port, "--owner-digest", "00000000"],
    env=os.environ.copy(),
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    start_new_session=True,
)
lines = []
started = False
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    ready, _, _ = select.select([proc.stdout], [], [], 0.1)
    if not ready:
        continue
    line = proc.stdout.readline()
    if not line:
        break
    lines.append(line)
    if line.startswith("serving:"):
        started = True
        break
if started:
    os.killpg(proc.pid, signal.SIGTERM)
try:
    proc.wait(timeout=2)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.wait(timeout=2)
sys.stdout.write("".join(lines))
sys.exit(0 if started else 1)
PY
  ) || status=$?
  [ "$status" -eq 0 ] || fail "a contained successful build did not report a URL: $out"
  assert_contains "$out" "serving:" \
    "a contained successful build did not bind after proving cleanup"
  assert_not_contains "$out" "DASHBOARD_BLOCKED" \
    "a contained successful build reported a false blocker"
  [ -s "$home/descendant.pid" ] || fail "the successful build did not create its descendant marker"
  child=$(sed -n '1p' "$home/descendant.pid")
  for _ in $(seq 1 20); do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "a successful build left a descendant process running"
  fi
  pass "a successful build proves and cleans its descendants"
}

test_direct_json_build_is_bounded() {
  local home out real_jq
  home=$(make_home bounded-direct-build)
  real_jq=$(command -v jq)
  printf '#!/usr/bin/env bash\nsleep 5\nexec %q "$@"\n' "$real_jq" > "$home/fakebin/jq"
  chmod +x "$home/fakebin/jq"
  SECONDS=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DASHBOARD_BUILD_TIMEOUT=1 \
    "$DASH" json 2>&1) && fail "an unbounded direct build was reported as successful: $out"
  [ "$SECONDS" -lt 6 ] || fail "a direct dashboard build exceeded its bound: ${SECONDS}s"
  pass "a direct dashboard JSON build is bounded"
}

test_path_is_stable_and_inside_the_home
test_the_payload_embeds_the_canonical_snapshot_unchanged
test_a_worker_carries_its_recorded_model_and_effort
test_a_missing_status_log_is_reported_not_degraded
test_event_history_is_bounded_and_discloses_what_it_dropped
test_status_lines_keep_their_recorded_verb_and_note
test_tail_collection_failure_is_disclosed_as_unavailable
test_a_symlinked_status_log_is_refused_and_disclosed
test_the_dashboard_skips_remote_evidence_in_local_only_mode
test_a_report_symlinked_out_of_the_home_never_reaches_the_page
test_a_dangling_wake_queue_is_disclosed_as_unsafe
test_a_symlinked_secondmate_registry_is_disclosed_as_unsafe
test_a_large_report_is_truncated_and_says_so
test_a_report_holding_binary_bytes_still_produces_valid_output
test_a_malformed_queued_notification_is_flagged_not_mis_parsed
test_queued_notifications_are_bounded
test_away_mode_and_missing_heartbeat_are_reported
test_the_local_token_record_is_read_or_disclosed_as_missing
test_the_built_page_carries_one_readable_payload_and_is_private
test_a_payload_string_cannot_close_the_data_block_early
test_the_build_refuses_a_template_without_a_data_slot
test_the_dashboard_refuses_when_the_fleet_snapshot_fails
test_the_dashboard_refuses_an_invalid_bound_or_port
test_render_refuses_an_incomplete_dashboard_document
test_render_refuses_an_invalid_generated_timestamp
test_render_refuses_an_unrepresentable_wake_epoch
test_render_refuses_an_unsafe_integer
test_a_bare_output_filename_is_published_in_the_current_directory
test_an_absolute_output_outside_the_home_is_refused
test_a_symlinked_output_parent_is_refused
test_a_symlinked_evidence_root_is_refused_before_reading_it
test_a_symlinked_task_metadata_is_not_silently_dropped
test_a_symlinked_watcher_heartbeat_is_not_reported_as_healthy
test_a_herdr_backed_snapshot_times_out_its_local_probe
test_a_malformed_herdr_endpoint_is_unknown_not_absent
test_a_malformed_tmux_endpoint_is_unknown_not_absent
test_malformed_zellij_and_cmux_endpoints_are_unknown_not_absent
test_initial_serve_build_is_bounded_before_binding
test_serve_refuses_without_process_containment
test_initial_build_contains_daemonizing_descendants
test_initial_build_proves_descendant_cleanup_after_success
test_direct_json_build_is_bounded
