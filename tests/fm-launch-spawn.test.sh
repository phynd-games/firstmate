#!/usr/bin/env bash
# tests/fm-launch-spawn.test.sh - the launch-record contract as the worker
# launch owners actually use it: bin/fm-spawn.sh (fresh and relaunch),
# bin/fm-control.sh (exit, relaunch), and bin/fm-teardown.sh (retire), driven
# end to end against a stateful fake `herdr` CLI plus a real git project and
# worktree, with no real backend and no real harness.
#
# The fake logs every CLI call together with whether the task's launch record
# existed at that instant, which is how "intent before creation" is proved
# rather than read from the code. Cases:
#   1. fresh spawn: no record before any create call, record present from the
#      first `workspace create` on, exact native ids bound after `tab create`,
#      readiness skipped under the harness reads unconfirmed, not ready
#   2. readiness: a registered agent reads ready (positive control); an
#      unregistered pane reads unconfirmed with the reason (negative control)
#   3. inventory refusal before any create -> failed with effect none
#   4. a structured Herdr refusal after the request was issued, with the exact
#      creation scope inventoried empty at once -> failed with effect none; a
#      structured error following an effect -> uncertain with the tab as the
#      known partial identity, never replaced automatically; a pre-call
#      journal write failure refuses the request before it leaves; a lost
#      answer -> uncertain with an obligation that no label
#      settles: the next spawn refuses (reporting the label inventory as a hint
#      only, live or not) until the record is settled explicitly with
#      `reconcile --verdict manual`, after which the spawn proceeds
#   5. launcher killed before creation -> intended, launcher gone, settled
#      absent from the launcher's own pre-create journal
#   6. launcher killed after creation -> created with identity; next spawn
#      replaces a husk only when Herdr's process-info shows an idle foreground
#      shell AND the adapter's strict proof shows no child process and a
#      sleeping shell; refuses a busy foreground (a launch may be in progress),
#      a helper that never leaves the shell's group, an attached child, a
#      partial container, and a live agent on that exact pane
#   7. record-write failure before creation refuses with nothing created;
#      after creation the spawn aborts, the endpoint is closed, and the record
#      reads failed/cleaned
#   8. control exit records stopped; relaunch stops the previous launch and
#      records a new ready launch on the same endpoint; teardown records
#      retired before removing the record and closes the pane
#   9. preservation: an unrelated home's records are byte-identical across
#      every failure, and an interrupted launch leaves its worktree untouched
#  10. no python3 on PATH refuses before any create call
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by bin/fm-launch-record.py)"; exit 0; }

# A leaked Herdr pane identity from the developer's terminal would make spawn
# resolve a launcher this fake never models.
herdr_forget_inherited_pane
unset HERDR_BIN_PATH CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

TMP_ROOT=$(fm_test_tmproot fm-launch-spawn-tests)
OWNER="$ROOT/bin/fm-launch-record.py"
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0

# --- fake herdr -----------------------------------------------------------------
# tests/launch-fake-herdr.sh owns the stateful fake `herdr` CLI, its call log
# with the record-present observation, and its fault injection.
# shellcheck source=tests/launch-fake-herdr.sh
. "$(dirname "${BASH_SOURCE[0]}")/launch-fake-herdr.sh"

# --- case world --------------------------------------------------------------------
# new_case <name> <id>: an isolated home (herdr declared, presentation off,
# manual backlog), a git project with an origin and a pre-made worktree the
# fake's `treehouse get` moves the pane into, an exempt scout brief, and a fresh
# fake state. Exports the environment the launch owners read; callers run the
# owners through `in_case`.
CASE_DIR=
CASE_ID=
new_case() {  # <name> <id>
  local name=$1 id=$2 dir="$TMP_ROOT/$1"
  CASE_DIR=$dir
  CASE_ID=$id
  rm -rf "$dir"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake" "$dir/block" "$dir/fail" "$dir/projects"
  printf 'herdr\n' > "$dir/home/config/backend"
  printf 'off\n' > "$dir/home/config/herdr-presentation-spaces"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  fm_git_worktree "$dir/proj" "$dir/wt" "fm/$id"
  make_fake_herdr "$dir" >/dev/null
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$dir/fake/state.json"
  : > "$dir/fake/log"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" "$ROOT/bin/fm-brief.sh" "$id" proj --scout \
    --not-applicable "configuration: task=$id; target=tests/fm-launch-spawn.test.sh fixture; action=exercise the launch record" >/dev/null \
    || fail "$name: scout brief could not be written"
}

