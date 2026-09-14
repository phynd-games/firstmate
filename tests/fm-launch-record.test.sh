#!/usr/bin/env bash
# tests/fm-launch-record.test.sh - the launch-record contract owned by
# bin/fm-launch-record.py, driven only through its executable interface.
#
# What is pinned here, and why each case can fail honestly:
#   1. Phases: intend -> created -> ready, each step refused from the wrong
#      phase, and every terminal verb (stop, exit, retire, fail, reconcile)
#      closing an open launch exactly once.
#   2. Duplicate requests: a second intent for the same subject is refused
#      (exit 3) while a launch is open, and accepted again only after a
#      terminal outcome; the prior outcome is retained under `previous`.
#   3. Concurrency: parallel intents for one subject yield exactly one winner.
#   4. Uncertain outcomes: a failure with an unknown or retained effect keeps the
#      launch open with a reconciliation obligation; none/cleaned closes it.
#   5. Launcher identity: pid plus start identity, so a live launcher reads
#      alive and a dead or recycled pid reads gone - never pid alone.
#   6. Privacy: identity and field keys come from an allowlist, credential-shaped
#      values are refused, launcher identity is stored only as a digest, and a
#      benign value passes (the positive control for the refusal).
#   7. Record safety: a symlinked or non-regular record path is refused, and a
#      read/write failure exits 1 rather than pretending.
#   8. pid-identity parity with bin/fm-wake-lib.sh's fm_pid_identity for a live
#      process, which is what lets the shell side and the record side agree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
FM_WAKE_LIB_NO_STATE_MKDIR=1 . "$ROOT/bin/fm-wake-lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by bin/fm-launch-record.py)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-launch-record-tests)
OWNER="$ROOT/bin/fm-launch-record.py"

lr() {  # <state-dir> <args...>
  local state=$1
  shift
  python3 "$OWNER" --state "$state" "$@"
}

