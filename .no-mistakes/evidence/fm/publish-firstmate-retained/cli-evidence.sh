#!/usr/bin/env bash
set -eu
ROOT=$PWD
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/launch-fake-herdr.sh"
TMP_ROOT=$(fm_test_tmproot launch-cli-evidence)
trap fm_test_cleanup EXIT
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
case_home="$TMP_ROOT/scenario"
mkdir -p "$case_home/home/"{state,data,config} "$case_home/"{fake,block,fail,projects}
printf 'herdr\n' > "$case_home/home/config/backend"
printf 'off\n' > "$case_home/home/config/herdr-presentation-spaces"
printf 'manual\n' > "$case_home/home/config/backlog-backend"
fm_git_worktree "$case_home/proj" "$case_home/wt" fm/evidence
make_fake_herdr "$case_home" >/dev/null
printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$case_home/fake/state.json"
export PATH="$case_home/fakebin:$PATH" FM_HOME="$case_home/home" FM_ROOT_OVERRIDE="$ROOT"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config" FM_PROJECTS_OVERRIDE="$case_home/projects"
export FM_FAKE_HERDR_STATE="$case_home/fake/state.json" FM_HERDR_LOG="$case_home/fake/log" FM_FAKE_WORKTREE="$case_home/wt"
export FM_FAKE_WATCH_RECORD="$FM_HOME/state/evidence.launch" FM_FAKE_BLOCK_DIR="$case_home/block" FM_FAKE_FAIL_DIR="$case_home/fail"
export FM_HERDR_PS_BIN="$case_home/fakebin/fakeps" FM_SPAWN_NO_GUARD=1 FM_BACKEND_TEST_HARNESS=1 FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_READY_SECS=1
"$ROOT/bin/fm-brief.sh" evidence proj --scout --not-applicable 'configuration: task=evidence; target=tests/fm-launch-spawn.test.sh fixture; action=exercise the launch record' >/dev/null
printf 'Actual Firstmate CLI against the repository stateful fake Herdr; no real harness is launched.\n\n'
run_spawn() {
  printf '$ bin/fm-spawn.sh evidence <fixture-project> --scout "sh -c true"\n'
  set +e
  "$ROOT/bin/fm-spawn.sh" evidence "$case_home/proj" --scout 'sh -c true' 2>&1
  rc=$?
  set -e
  printf 'exit=%s\n\n' "$rc"
}
: > "$case_home/fail/tab-create.lost"
run_spawn
[ "$rc" != 0 ]
printf '$ bin/fm-launch-record.py --home <fixture-home> show --task evidence\n'
python3 "$ROOT/bin/fm-launch-record.py" --home "$FM_HOME" show --task evidence
cp "$FM_HOME/state/evidence.launch" "$EVIDENCE_DIR/lost-response.launch.json"
cp "$case_home/fake/state.json" "$EVIDENCE_DIR/lost-response.native-fixture.json"
before=$(jq '.tabs | length' "$case_home/fake/state.json")
rm "$case_home/fail/tab-create.lost"
run_spawn
[ "$rc" = 1 ]
after=$(jq '.tabs | length' "$case_home/fake/state.json")
[ "$before" = "$after" ]
printf 'Observed native fixture tab count: before retry=%s after retry=%s\n' "$before" "$after"
printf '\nCreate requests and the launch-record presence observed by the fake runtime:\n'
tr '\037' ' ' < "$case_home/fake/log" | grep -E '^(workspace|tab) create'