in_case() {  # <command...> - run in the current case's environment
  # shellcheck disable=SC2030 # the subshell-local PATH is the point.
  ( export PATH="$CASE_DIR/fakebin:$PATH" FM_HOME="$CASE_DIR/home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$CASE_DIR/home/state" FM_DATA_OVERRIDE="$CASE_DIR/home/data" \
      FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" FM_PROJECTS_OVERRIDE="$CASE_DIR/projects" \
      FM_FAKE_HERDR_STATE="$CASE_DIR/fake/state.json" FM_HERDR_LOG="$CASE_DIR/fake/log" \
      FM_FAKE_WORKTREE="$CASE_DIR/wt" FM_FAKE_WATCH_RECORD="$CASE_DIR/home/state/$CASE_ID.launch" \
      FM_FAKE_BLOCK_DIR="$CASE_DIR/block" FM_FAKE_FAIL_DIR="$CASE_DIR/fail" \
      FM_HERDR_PS_BIN="$CASE_DIR/fakebin/fakeps" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=3 \
      FM_SPAWN_NO_GUARD=1 FM_BACKEND_TEST_HARNESS=1 FM_GATE_REFUSE_BYPASS=1
    "$@" )
}

spawn() {  # [spawn args...] -> stdout+stderr in $SPAWN_OUT, rc in $SPAWN_RC
  local out
  set +e
  out=$(in_case "$ROOT/bin/fm-spawn.sh" "$CASE_ID" "$CASE_DIR/proj" --scout "$@" 2>&1)
  SPAWN_RC=$?
  set -e
  SPAWN_OUT=$out
}

record() {  # <field> - dotted field of the current case's record
  python3 "$OWNER" --state "$CASE_DIR/home/state" get --task "$CASE_ID" "$1" 2>/dev/null || printf ''
}

record_show() {
  python3 "$OWNER" --state "$CASE_DIR/home/state" show --task "$CASE_ID" 2>&1 || true
}

fake_log() {  # human-readable call log
  tr '\037' ' ' < "$CASE_DIR/fake/log"
}

preset_agent() {  # <pane> <status>
  local tmp="$CASE_DIR/fake/state.json.tmp"
  jq --arg p "$1" --arg s "$2" '.agent_status[$p] = $s' "$CASE_DIR/fake/state.json" > "$tmp" && mv "$tmp" "$CASE_DIR/fake/state.json"
}

fake_tabs() {
  jq '.tabs | length' "$CASE_DIR/fake/state.json"
}

# Unrelated-home tripwire (G11): a second home with its own record whose bytes
# must never change, however the case under test fails.
OTHER_HOME="$TMP_ROOT/other-home"
mkdir -p "$OTHER_HOME/state"
python3 "$OWNER" --state "$OTHER_HOME/state" intend --task bystander --owner tester --origin fresh >/dev/null
OTHER_DIGEST=$(cksum < "$OTHER_HOME/state/bystander.launch")
assert_other_home_untouched() {  # <label>
  [ "$(cksum < "$OTHER_HOME/state/bystander.launch")" = "$OTHER_DIGEST" ] || fail "$1: the unrelated home's record changed"
}

# Kill the spawn while the fake blocks at <key>; returns after the spawn is dead.
spawn_killed_at() {  # <block-key>
  local key=$1
  : > "$CASE_DIR/block/$key"
  in_case "$ROOT/bin/fm-spawn.sh" "$CASE_ID" "$CASE_DIR/proj" --scout "sh -c true" >"$CASE_DIR/killed.out" 2>&1 &
  for _ in $(seq 1 300); do
    if grep -q "^$(printf '%s' "$key" | tr '-' '\037')" "$CASE_DIR/fake/log" 2>/dev/null; then break; fi
    sleep 0.1
  done
  sleep 0.3
  pgrep -f "fm-spawn.sh $CASE_ID " >/dev/null || fail "spawn for $CASE_ID was not found running while the fake blocked at $key"
  # SIGKILL the whole spawn process chain: the launcher runs its adapter calls
  # inside command substitutions, and an orphaned subshell would otherwise
  # carry on past the block and create on the dead launcher's behalf.
  pkill -9 -f "fm-spawn.sh $CASE_ID " || true
  rm -f "$CASE_DIR/block/$key"
  wait 2>/dev/null || true
  sleep 0.3
}

# --- 1. fresh spawn -------------------------------------------------------------------

