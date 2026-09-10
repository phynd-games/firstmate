#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fm-launch-spawn.test.sh" fixture-library

new_case interrupted-metadata rl28
printf idle > "$CASE_DIR/fake/agent-on-enter"
cat > "$CASE_DIR/fakebin/record-python" <<'SH'
#!/usr/bin/env bash
"${FM_TEST_REAL_PYTHON:?}" "$@" || exit $?
for arg in "$@"; do
  if [ "$arg" = ready ]; then
    : > "$FM_TEST_PAUSE/ready"
    for _ in $(seq 1 300); do
      [ ! -e "$FM_TEST_PAUSE/hold" ] && break
      sleep 0.1
    done
    : > "$FM_TEST_PAUSE/done"
  fi
done
SH
chmod +x "$CASE_DIR/fakebin/record-python"
mkdir "$CASE_DIR/pause"
: > "$CASE_DIR/pause/hold"
FM_TEST_REAL_PYTHON=$(command -v python3) FM_LAUNCH_RECORD_PYTHON="$CASE_DIR/fakebin/record-python" \
  FM_TEST_PAUSE="$CASE_DIR/pause" FM_SPAWN_READY_SECS=3 in_case python3 - "$ROOT" "$CASE_DIR" "$CASE_ID" <<'PY' || fail 'could not interrupt after metadata publication'
import os, pathlib, subprocess, sys, time
root, case, task = sys.argv[1:]
case = pathlib.Path(case)
with (case / 'interrupted.out').open('w') as output:
    child = subprocess.Popen([root + '/bin/fm-spawn.sh', task, str(case / 'proj'), '--scout', '--harness', 'claude'], stdout=output, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 60
        while not (case / 'pause/ready').exists():
            assert child.poll() is None, (case / 'interrupted.out').read_text()
            assert time.monotonic() < deadline, 'ready publication timeout'
            time.sleep(.1)
        assert (case / 'home/state' / (task + '.meta')).is_file()
        assert (case / 'home/state' / ('.' + task + '.create-issued')).is_file()
    finally:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=5)
        (case / 'pause/hold').unlink(missing_ok=True)
    deadline = time.monotonic() + 5
    while not (case / 'pause/done').exists():
        assert time.monotonic() < deadline, 'record wrapper did not finish'
        time.sleep(.1)
PY
first=$(record launch.id)
firstpane=$(record launch.identity.pane_id)
cp "$CASE_DIR/home/state/.$CASE_ID.create-issued" "$CASE_DIR/predecessor-journal"
printf idle > "$CASE_DIR/fake/agent-on-enter"
out=$(FM_SPAWN_READY_SECS=3 in_case "$ROOT/bin/fm-control.sh" "$CASE_ID" relaunch --note 'continue fixture' 2>&1) || fail "interrupted relaunch refused: $out"
second=$(record launch.id)
[ "$second" != "$first" ] || fail 'relaunch did not mint a successor'
[ "$(record launch.identity.pane_id)" = "$firstpane" ] || fail 'relaunch changed endpoint'
[ "$(fake_tabs)" -eq 1 ] || fail 'relaunch allocated another endpoint'
python3 - "$CASE_DIR/home/state/$CASE_ID.launch" "$first" <<'PY' || fail 'predecessor settlement evidence was not retained'
import json, sys
data = json.load(open(sys.argv[1]))
old = next(item for item in data['previous'] if item['id'] == sys.argv[2])
assert old['phase'] == 'stopped', old
event = next(item for item in old['history'] if item['event'] == 'journal-settled')
assert len(event['effects_digest']) == 64
assert any(item['state'] == 'retained' and item['identity']['pane_id'] == old['identity']['pane_id'] for item in event['effects']), event
PY
out=$(in_case python3 "$OWNER" --state "$CASE_DIR/home/state" effects --task "$CASE_ID" --launch "$second" 2>&1) || fail "successor effects rejected predecessor evidence: $out"
out=$(in_case "$ROOT/bin/fm-control.sh" "$CASE_ID" exit 2>&1) || fail "successor stop failed: $out"
mkdir -p "$CASE_DIR/home/data/$CASE_ID"
printf '# report\n\nDone.\n' > "$CASE_DIR/home/data/$CASE_ID/report.md"
in_case "$ROOT/bin/fm-captain-hold.sh" complete "$CASE_ID" --none >/dev/null 2>&1 || fail 'empty holds could not complete'
out=$(in_case "$ROOT/bin/fm-teardown.sh" "$CASE_ID" 2>&1) || fail "successor teardown failed: $out"
[ ! -e "$CASE_DIR/home/state/$CASE_ID.launch" ] || fail 'teardown retained launch record'
[ "$(fake_tabs)" -eq 0 ] || fail 'teardown left the adopted endpoint'
pass 'R28: interrupted publication relaunch retains predecessor evidence and permits successor retirement'

new_case unresolved-partial rl28partial
printf idle > "$CASE_DIR/fake/agent-on-enter"
FM_SPAWN_READY_SECS=3 spawn --harness claude
expect_code 0 "$SPAWN_RC" "partial fixture spawn failed: $SPAWN_OUT"
first=$(record launch.id)
workspace=$(record launch.identity.workspace_id)
response=$(in_case herdr tab create --workspace "$workspace" --label fixture-partial --session default) || fail 'partial native fixture could not be created'
tab=$(printf '%s' "$response" | jq -r '.result.tab.tab_id')
printf 'launch %s\nissued task-tab\npartial kind=task-tab workspace=%s tab=%s\n' "$first" "$workspace" "$tab" > "$CASE_DIR/home/state/.$CASE_ID.create-issued"
journal_before=$(cksum < "$CASE_DIR/home/state/.$CASE_ID.create-issued")
out=$(in_case "$ROOT/bin/fm-control.sh" "$CASE_ID" exit 2>&1) || fail "partial fixture stop failed: $out"
record_before=$(cksum < "$CASE_DIR/home/state/$CASE_ID.launch")
out=$(FM_SPAWN_READY_SECS=3 in_case "$ROOT/bin/fm-spawn.sh" "$CASE_ID" --relaunch 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'relaunch ignored an unresolved partial effect'
assert_contains "$out" 'partial create response requires inspected settlement' 'partial obligation must be reported'
[ "$(cksum < "$CASE_DIR/home/state/.$CASE_ID.create-issued")" = "$journal_before" ] || fail 'partial predecessor journal changed'
[ "$(cksum < "$CASE_DIR/home/state/$CASE_ID.launch")" = "$record_before" ] || fail 'partial predecessor was overwritten'
[ "$(fake_tabs)" -eq 2 ] || fail 'partial endpoint was replaced or closed'
in_case herdr tab close "$tab" --session default >/dev/null || fail 'exact partial fixture cleanup failed'
in_case python3 "$OWNER" --state "$CASE_DIR/home/state" reconcile --task "$CASE_ID" --launch "$first" \
  --verdict manual --evidence 'fixture partial tab closed by exact returned id; original stopped endpoint retained' >/dev/null \
  || fail 'stopped predecessor refused explicit inspected journal settlement'
assert_other_home_untouched 'relaunch journal recovery'
pass 'R28: a stopped predecessor retains unresolved partial effects and refuses a successor'
