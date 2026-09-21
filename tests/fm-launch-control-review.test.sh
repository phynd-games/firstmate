#!/usr/bin/env bash
set -u
# shellcheck source=tests/fm-launch-spawn.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-launch-spawn.test.sh" fixture-library

new_case control-proof ctlproof
FM_SPAWN_READY_SECS=0 spawn --harness claude
expect_code 0 "$SPAWN_RC" "unregistered worker fixture must launch: $SPAWN_OUT"
first=$(record launch.id)
pane=$(record launch.identity.pane_id)
before=$(cksum < "$CASE_DIR/home/state/$CASE_ID.launch")
for verb in exit relaunch; do
  args=("$CASE_ID" "$verb")
  [ "$verb" != relaunch ] || args+=(--note "continue the fixture")
  out=$(in_case "$ROOT/bin/fm-control.sh" "${args[@]}" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "$verb accepted an unregistered open launch"
  assert_contains "$out" "no attempt-bound stop is proven" "$verb must report missing stop proof"
  [ "$(cksum < "$CASE_DIR/home/state/$CASE_ID.launch")" = "$before" ] || fail "$verb settled the unresolved attempt"
  [ "$(fake_tabs)" -eq 1 ] || fail "$verb replaced the present endpoint"
done
preset_agent "$pane" idle
out=$(in_case "$ROOT/bin/fm-control.sh" "$CASE_ID" exit 2>&1) || fail "a registered agent could not be stopped: $out"
assert_contains "$out" "stopped $CASE_ID" "delivered exit must report stopped"
[ "$(record launch.id)" = "$first" ] || fail "stop changed the attempt"
[ "$(record launch.phase)" = stopped ] || fail "delivered exit was not recorded"
out=$(in_case "$ROOT/bin/fm-control.sh" "$CASE_ID" exit 2>&1) || fail "a proven stop lost idempotence: $out"
assert_contains "$out" already-stopped "a settled launch may report already stopped"
pass "control refuses agent absence as stop evidence and records delivered stops"

new_case control-stop-write ctlwrite
printf idle > "$CASE_DIR/fake/agent-on-enter"
FM_SPAWN_READY_SECS=3 spawn --harness claude
expect_code 0 "$SPAWN_RC" "registered worker fixture must launch: $SPAWN_OUT"
first=$(record launch.id)
cat > "$CASE_DIR/record-python" <<'WRAPPER'
#!/usr/bin/env bash
for arg in "$@"; do [ "$arg" != stop ] || exit 1; done
exec "$FM_TEST_REAL_PYTHON" "$@"
WRAPPER
chmod +x "$CASE_DIR/record-python"
out=$(FM_LAUNCH_RECORD_PYTHON="$CASE_DIR/record-python" FM_TEST_REAL_PYTHON="$(command -v python3)" \
  in_case "$ROOT/bin/fm-control.sh" "$CASE_ID" relaunch --note "continue fixture" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "relaunch ignored an unrecorded stop"
assert_contains "$out" "proven stop could not settle launch" "record failure must block relaunch"
[ "$(record launch.id)" = "$first" ] || fail "record failure minted a replacement"
[ "$(record launch.phase)" = ready ] || fail "record failure erased the obligation"
[ "$(fake_tabs)" -eq 1 ] || fail "record failure allocated another endpoint"
[ "$(jq '.agent_status | length' "$CASE_DIR/fake/state.json")" -eq 0 ] || fail "relaunch submitted a replacement after failed bookkeeping"
assert_other_home_untouched control-proof
pass "control refuses replacement when its exact stop receipt cannot persist"