test_fresh_spawn_records_intent_before_creation_and_native_identity() {
  local log first_create pre
  new_case fresh sp1
  spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "fresh spawn should succeed: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned sp1 harness=sh kind=scout" "spawn must report success"
  assert_contains "$SPAWN_OUT" "launch=l" "the success line must name the launch id"
  assert_contains "$SPAWN_OUT" "readiness=unconfirmed" "readiness skipped under the harness must read unconfirmed, never ready"
  log=$(fake_log)
  first_create=$(printf '%s\n' "$log" | grep -n -m1 -E '^(workspace|tab) create' | cut -d: -f1)
  [ -n "$first_create" ] || fail "the fake saw no create call"
  pre=$(printf '%s\n' "$log" | head -n $((first_create - 1)))
  [ -n "$pre" ] || fail "no Herdr call preceded the first create; the ordering proof is vacuous"
  # The record must not pre-exist (the first probe sees none), it must appear
  # before the first create (every create sees it), and the probes between the
  # intent and the create legitimately see it too.
  printf '%s\n' "$log" | head -n 1 | grep -q 'record=absent' || fail "the launch record pre-existed the spawn:"$'\n'"$pre"
  printf '%s\n' "$pre" | grep -q 'record=absent' || fail "no pre-intent probe was observed; the ordering proof is vacuous"
  printf '%s\n' "$log" | grep -E '^(workspace|tab) create' | grep -q 'record=absent' && fail "a create call ran without the launch record on disk:"$'\n'"$log"
  [ "$(record launch.phase)" = created ] || fail "phase after spawn should be created, got '$(record launch.phase)'"
  [ "$(record launch.identity.pane_id)" = "$(grep '^herdr_pane_id=' "$CASE_DIR/home/state/sp1.meta" | cut -d= -f2)" ] || fail "the record's pane must equal the task record's pane"
  [ "$(record launch.identity.tab_id)" = "$(grep '^herdr_tab_id=' "$CASE_DIR/home/state/sp1.meta" | cut -d= -f2)" ] || fail "the record's tab must equal the task record's tab"
  [ "$(record launch.identity.terminal_id)" = "$(grep '^herdr_terminal_id=' "$CASE_DIR/home/state/sp1.meta" | cut -d= -f2)" ] || fail "the record's terminal must equal the task record's terminal"
  [ "$(record launch.identity_source)" = native-response ] || fail "a fresh spawn's identity must come from the native create response"
  [ "$(record launch.readiness.verdict)" = unconfirmed ] || fail "readiness must be recorded unconfirmed when not polled"
  [ ! -e "$CASE_DIR/home/state/.sp1.create-issued" ] || fail "the transient create-note file must not outlive the spawn"
  assert_other_home_untouched "fresh spawn"
  pass "spawn: intent precedes the first Herdr create and the record binds the exact native ids"
}

# --- 2. readiness -------------------------------------------------------------------

test_readiness_positive_and_negative_controls() {
  new_case ready-yes sp2
  printf working > "$CASE_DIR/fake/agent-on-enter"
  FM_SPAWN_READY_SECS=3 spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "spawn with a registering agent should succeed: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "readiness=ready" "a registered agent must read ready"
  [ "$(record launch.phase)" = ready ] || fail "the record must reach ready"
  [ "$(record launch.readiness.source)" = herdr-agent-get ] || fail "readiness must name its native source"
  [ "$(record launch.fields.readiness_status)" = working ] || fail "readiness must record the native status observed"
  new_case ready-no sp3
  FM_SPAWN_READY_SECS=1 spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "spawn without a registering agent still launches: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "readiness=unconfirmed" "an unregistered pane must not read ready"
  assert_contains "$SPAWN_OUT" "no agent was confirmed" "the unconfirmed readiness must be reported"
  [ "$(record launch.phase)" = created ] || fail "an unconfirmed launch must stay created"
  assert_contains "$(record launch.readiness.reason)" "no registered agent within 1s" "the unconfirmed reason must be recorded"
  pass "spawn: readiness is native agent registration - ready with an agent, unconfirmed without"
}

# --- 3. and 4. creation failures --------------------------------------------------------

test_inventory_refusal_before_create_is_a_plain_failure() {
  new_case refuse-inventory sp4
  printf '{"error":{"code":"internal","message":"boom"}}\n' > "$CASE_DIR/fail/tab-list"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a failed tab inventory must refuse the spawn"
  fake_log | grep -q 'tab create' && fail "no tab create may follow a failed inventory"
  [ "$(record launch.phase)" = failed ] || fail "a refusal before any create must read failed, got '$(record launch.phase)'"
  [ "$(record launch.outcome.effect)" = none ] || fail "a refusal before any create has effect none"
  assert_other_home_untouched "inventory refusal"
  pass "spawn: a Herdr refusal before any create request is a closed failure with no obligation"
}

