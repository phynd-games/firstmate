#!/usr/bin/env bash
# Behavior tests for the read-only control-plane dashboard composer
# (bin/fm-dashboard.sh) and the bounded descriptor-anchored read boundary it
# collects through (bin/fm-dashboard-read.py over bin/fm_dashboard_io.py),
# exercised end to end against synthetic homes. Every assertion is on the
# command's own output contract - the fm-dashboard.v1 payload and the built page
# - never on the script's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

containment_available() {
  case "$(uname -s)" in
    Linux)
      command -v unshare >/dev/null 2>&1 || return 1
      unshare --pid --fork --mount-proc --kill-child=9 true >/dev/null 2>&1
      ;;
    Darwin)
      command -v sandbox-exec >/dev/null 2>&1 || return 1
      if sandbox-exec -p '(version 1) (allow default) (deny network-inbound)' \
        python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0))' \
        >/dev/null 2>&1; then
        return 1
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}

# A home with one worker, a backlog, a status log and a report. Callers add the
# malformed, missing, and oversized variants they need on top.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data/scout-one" "$home/config"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf 'Captain prefers short answers.\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  # Firstmate workers are Herdr-only, so the default fixture is Herdr-backed.
  # The malformed tmux/zellij/cmux cases below deliberately keep their own
  # backends: they prove the snapshot does not mis-report non-Herdr metadata.
  fm_fake_exit0 "$fakebin" herdr no-mistakes
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
    "backend=herdr"
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
  case "$(uname -s)" in
    Darwin) stat -f %Lp "$1" 2>/dev/null ;;
    *) stat -c %a "$1" 2>/dev/null ;;
  esac
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

test_free_form_backlog_rows_remain_valid_unstructured_evidence() {
  local home payload
  home=$(make_home free-form-backlog)
  cat > "$home/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] worker-one - Build the thing (repo: sample) (kind: ship) (since 2026-08-01)
operator note without task metadata

## Queued
free-form queued evidence

## Done
completed prose retained verbatim
MD
  payload=$(run_dash "$home" json) || fail "free-form backlog evidence invalidated the dashboard"
  printf '%s' "$payload" | jq -e '
    .snapshot.backlog.available == true
    and ([.snapshot.backlog.records[] | select(.structured == false and .raw != null)] | length) == 3
    and ([.snapshot.backlog.records[] | select(.structured == false) | .key] | unique | length) == 3
    and ([.snapshot.backlog.records[] | select(.raw == "free-form queued evidence")] | length) == 1' >/dev/null \
    || fail "free-form backlog rows were not preserved as unstructured records"
  pass "free-form backlog rows remain valid unstructured evidence"
}

test_record_reads_preserve_the_authoritative_source_path() {
  local home metadata data_real payload
  home=$(make_home exact-source-path)
  ln -s scout-one "$home/data/alias"
  metadata="$home/read.meta"
  data_real=$(cd "$home/data" && pwd -P)
  python3 "$ROOT/bin/fm-dashboard-read.py" "$home/data/alias/report.md" "$home/data" \
    text 4096 - "$metadata" >/dev/null \
    || fail "a safe read through an allowed ancestor symlink failed"
  # Provenance must name the file these bytes actually came from. The descriptor
  # read data/scout-one/report.md, so reporting the alias would claim a source
  # that was never opened; the recorded path is disclosed beside it, not instead
  # of it, so an alias is visible rather than substituted.
  jq -e --arg resolved "$data_real/scout-one/report.md" '.resolved_path == $resolved' \
    "$metadata" >/dev/null \
    || fail "the record reader did not name the file it read: $(jq -r .resolved_path "$metadata")"
  jq -e --arg path "$home/data/alias/report.md" '.path == $path' "$metadata" >/dev/null \
    || fail "the record reader replaced the path as recorded"
  # A record with no alias reports one and the same path both ways.
  python3 "$ROOT/bin/fm-dashboard-read.py" "$home/data/scout-one/report.md" "$home/data" \
    text 4096 - "$metadata" >/dev/null \
    || fail "reading an unaliased report failed"
  jq -e '.resolved_path != null and (.resolved_path | endswith("/data/scout-one/report.md"))' \
    "$metadata" >/dev/null \
    || fail "an unaliased record did not report the file it read"
  # And the payload itself carries both facts for every readable record.
  printf 'working: reading\n' > "$home/state/worker-one.status"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    ([.events[] | select(.readable) | .resolved_path] | length > 0 and all(type == "string"))
    and ([.reports.records[] | select(.readable) | .resolved_path]
      | length > 0 and all(type == "string"))' >/dev/null \
    || fail "the payload published no resolved source path for readable records"
  pass "record reads report the recorded path and the exact file they read"
}