new_state() {  # <name> -> echoes state dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

launch_id() {  # <state-dir> <task>
  lr "$1" get --task "$2" launch.id
}

# --- 1. phases --------------------------------------------------------------

test_phase_machine() {
  local state out rc id
  state=$(new_state phases)
  out=$(lr "$state" intend --task t1 --owner tester --origin fresh --field kind=scout)
  assert_contains "$out" "launch=l" "intend must print the minted launch id"
  id=$(launch_id "$state" t1)
  [ "$(lr "$state" get --task t1 launch.phase)" = intended ] || fail "a fresh launch must read intended"
  set +e
  lr "$state" ready --task t1 --launch "$id" --source probe >/dev/null 2>&1; rc=$?
  set -e
  expect_code 3 "$rc" "ready from intended must be refused: nothing is proven created"
  lr "$state" created --task t1 --launch "$id" --identity backend=herdr --identity session=default \
    --identity workspace_id=w1 --identity tab_id=w1:t2 --identity pane_id=w1:p2 --identity terminal_id=term_1 >/dev/null
  [ "$(lr "$state" get --task t1 launch.phase)" = created ] || fail "created must advance the phase"
  [ "$(lr "$state" get --task t1 launch.identity.pane_id)" = "w1:p2" ] || fail "created must bind the exact pane id"
  set +e
  lr "$state" created --task t1 --launch "$id" --identity pane_id=w1:p9 >/dev/null 2>&1; rc=$?
  set -e
  expect_code 3 "$rc" "created twice must be refused so an identity cannot be silently rebound"
  lr "$state" unready --task t1 --launch "$id" --reason "no agent yet" >/dev/null
  [ "$(lr "$state" get --task t1 launch.phase)" = created ] || fail "unready must keep the phase created"
  [ "$(lr "$state" get --task t1 launch.readiness.verdict)" = unconfirmed ] || fail "unready must record an unconfirmed verdict"
  lr "$state" ready --task t1 --launch "$id" --source herdr-agent-get --field readiness_status=idle >/dev/null
  [ "$(lr "$state" get --task t1 launch.phase)" = ready ] || fail "ready must advance the phase"
  set +e
  lr "$state" check --task t1 >/dev/null; rc=$?
  set -e
  expect_code 3 "$rc" "check must report an open launch with exit 3"
  lr "$state" stop --task t1 --current --reason "deliberate stop" >/dev/null
  [ "$(lr "$state" get --task t1 launch.phase)" = stopped ] || fail "stop must close the launch"
  set +e
  lr "$state" exit --task t1 --current --reason again >/dev/null 2>&1; rc=$?
  set -e
  expect_code 3 "$rc" "a terminal launch must refuse a second terminal verb"
  lr "$state" check --task t1 | grep -q '^open=none$' || fail "check must report open=none after a stop"
  pass "launch record: phases advance only in order and close exactly once"
}

test_wrong_launch_id_is_refused() {
  local state rc
  state=$(new_state wrong-id)
  lr "$state" intend --task t2 --owner tester --origin fresh >/dev/null
  set +e
  lr "$state" created --task t2 --launch l1.1.deadbeef --identity pane_id=w1:p1 >/dev/null 2>&1; rc=$?
  set -e
  expect_code 3 "$rc" "a phase change bound to another launch id must be refused"
  pass "launch record: every phase change is bound to the launch id the intent minted"
}

# --- 2. duplicates and retained outcomes ------------------------------------

test_duplicate_intent_refused_until_terminal() {
  local state rc out first
  state=$(new_state duplicate)
  lr "$state" intend --task t3 --owner tester --origin fresh >/dev/null
  first=$(launch_id "$state" t3)
  set +e
  out=$(lr "$state" intend --task t3 --owner tester --origin fresh 2>&1); rc=$?
  set -e
  expect_code 3 "$rc" "a second intent while a launch is open must be refused"
  assert_contains "$out" "phase=intended" "the refusal must print the open launch summary"
  assert_contains "$out" "launch=$first" "the refusal must name the open launch"
  lr "$state" fail --task t3 --launch "$first" --reason "nothing created" --effect none >/dev/null
  lr "$state" intend --task t3 --owner tester --origin fresh >/dev/null
  [ "$(launch_id "$state" t3)" != "$first" ] || fail "a new intent after a terminal outcome must mint a new id"
  out=$(lr "$state" show --task t3)
  assert_contains "$out" "previous launch=$first phase=failed" "the prior terminal outcome must be retained under previous"
  pass "launch record: duplicates refused while open, prior outcomes retained after"
}

test_concurrent_intents_have_one_winner() {
  local state i wins
  state=$(new_state concurrent)
  for i in 1 2 3 4 5 6 7 8; do
    ( lr "$state" intend --task t4 --owner "w$i" --origin fresh >/dev/null 2>&1 && printf 'win\n' >> "$state/wins" ) &
  done
  wait
  wins=$(grep -c win "$state/wins" 2>/dev/null || echo 0)
  [ "$wins" -eq 1 ] || fail "exactly one concurrent intent may win, got $wins"
  [ -f "$state/t4.launch.lock" ] || fail "the stable lock file must remain for later writers"
  pass "launch record: concurrent intents for one subject serialize to one winner"
}

test_lock_owner_death_and_empty_publication() {
  local state
  state=$(new_state lock-death)
  python3 - "$OWNER" "$state" <<'PYTEST' || fail "kernel lock recovery or exclusion failed"
import pathlib
import subprocess
import sys

owner, state = sys.argv[1:]
lock = pathlib.Path(state) / "locked.launch.lock"
holder = subprocess.Popen([sys.executable, "-c", """
import fcntl, sys, time
with open(sys.argv[1], 'w') as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    print('held', flush=True)
    time.sleep(60)
""", str(lock)], stdout=subprocess.PIPE, text=True)
command = [sys.executable, owner, '--state', state, 'intend', '--task', 'locked',
           '--owner', 'tester', '--origin', 'fresh']
try:
    assert holder.stdout.readline().strip() == 'held'
    inode = lock.stat().st_ino
    assert lock.read_bytes() == b''
    blocked = subprocess.run(command, capture_output=True, text=True)
    assert blocked.returncode == 1, blocked
    assert 'locked by another writer' in blocked.stderr, blocked.stderr
    assert not (pathlib.Path(state) / 'locked.launch').exists()
finally:
    holder.kill()
    holder.wait()
contenders = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
              for _ in range(8)]
results = [process.communicate() for process in contenders]
codes = [process.returncode for process in contenders]
assert codes.count(0) == 1 and codes.count(3) == 7, (codes, results)
assert lock.stat().st_ino == inode
PYTEST
  pass "launch record: an empty held lock excludes writers and owner death releases it without replacement"
}