test_issued_create_without_result_is_uncertain_and_settles_from_the_label() {
  local first pane
  new_case refuse-create sp5
  printf '{"error":{"code":"internal","message":"boom"}}\n' > "$CASE_DIR/fail/tab-create"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a refused tab create must refuse the spawn"
  [ "$(record launch.phase)" = failed ] || fail "a structured Herdr refusal is a closed failure, got '$(record launch.phase)'"
  [ "$(record launch.outcome.effect)" = none ] || fail "a refused create has effect none"
  [ "$(record launch.reconcile.required)" = False ] || fail "a refused create carries no obligation"
  assert_contains "$(record launch.fields.hint)" "refused task-tab code=internal verified=workspace:" "the hint must record Herdr's refusal and the scope inventoried empty"
  # A structured error following an effect: the tab exists anyway. The
  # inventory finds it, the launch reads uncertain with the tab as its known
  # partial identity, and the next spawn refuses to replace it automatically.
  new_case refuse-with-effect sp20
  printf '{"error":{"code":"internal","message":"boom after create"}}\n' > "$CASE_DIR/fail/tab-create"
  : > "$CASE_DIR/fail/tab-create.effect"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "an error after an effect must refuse the spawn"
  [ "$(record launch.phase)" = uncertain ] || fail "an error following an effect must read uncertain, got '$(record launch.phase)'"
  [ "$(record launch.fields.container)" = effect-tab ] || fail "the known partial identity must be recorded as the effect tab, got '$(record launch.fields.container)'"
  [ -n "$(record launch.identity.tab_id)" ] || fail "the created tab's id must be retained"
  rm -f "$CASE_DIR/fail/tab-create" "$CASE_DIR/fail/tab-create.effect"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a partial container must not be replaced automatically: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "bound to a partial container (effect-tab" "the refusal must name the partial container"
  fake_log | grep -q 'create' && fail "no create may be issued over an unsettled partial container"
  # The pre-call journal write fails: the request must not leave. The journal
  # is made read-only while the fake blocks at the first inventory call, which
  # runs after the spawn created it and before its first create request.
  new_case journal-unwritable sp21
  : > "$CASE_DIR/block/workspace-list"
  in_case "$ROOT/bin/fm-spawn.sh" sp21 "$CASE_DIR/proj" --scout "sh -c true" >"$CASE_DIR/journal.out" 2>&1 &
  for _ in $(seq 1 300); do
    grep -q "^workspace.list" "$CASE_DIR/fake/log" 2>/dev/null && break
    sleep 0.1
  done
  [ -f "$CASE_DIR/home/state/.sp21.create-issued" ] || fail "the journal must exist before the first Herdr call"
  chmod 0444 "$CASE_DIR/home/state/.sp21.create-issued"
  rm -f "$CASE_DIR/block/workspace-list"
  wait 2>/dev/null || true
  out=$(cat "$CASE_DIR/journal.out")
  assert_contains "$out" "could not record the home-workspace request; refusing to create" "a failed pre-call journal write must refuse the request"
  fake_log | grep -q 'create' && fail "no create request may leave when its journal line could not be written"
  [ "$(record launch.phase)" = failed ] || fail "a refused request with nothing issued is a closed failure, got '$(record launch.phase)'"
  chmod 0644 "$CASE_DIR/home/state/.sp21.create-issued" 2>/dev/null || true
  # Lost response: the tab exists, the CLI answered garbage.
  new_case lost-response sp6
  : > "$CASE_DIR/fail/tab-create.lost"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a lost create response must refuse the spawn"
  [ "$(record launch.phase)" = uncertain ] || fail "a lost response must read uncertain"
  [ "$(record launch.reconcile.required)" = True ] || fail "a lost response must carry an obligation"
  assert_contains "$(record launch.reconcile.hint)" "fm-sp6" "the hint must name the exact label"
  first=$(record launch.id)
  [ "$(jq '[.tabs[] | select(.label == "fm-sp6")] | length' "$CASE_DIR/fake/state.json")" -eq 1 ] || fail "the lost create must have left exactly one task tab behind"
  rm -f "$CASE_DIR/fail/tab-create.lost"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "an identity-less open record must refuse the next spawn until settled explicitly: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "no recorded native identity" "the refusal must say why"
  assert_contains "$SPAWN_OUT" "a tab labeled fm-sp6 exists at" "the label inventory is reported as a hint"
  assert_contains "$SPAWN_OUT" "a label is a hint, not ownership" "a label match must not be adopted"
  assert_contains "$SPAWN_OUT" "reconcile --task sp6 --current --verdict manual" "the refusal must name the exact settlement command"
  fake_log | grep -q 'create' && fail "no create may be issued while the obligation is open"
  [ "$(record launch.phase)" = uncertain ] || fail "the obligation must remain until settled explicitly"
  python3 "$OWNER" --state "$CASE_DIR/home/state" reconcile --task sp6 --current --verdict manual \
    --evidence "inspected the lab: the leftover fm-sp6 tab hosts an idle shell" >/dev/null || fail "explicit settlement must be accepted"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "after explicit settlement the spawn must proceed: $SPAWN_OUT"
  record_show | grep -q "previous launch=$first phase=reconciled" || fail "the settled launch must be retained as reconciled"
  [ "$(record launch.phase)" = created ] || fail "the replacement launch must be created"
  # Same lost response, but the leftover tab now hosts a live agent: still a
  # hint, still a refusal, and never a create.
  new_case lost-live sp7
  : > "$CASE_DIR/fail/tab-create.lost"
  spawn "sh -c true"
  rm -f "$CASE_DIR/fail/tab-create.lost"
  pane=$(jq -r '.tabs[] | select(.label == "fm-sp7") | .pane_id' "$CASE_DIR/fake/state.json")
  preset_agent "$pane" working
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a live agent on the leftover tab must refuse a duplicate"
  assert_contains "$SPAWN_OUT" "native agent state: alive" "the hint must report the live agent"
  assert_contains "$SPAWN_OUT" "settle the record with" "the refusal must still route to explicit settlement"
  fake_log | grep -q 'create' && fail "no create may be issued while a live agent holds the task's label"
  [ "$(record launch.phase)" = uncertain ] || fail "the obligation must remain while the live agent is unresolved"
  assert_other_home_untouched "lost response"
  pass "spawn: a refused create is a closed failure; a lost answer stays an obligation no label settles, until settled explicitly"
}