test_report_discovery_applies_its_bound_during_enumeration() {
  local home payload i
  home=$(make_home bounded-report-discovery)
  for i in $(seq -w 1 12); do
    mkdir -p "$home/data/report-$i"
    printf '# Report %s\n' "$i" > "$home/data/report-$i/report.md"
  done
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_SNAPSHOT_REPORTS=2 \
    "$SNAPSHOT" --json) || fail "bounded report discovery failed"
  printf '%s' "$payload" | jq -e '
    ([.scout_reports[] | select((.overflow // false) | not)] | length) <= 2
    and ([.scout_reports[] | select(.overflow == true)] | length) == 1' >/dev/null \
    || fail "report discovery exceeded its pre-enumeration bound or hid overflow"
  pass "report discovery stays bounded while enumerating report directories"
}

test_report_discovery_refusal_is_preserved_as_degraded_evidence() {
  local home payload outside
  home=$(make_home report-discovery-refusal)
  outside="$TMP_ROOT/report-discovery-refusal-outside"
  printf '# outside\n' > "$outside"
  mkdir -p "$home/data/refused"
  ln -s "$outside" "$home/data/refused/report.md"
  payload=$(run_dash "$home" json) || fail "report discovery refusal broke collection"
  printf '%s' "$payload" | jq -e '
    [.snapshot.scout_reports[] | select(.error == true and (.path | endswith("/data/refused/report.md")))]
    | length == 1
    and .[0].available == false
    and (. [0].reason | test("symlink"))' >/dev/null \
    || fail "a refused report discovery entry disappeared without degraded evidence"
  pass "report discovery refusals remain explicit degraded evidence"
}

test_snapshot_rejects_invalid_record_read_bounds() {
  local home out status=0
  home=$(make_home invalid-snapshot-bound)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_META_BYTES=invalid \
    "$SNAPSHOT" --json 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an invalid metadata byte bound was accepted"
  assert_contains "$out" "FM_SNAPSHOT_META_BYTES" "invalid metadata bound diagnostic"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_STATUS_BYTES=0 \
    "$SNAPSHOT" --json 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a zero status byte bound was accepted"
  assert_contains "$out" "FM_SNAPSHOT_STATUS_BYTES" "invalid status bound diagnostic"
  pass "snapshot record byte bounds are validated at input"
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

test_an_unterminated_event_line_counts_as_one_record() {
  local home payload
  home=$(make_home unterminated-event)
  printf 'working: final line' > "$home/state/worker-one.status"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .events[0].readable == true
    and .events[0].total == 1
    and .events[0].shown == 1
    and .events[0].truncated == 0
    and .events[0].lines[0].raw == "working: final line"' >/dev/null \
    || fail "an unterminated event line was not counted as a logical record"
  pass "an unterminated event line counts as one logical record"
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
  local home payload real_python
  home=$(make_home tail-failure)
  printf 'working: still here\n' > "$home/state/worker-one.status"
  printf '1750000000\t7\tcheck\tworker-one\tstill queued\n' > "$home/state/.wake-queue"
  real_python=$(command -v python3)
  cat > "$home/fakebin/python3" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  *fm-dashboard-read.py)
    case "\${2:-}" in
      *worker-one.status|*/.wake-queue)
        printf '%s\n' 'could not read bounded tail' >&2
        exit 1
        ;;
    esac
    ;;
esac
exec "$real_python" "\$@"
SH
  chmod +x "$home/fakebin/python3"
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

test_status_read_failure_does_not_become_pr_absence() {
  local home payload real_python
  home=$(make_home status-pr-failure)
  real_python=$(command -v python3)
  cat > "$home/fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$ROOT/bin/fm-dashboard-read.py" ] && [[ "\${2:-}" == *worker-one.status ]]; then
  printf '%s\\n' 'status log read failed' >&2
  exit 1
fi
exec "$real_python" "\$@"
SH
  chmod +x "$home/fakebin/python3"
  payload=$(run_dash "$home" json) || fail "status-read failure broke collection"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks[] | select(.id == "worker-one")
    | .pr.available == false
    and (.pr.reason | test("status log read failed"))
    and .pr.source == "status_event"' >/dev/null \
    || fail "a failed status-log read was presented as absent PR evidence"
  pass "status-log read failures stay distinct from absent PR evidence"
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
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf remote-call >> \"\$FM_HOME/remote-call.log\"" 'exit 1' \
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
test_a_report_symlinked_out_of_the_home_never_reaches_the_evidence() {
  local home payload
  home=$(make_home escaping-report)
  mkdir -p "$TMP_ROOT/outside-data"
  printf '# elsewhere\n\nsentinel-outside-the-home\n' > "$TMP_ROOT/outside-data/report.md"
  rm -rf "$home/data/scout-one"
  ln -s "$TMP_ROOT/outside-data" "$home/data/scout-one"
  mkdir -p "$home/data/scout-two"
  ln -s "$TMP_ROOT/outside-data/report.md" "$home/data/scout-two/report.md"

  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    [.reports.records[] | select(.path | endswith("/data/scout-one/report.md")
      or endswith("/data/scout-two/report.md"))] as $refused
    | ($refused | length) == 2
    and all($refused[]; .readable == false and (.reason | test("symlink|outside")))' >/dev/null \
    || fail "a report symlinked out of the home was not disclosed as unavailable evidence"
  printf '%s' "$payload" | jq -e '.snapshot.tasks[0].hints.scout_report_present == false' >/dev/null \
    || fail "a report symlinked out of the home was advertised as present"
  printf '%s' "$payload" | grep -q 'sentinel-outside-the-home' \
    && fail "content from outside the home leaked into the payload"

  # The payload is the only thing the API can serve, so keeping it clean is the
  # whole containment guarantee now that there is no separate generated page.
  pass "a report symlinked out of the home never reaches the evidence the API serves"
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

test_a_task_linked_report_uses_the_global_report_cap() {
  local home payload
  home=$(make_home linked-report-cap)
  mkdir -p "$home/data/worker-one" "$home/data/worker-two"
  printf '# Worker report\n\nThe task artifact.\n' > "$home/data/worker-one/report.md"
  printf '# Worker two report\n' > "$home/data/worker-two/report.md"
  fm_write_meta "$home/state/worker-two.meta" \
    "window=firstmate:fm-worker-two" "endpoint_task_id=worker-two" \
    "worktree=$home/wt-two" "project=$home/project" "harness=claude" \
    "model=opus" "effort=xhigh" "kind=ship" "mode=no-mistakes" \
    "yolo=off" "backend=herdr"
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_DASHBOARD_REPORTS=1 \
    "$DASH" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .reports.total == 3
    and (.reports.records | length) == 1
    and .reports.records[0].id == "worker-one"
    and .reports.truncated == 2
    and ([.snapshot.scout_reports[] | select(.overflow == true and .count == 1)] | length) == 1' >/dev/null \
    || fail "the global report cap did not prioritize task-linked reports"
  pass "task-linked reports consume the global report cap before scout reports"
}

test_an_unreadable_task_report_preserves_its_refusal_reason() {
  local home payload outside
  home=$(make_home refused-task-report)
  outside="$TMP_ROOT/refused-task-report-outside"
  printf 'outside report\n' > "$outside"
  mkdir -p "$home/data/worker-one"
  rm -f "$home/data/worker-one/report.md"
  ln -s "$outside" "$home/data/worker-one/report.md"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks[] | select(.id == "worker-one")
    | .paths.report.present == false
    and .paths.report.available == false
    and (.paths.report.path | endswith("/data/worker-one/report.md"))
    and (.paths.report.reason | test("symlink"))' >/dev/null \
    || fail "the task report refusal reason was discarded"
  pass "an unreadable task report preserves its path and refusal reason"
}

test_scout_report_discovery_failure_is_not_an_empty_success() {
  local home real_python out status=0
  home=$(make_home scout-discovery-failure)
  real_python=$(command -v python3)
  cat > "$home/fakebin/python3" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = report_paths ] || continue
  printf '%s\\n' 'refused: report discovery failed' >&2
  exit 1
done
exec "$real_python" "\$@"
SH
  chmod +x "$home/fakebin/python3"
  out=$(run_dash "$home" json 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "scout report discovery failure became a successful empty array"
  printf '%s' "$out" | grep -q 'scout report discovery failed' \
    || fail "scout report discovery failure was hidden"
  pass "scout report discovery failures remain explicit collector failures"
}

test_a_refused_report_directory_keeps_its_discovery_reason() {
  local home payload
  home=$(make_home discovery-reason-kept)
  # The report directory is the symlink, so the report path underneath it still
  # resolves to a readable file inside this home. Discovery refused that entry;
  # re-reading the path would quietly overrule the refusal and present the
  # aliased body as this worker's own report.
  ln -s scout-one "$home/data/aliased-scout"
  payload=$(run_dash "$home" json) || fail "a refused report directory broke collection"
  printf '%s' "$payload" | jq -e '
    [.reports.records[] | select(.id == "aliased-scout")] as $rows
    | ($rows | length) == 1
    and $rows[0].readable == false
    and ($rows[0].reason | test("symlink"))
    and $rows[0].body == ""' >/dev/null \
    || fail "a refused report directory was re-read instead of keeping its refusal: $(printf '%s' "$payload" | jq -c '[.reports.records[]|{id,readable,reason}]')"
  printf '%s' "$payload" | jq -e '
    [.degraded[] | select(.reason | test("symlink")) | .source] | any(test("report"))' >/dev/null \
    || fail "the refused report was not disclosed as degraded evidence"
  pass "a refused report directory keeps its discovery reason"
}

test_omitted_report_discovery_errors_are_counted_in_the_total() {
  local home payload
  home=$(make_home discovery-error-total)
  ln -s scout-one "$home/data/aliased-one"
  ln -s scout-one "$home/data/aliased-two"
  # One report row fits the bound, so only one refusal can be listed. The
  # refusals that did not fit are still owed to the total.
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_DASHBOARD_REPORTS=1 "$DASH" json) \
    || fail "a bounded report index with refusals broke collection"
  printf '%s' "$payload" | jq -e '
    .reports.total > .reports.shown
    and .reports.truncated == (.reports.total - .reports.shown)
    and .reports.total >= 3' >/dev/null \
    || fail "omitted report discovery errors were dropped from the report total: $(printf '%s' "$payload" | jq -c '.reports | {total,shown,truncated}')"
  pass "omitted report discovery errors stay counted in the report total"
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
    "kind=ship" "backend=herdr" "window=default:w1:p1" "worktree=$home" "harness=claude"
  SECONDS=0
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z FM_SNAPSHOT_HERDR_TIMEOUT=1 \
    "$DASH" json) || fail "the dashboard failed instead of returning bounded Herdr evidence"
  elapsed=$SECONDS
  [ "$elapsed" -lt 6 ] || fail "the local Herdr snapshot probe exceeded its bound: ${elapsed}s"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks
    | map(select(.id == "herdr-one"
      and .current_state.state == "unknown"
      and .current_state.source == "probe-failed"
      and .current_state.freshness == "degraded"
      and .endpoint.freshness == "degraded"
      and (.endpoint.reason | length) > 0))
    | length == 1' >/dev/null \
    || fail "the timed-out Herdr task was not disclosed as unknown"
  pass "Herdr-backed snapshot probes are bounded and preserve unknown evidence"
}

test_a_failed_herdr_probe_is_degraded_with_a_reason() {
  local home payload
  home=$(make_home failed-herdr)
  printf '#!/usr/bin/env bash\nexit 42\n' > "$home/fakebin/herdr"
  chmod +x "$home/fakebin/herdr"
  fm_write_meta "$home/state/herdr-one.meta" \
    "kind=ship" "backend=herdr" "window=default:w1:p1" "worktree=$home" "harness=claude"
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z "$DASH" json) \
    || fail "the dashboard failed instead of preserving failed Herdr evidence"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks
    | map(select(.id == "herdr-one"
      and .current_state.source == "probe-failed"
      and .current_state.freshness == "degraded"
      and .endpoint.freshness == "degraded"
      and (.endpoint.reason | length) > 0
      and (.current_state.detail | test("backend target gone"))))
    | length == 1' >/dev/null \
    || fail "a failed Herdr probe was not disclosed as degraded evidence"
  pass "failed Herdr probes remain degraded with their failure reason"
}

test_a_herdr_server_error_is_a_failed_probe_not_an_unknown_state() {
  local home payload
  home=$(make_home herdr-server-error)
  fm_write_meta "$home/state/herdr-one.meta" \
    "window=default:w1:p1" \
    "endpoint_task_id=herdr-one" \
    "worktree=$home/wt" \
    "harness=claude" \
    "kind=ship" \
    "backend=herdr"
  # Herdr answered, and its answer is an error: the server could not be reached.
  # That is a FAILED probe, not a successful probe that returned unknown.
  cat > "$home/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"error":{"code":"server_unavailable","message":"no server"}}'
SH
  chmod +x "$home/fakebin/herdr"
  payload=$(run_dash "$home" json) || fail "a Herdr server error broke collection"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks
    | map(select(.id == "herdr-one"))
    | length == 1
    and .[0].endpoint.exists == null
    and .[0].endpoint.freshness == "degraded"
    and (.[0].endpoint.reason | test("server_unavailable"))' >/dev/null \
    || fail "a Herdr error code was flattened into an unknown state without its reason"
  pass "a Herdr server error stays a degraded probe carrying its error code"
}

test_a_herdr_server_lost_between_probes_is_degraded_with_its_reason() {
  local home payload
  home=$(make_home herdr-lost-between-probes)
  fm_write_meta "$home/state/herdr-two.meta" \
    "window=default:w1:p1" \
    "endpoint_task_id=herdr-two" \
    "worktree=$home/wt" \
    "harness=claude" \
    "kind=secondmate" \
    "backend=herdr"
  # The endpoint probe succeeds and the server is gone by the agent probe, which
  # opens with its own pane read. That second failure must stay a failure.
  cat > "$home/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"pane get"*)
    if [ -e "$home/pane-probed" ]; then
      printf '%s\\n' '{"error":{"code":"server_gone"}}'
    else
      : > "$home/pane-probed"
      printf '%s\\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}'
    fi
    ;;
  *) printf '%s\\n' '{"result":{"agent":{"agent_status":"working"}}}' ;;
esac
SH
  chmod +x "$home/fakebin/herdr"
  payload=$(run_dash "$home" json) || fail "a lost Herdr server broke collection"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks
    | map(select(.id == "herdr-two"))
    | length == 1
    and .[0].endpoint.agent_alive == "unknown"
    and .[0].endpoint.freshness == "degraded"
    and (.[0].endpoint.reason | test("server_gone"))' >/dev/null \
    || fail "a Herdr server lost between probes was reported as an unknown agent"
  pass "a Herdr server lost between probes stays degraded with its reason"
}