test_launcher_args_capture_caller() {
  local state out
  state=$(new_state launcher-args)
  out=$(bash -c '
    set -eu
    FM_ROOT=$1 FM_STATE_OVERRIDE=$2
    FM_WAKE_LIB_NO_STATE_MKDIR=1 . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-launch-record-lib.sh"
    launcher_pid=${BASHPID:-$$}
    args=()
    while IFS= read -r line; do args+=("$line"); done < <(fm_launch_record_launcher_args "$launcher_pid")
    fm_launch_record intend --task caller --owner tester --origin fresh "${args[@]}" >/dev/null
    [ "$(fm_launch_record get --task caller launch.launcher.pid)" = "$launcher_pid" ]
    fm_launch_record check --task caller || [ "$?" = 3 ]
  ' _ "$ROOT" "$state") || fail "launcher arguments did not bind the caller"
  assert_contains "$out" "launcher=alive" "process substitution must not become the recorded launcher"
  pass "launch record: the shell seam captures the live caller before process substitution"
}

# --- 4. uncertain outcomes and reconciliation --------------------------------

test_uncertain_outcome_keeps_obligation() {
  local state id out rc
  state=$(new_state uncertain)
  lr "$state" intend --task t5 --owner tester --origin fresh >/dev/null
  id=$(launch_id "$state" t5)
  lr "$state" fail --task t5 --launch "$id" --reason "create response lost" --effect unknown --field "hint=tab fm-t5 may exist" >/dev/null
  [ "$(lr "$state" get --task t5 launch.phase)" = uncertain ] || fail "an unknown effect must leave the launch uncertain"
  [ "$(lr "$state" get --task t5 launch.reconcile.required)" = True ] || fail "an uncertain launch must carry a reconciliation obligation"
  set +e
  lr "$state" intend --task t5 --owner tester --origin fresh >/dev/null 2>&1; rc=$?
  set -e
  expect_code 3 "$rc" "an uncertain launch must block a blind duplicate intent"
  out=$(lr "$state" list --reconcile)
  assert_contains "$out" "subject=task:t5" "list --reconcile must surface the obligation"
  assert_contains "$out" "needs_reconcile=yes" "list --reconcile must flag the obligation"
  lr "$state" reconcile --task t5 --current --verdict absent --evidence "no fm-t5 tab in any session" >/dev/null
  [ "$(lr "$state" get --task t5 launch.phase)" = reconciled ] || fail "reconcile must close the uncertain launch"
  lr "$state" list --reconcile | grep -q 'task:t5' && fail "a reconciled launch must leave the obligation list"
  lr "$state" intend --task t5 --owner tester --origin fresh >/dev/null || fail "a new intent must be accepted after reconciliation"
  # Negative control for the obligation: a cleaned effect closes the launch.
  lr "$state" fail --task t5 --launch "$(launch_id "$state" t5)" --reason "aborted" --effect cleaned >/dev/null
  [ "$(lr "$state" get --task t5 launch.phase)" = failed ] || fail "a cleaned effect must close the launch as failed"
  lr "$state" list --reconcile | grep -q 'task:t5' && fail "a failed launch carries no obligation"
  pass "launch record: unknown or retained effects keep an obligation; none or cleaned close the launch"
}

test_retained_effect_is_uncertain() {
  local state id
  state=$(new_state retained)
  lr "$state" intend --task t6 --owner tester --origin fresh >/dev/null
  id=$(launch_id "$state" t6)
  lr "$state" created --task t6 --launch "$id" --identity pane_id=w1:p4 --identity session=default >/dev/null
  lr "$state" fail --task t6 --launch "$id" --reason "backlog transition failed after launch" --effect retained --field worktree=/tmp/x >/dev/null
  [ "$(lr "$state" get --task t6 launch.phase)" = uncertain ] || fail "a retained endpoint must read uncertain"
  [ "$(lr "$state" get --task t6 launch.identity.pane_id)" = "w1:p4" ] || fail "the retained identity must survive the failure"
  pass "launch record: a retained endpoint stays open with its exact identity"
}

# --- 5. launcher identity -----------------------------------------------------

test_launcher_alive_versus_gone() {
  local state out sleeper identity
  state=$(new_state launcher)
  sleep 300 &
  sleeper=$!
  identity=$(fm_pid_identity "$sleeper")
  lr "$state" intend --task t7 --owner tester --origin fresh --launcher-pid "$sleeper" --launcher-identity "$identity" >/dev/null
  out=$(lr "$state" check --task t7 || true)
  assert_contains "$out" "launcher=alive" "a live launcher with its identity must read alive"
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null || true
  out=$(lr "$state" check --task t7 || true)
  assert_contains "$out" "launcher=gone" "a dead launcher must read gone"
  out=$(lr "$state" list --reconcile)
  assert_contains "$out" "task:t7" "an intended launch whose launcher is gone needs reconciliation"
  # A recycled pid (same number, different identity) must also read gone.
  sleep 300 &
  sleeper=$!
  lr "$state" reconcile --task t7 --current --verdict launcher-gone --evidence test >/dev/null
  lr "$state" intend --task t8 --owner tester --origin fresh --launcher-pid "$sleeper" --launcher-identity "not-the-real-identity" >/dev/null
  out=$(lr "$state" check --task t8 || true)
  assert_contains "$out" "launcher=gone" "a live pid with a different start identity must read gone, never alive"
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null || true
  pass "launch record: launcher liveness is pid plus start identity, never pid alone"
}

test_pid_identity_parity_with_shell() {
  local sleeper shell_side record_side
  sleep 300 &
  sleeper=$!
  shell_side=$(fm_pid_identity "$sleeper")
  record_side=$(python3 "$OWNER" pid-identity "$sleeper")
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null || true
  [ -n "$shell_side" ] || fail "fm_pid_identity produced nothing for a live process"
  [ "$shell_side" = "$record_side" ] || fail "pid-identity must match fm_pid_identity byte for byte:"$'\n'"shell:  $shell_side"$'\n'"record: $record_side"
  pass "launch record: pid-identity matches fm_pid_identity for a live process"
}

# --- 6. privacy ----------------------------------------------------------------

test_privacy_allowlist_and_secret_shapes() {
  local state rc id
  state=$(new_state privacy)
  set +e
  lr "$state" intend --task t9 --owner tester --origin fresh --field command="claude --dangerously-skip-permissions" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "a field outside the allowlist (command) must be refused"
  set +e
  lr "$state" intend --task t9 --owner tester --origin fresh --field note="api_key=abcdefghijklmnop" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "a credential-shaped value must be refused"
  set +e
  lr "$state" intend --task t9 --owner tester --origin fresh --field note="AKIAABCDEFGHIJKLMNOP" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "an access-key-shaped value must be refused"
  [ ! -e "$state/t9.launch" ] || fail "a refused intent must write nothing"
  # Positive control: a benign note with the same key passes.
  lr "$state" intend --task t9 --owner tester --origin fresh --field note="ordinary launch note" --launcher-pid $$ --launcher-identity "secret-shaped-identity token=abcdefghijklmnopqrst" >/dev/null \
    || fail "a benign field value must be accepted"
  id=$(launch_id "$state" t9)
  grep -q 'abcdefghijklmnopqrst' "$state/t9.launch" && fail "the launcher identity must be stored only as a digest"
  grep -q 'pid_identity_sha256' "$state/t9.launch" || fail "the launcher identity digest must be recorded"
  set +e
  lr "$state" created --task t9 --launch "$id" --identity env=SECRET=1 >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "an identity key outside the allowlist must be refused"
  set +e
  lr "$state" created --task t9 --launch "$id" --identity "pane_id=$(printf 'w1:p1%600s' '')" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "an over-long value must be refused"
  pass "launch record: only allowlisted keys and benign, bounded values are stored"
}

# --- 7. record safety -----------------------------------------------------------

test_symlink_and_directory_records_are_refused() {
  local state rc
  state=$(new_state safety)
  ln -s /dev/null "$state/t10.launch"
  set +e
  lr "$state" intend --task t10 --owner tester --origin fresh >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "a symlinked record path must be refused with exit 1"
  mkdir -p "$state/t11.launch"
  set +e
  lr "$state" intend --task t11 --owner tester --origin fresh >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "a directory at the record path must be refused with exit 1"
  set +e
  lr "$TMP_ROOT/missing-state-dir" intend --task t12 --owner tester --origin fresh >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "a missing state directory must fail the write with exit 1, not create it"
  set +e
  lr "$state" show --task nothing >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "show on a missing record must exit 1"
  pass "launch record: unsafe record paths and unreadable records exit 1"
}

test_helper_subject_and_list() {
  local state out
  state=$(new_state helper)
  lr "$state" intend --helper docs-reader --owner fm-docs-reader.sh --origin ensure --field port=8601 >/dev/null
  [ -f "$state/.launch-docs-reader" ] || fail "a helper record must live at state/.launch-<name>"
  lr "$state" intend --task t13 --owner tester --origin fresh >/dev/null
  out=$(lr "$state" list --open)
  assert_contains "$out" "subject=helper:docs-reader" "list must include helper subjects"
  assert_contains "$out" "subject=task:t13" "list must include task subjects"
  pass "launch record: helpers and tasks share one contract and one listing"
}

test_atomic_retirement_removal() {
  local state first second rc
  state=$(new_state atomic-retire)
  lr "$state" intend --task retired --owner tester --origin fresh >/dev/null
  first=$(launch_id "$state" retired)
  lr "$state" exit --task retired --launch "$first" --reason finished >/dev/null
  lr "$state" retire --task retired --launch "$first" --reason cleanup >/dev/null || fail "settled launch could not retire"
  lr "$state" show --task retired --json | python3 -c 'import json,sys; r=json.load(sys.stdin); e=r["launch"]["history"][-1]; assert e["previous_outcome"]["phase"] == "exited"' || fail "retirement lost its prior outcome"
  lr "$state" intend --task retired --owner tester --origin fresh >/dev/null
  second=$(launch_id "$state" retired)
  lr "$state" retire --task retired --launch "$first" --reason stale --remove >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 3 "$rc" "stale retirement must preserve the new launch"
  [ "$(launch_id "$state" retired)" = "$second" ] || fail "stale retirement removed the successor"
  lr "$state" retire --task retired --launch "$second" --reason cleanup --remove >/dev/null || fail "atomic retirement failed"
  [ ! -e "$state/retired.launch" ] || fail "retirement did not remove the record"
  [ -f "$state/retired.launch.lock" ] || fail "retirement removed the stable lock"
  pass "launch record: retirement preserves prior outcomes and removes only its exact launch"
}

test_attempt_bound_create_journal() {
  local state first second out rc
  state=$(new_state create-journal)
  lr "$state" intend --task j1 --owner tester --origin fresh >/dev/null || fail "intent"
  first=$(launch_id "$state" j1)
  lr "$state" journal --task j1 --launch "$first" --init || fail "initialize journal"
  lr "$state" reconcile --task j1 --launch "$first" --verdict absent --pre-create-journal --evidence "no issued request" || fail "unissued intent should settle"
  lr "$state" intend --task j1 --owner tester --origin fresh >/dev/null || fail "successor intent"
  second=$(launch_id "$state" j1)
  lr "$state" journal --task j1 --launch "$second" --init || fail "successor journal"
  set +e
  out=$(lr "$state" journal --task j1 --launch "$first" --line 'issued task-tab' 2>&1); rc=$?
  set -e
  expect_code 3 "$rc" "old descendant must not issue against successor: $out"
  [ "$(cat "$state/.j1.create-issued")" = "launch $second" ] || fail "rejected predecessor modified journal"
  lr "$state" journal --task j1 --launch "$second" --line 'issued task-tab' || fail "current issuance"
  set +e
  out=$(lr "$state" reconcile --task j1 --launch "$second" --verdict absent --pre-create-journal --evidence "no effect" 2>&1); rc=$?
  set -e
  expect_code 3 "$rc" "issued request must block no-effect settlement: $out"
  set +e
  out=$(lr "$state" journal --task j1 --launch "$second" --init 2>&1); rc=$?
  set -e
  expect_code 3 "$rc" "reinitialization must not erase issued requests: $out"
  [ "$(lr "$state" get --task j1 launch.phase)" = intended ] || fail "unresolved issuance must remain open"
  pass "attempt-bound journal serializes issuance with no-effect settlement"
}

test_atomic_successor_publication() {
  local state
  state=$(new_state atomic-successor)
  python3 - "$OWNER" "$state" <<'PYTEST' || fail "atomic successor publication contract failed"
import json
import pathlib
import subprocess
import sys

owner, state = sys.argv[1:]
path = pathlib.Path(state) / '.launch-watcher'
base = [sys.executable, owner, '--state', state]
def run(*args, code=0):
    result = subprocess.run(base + list(args), capture_output=True, text=True)
    assert result.returncode == code, result
    return result.stdout

run('intend', '--helper', 'watcher', '--owner', 'tester', '--origin', 'cycle')
first = json.loads(path.read_text())['launch']['id']
run('created', '--helper', 'watcher', '--launch', first, '--identity-source', 'process',
    '--identity', 'pid=123', '--identity', 'pid_identity_sha256=' + 'a' * 64)
run('ready', '--helper', 'watcher', '--launch', first, '--source', 'watcher-beacon')
before = path.read_bytes()
predecessor = json.loads(before)['launch']
args = ['intend', '--helper', 'watcher', '--owner', 'tester', '--origin', 'successor',
        '--supersede', first, '--reason', 'next cycle', '--field', 'predecessor=123']
run(*args, '--field', 'note=api_key=abcdefghijklmnop', code=2)
assert path.read_bytes() == before
run(*args[:-4], code=2)
assert path.read_bytes() == before
fault = """
import errno, os, runpy, sys
sys.argv = sys.argv[1:]
def refuse_replace(source, destination):
    raise OSError(errno.EIO, 'injected publication failure')
os.replace = refuse_replace
runpy.run_path(sys.argv[0], run_name='__main__')
"""
result = subprocess.run([sys.executable, '-c', fault, owner, '--state', state] + args,
                        capture_output=True, text=True)
assert result.returncode == 1 and 'injected publication failure' in result.stderr, result
assert path.read_bytes() == before
assert 'launch=' + first in run('check', '--helper', 'watcher', code=3)
assert not list(path.parent.glob('.launch-watcher.tmp.*'))
contenders = [subprocess.Popen(base + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
              for _ in range(8)]
outputs = [process.communicate() for process in contenders]
codes = [process.returncode for process in contenders]
assert codes.count(0) == 1 and codes.count(3) == 7, (codes, outputs)
data = json.loads(path.read_text())
new = data['launch']
assert new['id'] != first and new['phase'] == 'intended', data
assert new['fields']['predecessor'] == '123'
assert len(data['previous']) == 1
old = data['previous'][0]
assert old['id'] == first and old['phase'] == 'superseded', data
assert old['identity'] == predecessor['identity']
assert old['launcher'] == predecessor['launcher']
assert old['readiness'] == predecessor['readiness']
assert old['history'][:-1] == predecessor['history']
assert old['history'][-1]['event'] == 'superseded'
after = path.read_bytes()
run(*args, code=3)
assert path.read_bytes() == after
run('exit', '--helper', 'watcher', '--launch', first, '--reason', 'finished', '--code', '0')
data = json.loads(path.read_text())
assert data['launch'] == new
assert data['previous'][0]['outcome']['exit']['code'] == 0
assert data['previous'][0]['history'][-1]['event'] == 'exited-after-supersede'
PYTEST
  pass "launch record: successor publication is atomic, retains history, and rejects stale concurrent writers"
}

test_atomic_successor_publication
test_attempt_bound_create_journal

test_atomic_retirement_removal
test_phase_machine
test_wrong_launch_id_is_refused
test_duplicate_intent_refused_until_terminal
test_concurrent_intents_have_one_winner
test_lock_owner_death_and_empty_publication
test_launcher_args_capture_caller
test_uncertain_outcome_keeps_obligation
test_retained_effect_is_uncertain
test_launcher_alive_versus_gone
test_pid_identity_parity_with_shell
test_privacy_allowlist_and_secret_shapes
test_symlink_and_directory_records_are_refused
test_helper_subject_and_list