# --- 5. and 6. launcher interruption -------------------------------------------------------

test_launcher_killed_before_creation() {
  new_case kill-before sp8
  spawn_killed_at workspace-list
  [ "$(record launch.phase)" = intended ] || fail "a launcher killed before creation must leave an intended record, got '$(record launch.phase)'"
  python3 "$OWNER" --state "$CASE_DIR/home/state" check --task sp8 2>/dev/null | grep -q '^launcher=gone$' || fail "the dead launcher must read gone"
  python3 "$OWNER" --state "$CASE_DIR/home/state" list --reconcile | grep -q 'task:sp8' || fail "an intended launch with a gone launcher needs reconciliation"
  [ "$(fake_tabs)" -eq 0 ] || fail "nothing may exist in Herdr when the launcher died before creating"
  [ -d "$CASE_DIR/wt/.git" ] || [ -f "$CASE_DIR/wt/.git" ] || fail "the pre-made worktree must be untouched"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "the next spawn must settle the orphaned intent and succeed: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "reconciled task sp8's earlier launch record (absent: launcher gone before any create request" "the launcher's own pre-create journal settles it as absent"
  # The same dead launcher without its journal is unknown, not absent.
  new_case kill-before-nojournal sp18
  spawn_killed_at workspace-list
  rm -f "$CASE_DIR/home/state/.sp18.create-issued"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "an intended record without its journal must refuse: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "no tab labeled fm-sp18 in any running session, which does not prove" "absence of a label match is not proof"
  fake_log | grep -q 'create' && fail "no create may be issued for an unsettled intended record"
  assert_other_home_untouched "killed before creation"
  pass "spawn: a launcher killed before creation leaves an intended record the next launch settles as absent"
}