test_a_herdr_agent_error_is_a_failed_probe_not_an_unknown_state() {
  local home payload
  home=$(make_home herdr-agent-error)
  fm_write_meta "$home/state/herdr-three.meta" \
    "window=default:w1:p1" \
    "endpoint_task_id=herdr-three" \
    "worktree=$home/wt" \
    "harness=claude" \
    "kind=secondmate" \
    "backend=herdr"
  cat > "$home/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"agent get"*) printf '%s\n' '{"error":{"code":"agent_unreachable"}}' ;;
  *) printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' ;;
esac
SH
  chmod +x "$home/fakebin/herdr"
  payload=$(run_dash "$home" json) || fail "a Herdr agent error broke collection"
  printf '%s' "$payload" | jq -e '
    .snapshot.tasks
    | map(select(.id == "herdr-three"))
    | length == 1
    and .[0].endpoint.agent_alive == "unknown"
    and .[0].endpoint.freshness == "degraded"
    and (.[0].endpoint.reason | test("agent_unreachable"))' >/dev/null \
    || fail "a Herdr agent error code was flattened into an unknown agent state"
  pass "a Herdr agent error stays a degraded probe carrying its error code"
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





test_collecting_evidence_never_creates_the_state_directory() {
  local home payload
  home=$(make_home read-only-collection)
  rm -rf "$home/state"
  payload=$(run_dash "$home" json) || fail "collection failed on a home with no state directory"
  [ ! -e "$home/state" ] \
    || fail "the read-only collector created the state directory it was observing"
  printf '%s' "$payload" | jq -e '.schema == "fm-dashboard.v1"' >/dev/null \
    || fail "collection over a stateless home did not return a payload"
  pass "collecting evidence never creates the state directory"
}