test_launcher_killed_after_creation() {
  local pane
  new_case kill-after sp9
  spawn_killed_at pane-run
  [ "$(record launch.phase)" = created ] || fail "a launcher killed after creation must leave a created record, got '$(record launch.phase)'"
  pane=$(record launch.identity.pane_id)
  [ -n "$pane" ] || fail "the created record must carry the exact pane"
  [ "$(fake_tabs)" -eq 1 ] || fail "the created tab must be retained, never blindly removed"
  [ ! -e "$CASE_DIR/home/state/sp9.meta" ] || fail "no task record may exist for a launch that never published one"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "the next spawn must replace the agent-free pane and succeed: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "husk-replaced: native agent state dead and a proven quiescent idle shell" "the exact recorded pane must be classified natively before replacement"
  # An idle foreground with a child process attached to the shell (a launch
  # started in the background, or one that has not surfaced yet) is not
  # quiescent: the strict proof must refuse, and pass again once it is gone.
  new_case kill-after-child sp23
  spawn_killed_at pane-run
  pane=$(record launch.identity.pane_id)
  printf '40001 1 S\n40077 40001 S\n' > "$CASE_DIR/fake/ps-table"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "an idle shell with an attached child must refuse: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "not provably quiescent" "the refusal must name the missing quiescence proof"
  fake_log | grep -q 'create' && fail "no create may be issued while the shell has a child"
  rm -f "$CASE_DIR/fake/ps-table"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "a proven quiescent shell is replaced: $SPAWN_OUT"
  # A partial task workspace (its tab never created) is retained, never
  # replaced: modelled through the record owner because the fake does not
  # model the projected layout.
  new_case partial-workspace sp22
  launch=$(python3 "$OWNER" --state "$CASE_DIR/home/state" intend --task sp22 --owner fm-spawn.sh --origin fresh | sed 's/^launch=//')
  python3 "$OWNER" --state "$CASE_DIR/home/state" created --task sp22 --launch "$launch" --identity backend=herdr --identity session=default --identity workspace_id=w9 --identity tab_id=w9:t1 --identity pane_id=w9:p1 --field container=task-workspace >/dev/null || fail "partial container record could not be written"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a partial task workspace must refuse: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "bound to a partial container (task-workspace: workspace=w9" "the refusal must name the partial workspace"
  fake_log | grep -q 'create' && fail "no create may be issued over a partial task workspace"
  # A busy foreground (a harness that has not registered yet) is not a husk.
  new_case kill-after-busy sp17
  spawn_killed_at pane-run
  pane=$(record launch.identity.pane_id)
  : > "$CASE_DIR/fake/busy-$pane"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "an agent-free pane with a busy foreground must refuse: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "no registered agent but a foreground process is running" "the refusal must name the in-progress possibility"
  fake_log | grep -q 'create' && fail "no create may be issued while the recorded pane is busy"
  [ "$(record launch.phase)" = created ] || fail "the created record must be retained while the pane is busy"
  rm -f "$CASE_DIR/fake/busy-$pane"
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "once the foreground is idle the husk is replaced: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "husk-replaced" "an idle agent-free pane reconciles as a husk"
  # A helper that never leaves the shell's foreground group is not an idle
  # shell either: the settle window must run out into busy, never idle.
  new_case kill-after-helper sp19
  spawn_killed_at pane-run
  pane=$(record launch.identity.pane_id)
  : > "$CASE_DIR/fake/helper-$pane"
  : > "$CASE_DIR/fake/log"
  FM_BACKEND_HERDR_FOREGROUND_SETTLE_POLLS=3 spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a foreground helper that never settles must refuse: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "no registered agent but a foreground process is running" "the unsettled foreground must read busy"
  fake_log | grep -q 'create' && fail "no create may be issued while the foreground never settles"
  [ "$(record launch.phase)" = created ] || fail "the created record must be retained while the foreground never settles"
  rm -f "$CASE_DIR/fake/helper-$pane"
  # The recorded pane is gone by the next launch (closed by hand, or Herdr
  # lost it): presence, not agent state, must settle it as absent.
  new_case kill-after-gone sp15
  spawn_killed_at pane-run
  pane=$(record launch.identity.pane_id)
  in_case "$CASE_DIR/fakebin/herdr" pane close "$pane" --session default >/dev/null
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 0 "$SPAWN_RC" "a gone recorded pane must be settled as absent and the spawn succeed: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "absent: native endpoint presence missing for default:$pane" "a gone pane must reconcile as absent by presence"
  new_case kill-after-live sp10
  spawn_killed_at pane-run
  pane=$(record launch.identity.pane_id)
  preset_agent "$pane" idle
  : > "$CASE_DIR/fake/log"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a live agent on the recorded pane must refuse a duplicate launch"
  assert_contains "$SPAWN_OUT" "already has a live agent on its recorded endpoint default:$pane" "the refusal must name the exact recorded pane"
  fake_log | grep -q 'create' && fail "no create may be issued while the recorded pane hosts a live agent"
  [ "$(record launch.phase)" = created ] || fail "the created record must be retained while its agent lives"
  assert_other_home_untouched "killed after creation"
  pass "spawn: a launcher killed after creation leaves an exact created record; an idle husk is replaced, a busy pane and a live agent refuse"
}

# --- 7. record-write failures ----------------------------------------------------------------

test_record_write_failure_before_creation_refuses() {
  new_case write-fail-before sp11
  mkdir -p "$CASE_DIR/home/state/sp11.launch"
  spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "an unwritable launch record must refuse the spawn"
  assert_contains "$SPAWN_OUT" "refusing to launch without a durable launch record" "the refusal must say why"
  fake_log | grep -q 'create' && fail "nothing may be created when the intent cannot be recorded"
  [ ! -e "$CASE_DIR/home/state/sp11.meta" ] || fail "no task record may be published"
  pass "spawn: a record-write failure before creation refuses with nothing created"
  # The intent write itself failing (the record path is writable, the `intend`
  # command is what fails) must refuse the same way: the check above never
  # reaches that branch because an unwritable path already fails `check`.
  local wrap="$TMP_ROOT/wrap-intend"
  mkdir -p "$wrap"
  cat > "$wrap/python3" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = intend ]; then echo "fm-launch-record: injected intent write failure" >&2; exit 1; fi
done
exec "${FM_TEST_REAL_PYTHON:?}" "$@"
SH
  chmod +x "$wrap/python3"
  new_case intend-fail sp16
  FM_TEST_REAL_PYTHON=$(command -v python3) FM_LAUNCH_RECORD_PYTHON="$wrap/python3" spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a failed intent write must refuse the spawn"
  assert_contains "$SPAWN_OUT" "launch intent could not be recorded before creation" "the refusal must name the intent write"
  assert_contains "$SPAWN_OUT" "injected intent write failure" "the refusal must carry the record owner's detail"
  fake_log | grep -q 'create' && fail "nothing may be created when the intent write fails"
  [ ! -e "$CASE_DIR/home/state/sp16.meta" ] || fail "no task record may be published"
  [ ! -e "$CASE_DIR/home/state/sp16.launch" ] || fail "no launch record may remain after a failed intent write"
  pass "spawn: a failed intent write refuses before any Herdr create request"
}

test_record_write_failure_after_creation_aborts_and_cleans() {
  local wrap="$TMP_ROOT/wrap-created"
  mkdir -p "$wrap"
  cat > "$wrap/python3" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = created ]; then echo "fm-launch-record: injected write failure" >&2; exit 1; fi
done
exec "${FM_TEST_REAL_PYTHON:?}" "$@"
SH
  chmod +x "$wrap/python3"
  new_case write-fail-after sp12
  FM_TEST_REAL_PYTHON=$(command -v python3) FM_LAUNCH_RECORD_PYTHON="$wrap/python3" spawn "sh -c true"
  expect_code 1 "$SPAWN_RC" "a record-write failure after creation must abort the spawn"
  assert_contains "$SPAWN_OUT" "its launch record could not bind the native identity" "the abort must name the record failure"
  fake_log | grep -q 'pane close' || fail "the created endpoint must be closed on abort"
  [ "$(fake_tabs)" -eq 0 ] || fail "no endpoint may remain after the abort cleanup"
  [ "$(record launch.phase)" = failed ] || fail "a cleaned abort must read failed, got '$(record launch.phase)'"
  [ "$(record launch.outcome.effect)" = cleaned ] || fail "the confirmed cleanup must be recorded as cleaned"
  [ ! -e "$CASE_DIR/home/state/sp12.meta" ] || fail "no task record may be published"
  assert_other_home_untouched "write failure after creation"
  pass "spawn: a record-write failure after creation aborts, closes the endpoint, and records a cleaned failure"
}

# --- 8. control exit, relaunch, teardown -----------------------------------------------------