test_a_quiet_build_publishes_the_stamp_a_later_check_will_match() {
  local home payload stamp live
  home=$(make_home stable-freshness)
  live=$(run_dash "$home" stamp) || fail "the freshness stamp could not be read"
  payload=$(run_dash "$home" json) || fail "the dashboard payload could not be composed"
  stamp=$(printf '%s' "$payload" | jq -r '.freshness_stamp')
  [ "$stamp" = "$live" ] \
    || fail "an unchanged home published a stamp no later check would match"
  printf '%s' "$payload" | jq -e '[.degraded[] | select(.source == "evidence freshness")] | length == 0' \
    >/dev/null || fail "an unchanged home was reported as collected mid-change"
  pass "a quiet build publishes the stamp a later freshness check will match"
}

test_evidence_changed_mid_collection_is_disclosed_and_not_reused() {
  local home payload stamp live
  home=$(make_home torn-freshness)
  # Change a record while collection is in flight. The payload that comes back
  # holds pre-change evidence, so it must NOT carry a stamp that a later check
  # would accept as current - that is exactly how stale evidence gets served.
  ( sleep 3; printf 'working: changed mid-collection\n' >> "$home/state/worker-one.status" ) &
  payload=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-01T00:00:00Z \
    FM_SNAPSHOT_TEST_DELAY_AFTER_STAMP=9 "$DASH" json) \
    || fail "a mid-collection change broke collection"
  wait
  printf '%s' "$payload" | jq -e '
    [.degraded[] | select(.source == "evidence freshness")] | length == 1' >/dev/null \
    || fail "a mid-collection change was not disclosed"
  stamp=$(printf '%s' "$payload" | jq -r '.freshness_stamp')
  live=$(run_dash "$home" stamp) || fail "the freshness stamp could not be read"
  [ "$stamp" != "$live" ] \
    || fail "evidence collected mid-change published a stamp that would be reused as current"
  pass "evidence changed mid-collection is disclosed and cannot be reused as current"
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

test_the_payload_embeds_the_canonical_snapshot_unchanged
test_a_worker_carries_its_recorded_model_and_effort
test_a_missing_status_log_is_reported_not_degraded
test_free_form_backlog_rows_remain_valid_unstructured_evidence
test_record_reads_preserve_the_authoritative_source_path
test_report_discovery_applies_its_bound_during_enumeration
test_report_discovery_refusal_is_preserved_as_degraded_evidence
test_snapshot_rejects_invalid_record_read_bounds
test_event_history_is_bounded_and_discloses_what_it_dropped
test_an_unterminated_event_line_counts_as_one_record
test_status_lines_keep_their_recorded_verb_and_note
test_tail_collection_failure_is_disclosed_as_unavailable
test_status_read_failure_does_not_become_pr_absence
test_a_symlinked_status_log_is_refused_and_disclosed
test_the_dashboard_skips_remote_evidence_in_local_only_mode
test_a_report_symlinked_out_of_the_home_never_reaches_the_evidence
test_a_dangling_wake_queue_is_disclosed_as_unsafe
test_a_symlinked_secondmate_registry_is_disclosed_as_unsafe
test_a_large_report_is_truncated_and_says_so
test_a_task_linked_report_uses_the_global_report_cap
test_an_unreadable_task_report_preserves_its_refusal_reason
test_scout_report_discovery_failure_is_not_an_empty_success
test_a_refused_report_directory_keeps_its_discovery_reason
test_omitted_report_discovery_errors_are_counted_in_the_total
test_a_report_holding_binary_bytes_still_produces_valid_output
test_a_malformed_queued_notification_is_flagged_not_mis_parsed
test_queued_notifications_are_bounded
test_away_mode_and_missing_heartbeat_are_reported
test_the_local_token_record_is_read_or_disclosed_as_missing
test_the_dashboard_refuses_when_the_fleet_snapshot_fails
test_the_dashboard_refuses_an_invalid_bound_or_port
test_a_symlinked_evidence_root_is_refused_before_reading_it
test_a_symlinked_task_metadata_is_not_silently_dropped
test_a_symlinked_watcher_heartbeat_is_not_reported_as_healthy
test_a_herdr_backed_snapshot_times_out_its_local_probe
test_a_failed_herdr_probe_is_degraded_with_a_reason
test_a_malformed_herdr_endpoint_is_unknown_not_absent
test_a_herdr_server_error_is_a_failed_probe_not_an_unknown_state
test_a_herdr_server_lost_between_probes_is_degraded_with_its_reason
test_a_herdr_agent_error_is_a_failed_probe_not_an_unknown_state
test_a_malformed_tmux_endpoint_is_unknown_not_absent
test_malformed_zellij_and_cmux_endpoints_are_unknown_not_absent
test_a_quiet_build_publishes_the_stamp_a_later_check_will_match
test_evidence_changed_mid_collection_is_disclosed_and_not_reused
test_direct_json_build_is_bounded
test_collecting_evidence_never_creates_the_state_directory