test_control_exit_relaunch_and_teardown_record_outcomes() {
  local first second wrap="$TMP_ROOT/wrap-log"
  new_case lifecycle sp13
  printf idle > "$CASE_DIR/fake/agent-on-enter"
  FM_SPAWN_READY_SECS=3 spawn --harness claude
  expect_code 0 "$SPAWN_RC" "claude spawn should succeed: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "readiness=ready" "the registering agent must read ready"
  first=$(record launch.id)
  # relaunch: stop the old agent, start a replacement in the same pane
  printf idle > "$CASE_DIR/fake/agent-on-enter"
  out=$(FM_SPAWN_READY_SECS=3 in_case "$ROOT/bin/fm-control.sh" sp13 relaunch --note "carry on" 2>&1) || fail "relaunch should succeed: $out"
  assert_contains "$out" "relaunched sp13 harness=claude" "relaunch must report success"
  second=$(record launch.id)
  [ "$second" != "$first" ] || fail "a relaunch must mint a new launch id"
  [ "$(record launch.origin)" = relaunch ] || fail "the replacement must record origin=relaunch"
  [ "$(record launch.phase)" = ready ] || fail "the replacement must read ready"
  [ "$(record launch.identity_source)" = adopted-record ] || fail "a relaunch adopts the recorded endpoint"
  [ "$(record launch.identity.pane_id)" = "$(grep '^herdr_pane_id=' "$CASE_DIR/home/state/sp13.meta" | cut -d= -f2)" ] || fail "the replacement must bind the same pane"
  record_show | grep -q "previous launch=$first phase=stopped reason=fm-control relaunch stopped the previous agent" || fail "the previous launch must read stopped by the relaunch"
  # exit: a deliberate stop
  out=$(in_case "$ROOT/bin/fm-control.sh" sp13 exit 2>&1) || fail "exit should succeed: $out"
  assert_contains "$out" "stopped sp13" "exit must report the stop"
  [ "$(record launch.phase)" = stopped ] || fail "exit must record stopped, got '$(record launch.phase)'"
  assert_contains "$(record launch.outcome.reason)" "fm-control exit" "the stop reason must name the control verb"
  # teardown: retire recorded before the record leaves with the other task state
  mkdir -p "$wrap"
  cat > "$wrap/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_WRAP_LOG:?}"
exec "${FM_TEST_REAL_PYTHON:?}" "$@"
SH
  chmod +x "$wrap/python3"
  mkdir -p "$CASE_DIR/home/data/sp13"
  printf '# report\n\nDone.\n' > "$CASE_DIR/home/data/sp13/report.md"
  in_case "$ROOT/bin/fm-captain-hold.sh" complete sp13 --none >/dev/null 2>&1 || fail "captain-hold completion should succeed for an empty inventory"
  : > "$CASE_DIR/wrap.log"
  out=$(FM_TEST_WRAP_LOG="$CASE_DIR/wrap.log" FM_TEST_REAL_PYTHON="$(command -v python3)" FM_LAUNCH_RECORD_PYTHON="$wrap/python3" \
    in_case "$ROOT/bin/fm-teardown.sh" sp13 2>&1) || fail "teardown should succeed: $out"
  assert_contains "$out" "teardown sp13 complete" "teardown must report completion"
  grep -q 'retire --task sp13 --current --reason teardown' "$CASE_DIR/wrap.log" || fail "teardown must record the retired outcome before removing the record"
  [ ! -e "$CASE_DIR/home/state/sp13.launch" ] || fail "teardown must remove the launch record with the task's other runtime state"
  [ ! -e "$CASE_DIR/home/state/sp13.launch.lock" ] || fail "teardown must remove the record lock"
  [ "$(fake_tabs)" -eq 0 ] || fail "teardown must close the endpoint"
  assert_other_home_untouched "lifecycle"
  pass "control and teardown: relaunch stops then re-records, exit records stopped, teardown records retired before removal"
}

# --- 10. dependency --------------------------------------------------------------------------

test_missing_python_refuses_before_any_create() {
  local bare="$TMP_ROOT/bare-path" dir entry name
  # Every executable on the real PATH except the Python interpreters, so the
  # only thing this case removes is the record owner's interpreter.
  mkdir -p "$bare"
  # shellcheck disable=SC2031 # the real PATH of this test process, not a subshell's.
  IFS=: read -r -a path_dirs <<< "$PATH"
  for dir in "${path_dirs[@]}"; do
    [ -d "$dir" ] || continue
    for entry in "$dir"/*; do
      [ -x "$entry" ] && [ ! -d "$entry" ] || continue
      name=$(basename "$entry")
      case "$name" in python|python3|python3.*|python3-*) continue ;; esac
      [ -e "$bare/$name" ] || ln -s "$entry" "$bare/$name"
    done
  done
  new_case no-python sp14
  set +e
  out=$(PATH="$bare" in_case "$ROOT/bin/fm-spawn.sh" sp14 "$CASE_DIR/proj" --scout "sh -c true" 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "a home without python3 must refuse the spawn"
  assert_contains "$out" "needs python3" "the refusal must name the missing interpreter"
  fake_log | grep -q 'create' && fail "nothing may be created when the record owner cannot run"
  pass "spawn: a missing python3 refuses before any Herdr create request"
}

test_fresh_spawn_records_intent_before_creation_and_native_identity
test_readiness_positive_and_negative_controls
test_inventory_refusal_before_create_is_a_plain_failure
test_issued_create_without_result_is_uncertain_and_settles_from_the_label
test_launcher_killed_before_creation
test_launcher_killed_after_creation
test_record_write_failure_before_creation_refuses
test_record_write_failure_after_creation_aborts_and_cleans
test_control_exit_relaunch_and_teardown_record_outcomes
test_missing_python_refuses_before_any_create
