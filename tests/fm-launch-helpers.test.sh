#!/usr/bin/env bash
# tests/fm-launch-helpers.test.sh - the launch-record contract as the
# Firstmate-owned long-lived helper launchers use it: the Herdr-hosted watcher
# continuity owner (bin/fm-herdr-supervisor.sh establish/retire) and the
# away-mode daemon launcher (bin/fm-afk-launch.sh start/stop), driven for real
# against the shared stateful fake `herdr` (tests/launch-fake-herdr.sh).
#
# Cases:
#   1. supervisor establish: the launch record's intent is on disk before the
#      `workspace create` request, the record binds the exact workspace, tab,
#      and pane the create response returned (equal to the supervisor's own
#      binding record), readiness comes from the pane process proof, and
#      retire records a stop
#   2. supervisor establish refused by Herdr: the launch reads failed with a
#      cleaned effect once the supervisor's own cleanup ran
#   3. away-mode launcher: intent precedes `workspace create`, the record binds
#      the daemon terminal's exact ids from the response, readiness is the
#      daemon's identity-bound lock, and stop records the stop
#   4. away-mode launcher refused by Herdr: an issued create with no usable
#      identity reads uncertain with an obligation, and nothing is retained
#      as a terminal record
# The supervisor mirror is best-effort by design (its own pending record is
# the cleanup authority), so these cases also prove the mirror never changes
# the supervisor's own outcome: establish still starts, and retire still
# retires, exactly as the supervisor suite asserts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"
# shellcheck source=tests/launch-fake-herdr.sh
. "$(dirname "${BASH_SOURCE[0]}")/launch-fake-herdr.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
FM_WAKE_LIB_NO_STATE_MKDIR=1 . "$ROOT/bin/fm-wake-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by bin/fm-launch-record.py)"; exit 0; }

herdr_forget_inherited_pane
unset HERDR_BIN_PATH

TMP_ROOT=$(fm_test_tmproot fm-launch-helpers-tests)
OWNER="$ROOT/bin/fm-launch-record.py"
LOOP_PIDS=()

cleanup() {
  local pid
  cleanup_watchers 2>/dev/null || true
  for pid in "${LOOP_PIDS[@]+"${LOOP_PIDS[@]}"}"; do
    kill -TERM "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
  done
  # A loop this suite started lives under its own temp root; end any that a
  # failed assertion left behind so no supervisor outlives the test.
  pkill -TERM -f "$TMP_ROOT/.*fm-herdr-supervisor.sh run" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

record() {  # <state-dir> <helper> <field>
  python3 "$OWNER" --state "$1" get --helper "$2" "$3" 2>/dev/null || printf ''
}

fake_log() {  # <case-dir>
  tr '\037' ' ' < "$1/fake/log"
}

# --- supervisor world -------------------------------------------------------------
# A home with Herdr declared and one in-flight task record (supervision is
# needed), a copied script root whose fm-watch-arm.sh is a counting stub that
# returns an actionable reason (the continuity loop then re-arms, exactly as the
# supervisor suite models it), and the shared fake Herdr. The launch-record
# owner is copied beside the scripts so the loop's own root can reach it.
new_supervisor_home() {  # <name> -> echoes home
  local name=$1 home="$TMP_ROOT/$1" root
  mkdir -p "$home/state" "$home/config" "$home/fake" "$home/block" "$home/fail"
  printf 'herdr\n' > "$home/config/backend"
  printf 'on\n' > "$home/config/herdr-supervisor"
  fm_write_meta "$home/state/inflight.meta" "window=default:w9:p9" "endpoint_task_id=inflight" "backend=herdr"
  make_fake_herdr "$home" >/dev/null
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$home/fake/state.json"
  : > "$home/fake/log"
  root="$home/root"
  mkdir -p "$root/bin"
  cp "$ROOT"/bin/*.sh "$ROOT"/bin/*.py "$root/bin/"
  cp -R "$ROOT/bin/backends" "$root/bin/"
  cat > "$root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
C="${FM_TEST_ARM_COUNT:?}"
n=$(( $(cat "$C" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$C"
echo "signal: /fake/state/task.status"
exit 0
SH
  chmod +x "$root/bin"/*.sh "$root/bin"/*.py
  printf '%s\n' "$home"
}

run_supervisor() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" \
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$home/root" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_FAKE_HERDR_STATE="$home/fake/state.json" \
  FM_HERDR_LOG="$home/fake/log" \
  FM_FAKE_WATCH_RECORD="$home/state/.launch-herdr-supervisor" \
  FM_FAKE_FAIL_DIR="$home/fail" \
  FM_FAKE_BLOCK_DIR="$home/block" \
  FM_TEST_ARM_COUNT="$home/arm.count" \
  FM_HERDR_WORKSPACE_CONTROL_HELPER="$home/fakebin/herdr-workspace-control" \
  FM_SUPERVISION_MODEL=extension \
  FM_HERDR_SUPERVISOR_READY_TIMEOUT=15 \
  FM_HERDR_SUPERVISOR_RETRY_BASE=0 \
  FM_HERDR_SUPERVISOR_RETRY_MAX=0 \
  FM_HERDR_SUPERVISOR_IDLE_INTERVAL=1 \
  FM_BACKEND_TEST_HARNESS=1 \
  HERDR_SESSION=default \
  "$home/root/bin/fm-herdr-supervisor.sh" "$@"
}

test_supervisor_establish_records_intent_identity_readiness_and_stop() {
  local home out log first_create pre state binding
  home=$(new_supervisor_home supervisor)
  out=$(run_supervisor "$home" ensure 2>&1) || fail "ensure should establish a supervisor: $out"
  assert_contains "$out" "herdr-supervisor: started" "the supervisor must start as before: $out"
  LOOP_PIDS+=("$(cat "$home/fake/loop-pid" 2>/dev/null || echo 0)")
  state="$home/state"
  log=$(fake_log "$home")
  first_create=$(printf '%s\n' "$log" | grep -n -m1 '^workspace create' | cut -d: -f1)
  [ -n "$first_create" ] || fail "the fake saw no workspace create"
  pre=$(printf '%s\n' "$log" | head -n $((first_create - 1)))
  printf '%s\n' "$pre" | grep -q 'record=absent' || fail "no pre-intent probe was observed; the ordering proof is vacuous"
  printf '%s\n' "$log" | grep '^workspace create' | grep -q 'record=absent' && fail "the supervisor's workspace create ran without the launch record on disk:"$'\n'"$log"
  [ "$(record "$state" herdr-supervisor launch.phase)" = ready ] || fail "the supervisor launch must read ready, got '$(record "$state" herdr-supervisor launch.phase)'"
  [ "$(record "$state" herdr-supervisor launch.readiness.source)" = herdr-pane-process-info ] || fail "readiness must come from the pane process proof"
  binding=$(grep -m1 '^pane=' "$state/.herdr-supervisor" | cut -d= -f2)
  [ -n "$binding" ] || fail "the supervisor's own binding record must name its pane"
  [ "$(record "$state" herdr-supervisor launch.identity.pane_id)" = "$binding" ] || fail "the launch record must bind the same pane as the supervisor's binding record"
  [ "$(record "$state" herdr-supervisor launch.identity.workspace_id)" = "$(grep -m1 '^workspace=' "$state/.herdr-supervisor" | cut -d= -f2)" ] || fail "the launch record must bind the same workspace"
  [ "$(record "$state" herdr-supervisor launch.identity.tab_id)" = "$(grep -m1 '^tab=' "$state/.herdr-supervisor" | cut -d= -f2)" ] || fail "the launch record must bind the same tab"
  [ "$(record "$state" herdr-supervisor launch.identity_source)" = native-response ] || fail "the identity must come from the native create response"
  out=$(run_supervisor "$home" retire --reason "test retire" 2>&1) || fail "retire should succeed: $out"
  assert_contains "$out" "herdr-supervisor: retired" "retire must report as before"
  [ "$(record "$state" herdr-supervisor launch.phase)" = stopped ] || fail "retire must record stopped, got '$(record "$state" herdr-supervisor launch.phase)'"
  assert_contains "$(record "$state" herdr-supervisor launch.outcome.reason)" "retired: test retire" "the stop reason must carry the retire reason"
  pass "supervisor: intent precedes workspace create, identity matches the binding record, readiness is the process proof, retire records a stop"
}

# A refused create is ambiguous to the supervisor itself: Herdr answered
# nothing usable, so it keeps its pending create intent for exact-label
# reconciliation rather than declaring nothing was created. The launch record
# mirrors that honestly - uncertain with an obligation - and never claims a
# cleaned failure the owner did not establish.
test_supervisor_create_refusal_records_the_owner_uncertainty() {
  local home out state
  home=$(new_supervisor_home supervisor-refused)
  printf '{"error":{"code":"internal","message":"boom"}}\n' > "$home/fail/workspace-create"
  out=$(run_supervisor "$home" ensure 2>&1) && fail "ensure should fail when Herdr refuses the workspace create: $out"
  assert_contains "$out" "FAILED" "the supervisor must report the failure as before"
  state="$home/state"
  [ -f "$state/.herdr-supervisor-pending-cleanup" ] || fail "the supervisor keeps its pending create intent after a refused create (its own contract)"
  [ ! -f "$state/.herdr-supervisor" ] || fail "the supervisor must not retain a binding after a refused create"
  [ "$(record "$state" herdr-supervisor launch.phase)" = uncertain ] || fail "the mirror must reflect the owner's retained uncertainty, got '$(record "$state" herdr-supervisor launch.phase)'"
  [ "$(record "$state" herdr-supervisor launch.reconcile.required)" = True ] || fail "an uncertain establish must carry an obligation"
  [ "$(record "$state" herdr-supervisor launch.outcome.effect)" = unknown ] || fail "the effect must be unknown while the owner's pending intent stands"
  pass "supervisor: a refused create mirrors the owner's retained pending intent as an uncertain launch"
}

# --- away-mode launcher world -------------------------------------------------------
# A home with Herdr declared, a captain pane pre-seeded in the fake (the pane
# the daemon would inject into), a harmless placeholder entry command, and the
# supervision claim lock free. The daemon's own readiness (its identity-bound
# lock) is modelled by the placeholder: with FM_AFK_LAUNCH_ENTRY set, the
# launcher's readiness check is the terminal's native presence.
new_afk_home() {  # <name> -> echoes home
  local name=$1 home="$TMP_ROOT/$1" tmp
  mkdir -p "$home/state" "$home/config" "$home/fake" "$home/block" "$home/fail"
  printf 'herdr\n' > "$home/config/backend"
  make_fake_herdr "$home" >/dev/null
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$home/fake/state.json"
  : > "$home/fake/log"
  # Seed the captain's own workspace and pane.
  tmp="$home/fake/state.json.tmp"
  jq '.workspaces += [{workspace_id:"w1",label:"captain",focused:true,active_tab_id:"w1:t2"}]
      | .tabs += [{tab_id:"w1:t2",label:"captain",workspace_id:"w1",pane_id:"w1:p2",focused:true,cwd:"/tmp"}]
      | .next = 3' "$home/fake/state.json" > "$tmp" && mv "$tmp" "$home/fake/state.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/entry.sh"
  chmod +x "$home/entry.sh"
  printf '%s\n' "$home"
}

run_afk() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" \
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_FAKE_HERDR_STATE="$home/fake/state.json" \
  FM_HERDR_LOG="$home/fake/log" \
  FM_FAKE_WATCH_RECORD="$home/state/.launch-afk-daemon" \
  FM_FAKE_FAIL_DIR="$home/fail" \
  FM_FAKE_BLOCK_DIR="$home/block" \
  FM_AFK_LAUNCH_ENTRY="$home/entry.sh" \
  FM_SUPERVISOR_TARGET="default:w1:p2" \
  FM_SUPERVISOR_BACKEND=herdr \
  FM_BACKEND_TEST_HARNESS=1 \
  HERDR_SESSION=default \
  "$ROOT/bin/fm-afk-launch.sh" "$@"
}

test_afk_launcher_records_intent_identity_readiness_and_stop() {
  local home out log first_create pre state pane rec_target
  home=$(new_afk_home afk)
  out=$(run_afk "$home" start 2>&1) || fail "away-mode start should succeed: $out"
  state="$home/state"
  [ -f "$state/.afk" ] || fail "away mode must be on after start"
  [ -f "$state/.afk-daemon-terminal" ] || fail "the daemon terminal record must exist after start"
  log=$(fake_log "$home")
  first_create=$(printf '%s\n' "$log" | grep -n -m1 '^workspace create' | cut -d: -f1)
  [ -n "$first_create" ] || fail "the fake saw no workspace create"
  pre=$(printf '%s\n' "$log" | head -n $((first_create - 1)))
  printf '%s\n' "$pre" | grep -q 'record=absent' || fail "no pre-intent probe was observed; the ordering proof is vacuous"
  printf '%s\n' "$log" | grep '^workspace create' | grep -q 'record=absent' && fail "the daemon workspace create ran without the launch record on disk:"$'\n'"$log"
  [ "$(record "$state" afk-daemon launch.phase)" = ready ] || fail "the daemon launch must read ready, got '$(record "$state" afk-daemon launch.phase)'"
  [ "$(record "$state" afk-daemon launch.readiness.source)" = daemon-lock-identity ] || fail "readiness must name the daemon's identity-bound lock"
  pane=$(record "$state" afk-daemon launch.identity.pane_id)
  rec_target=$(cut -f2 "$state/.afk-daemon-terminal")
  [ "default:$pane" = "$rec_target" ] || fail "the launch record's pane ($pane) must equal the terminal record's target ($rec_target)"
  [ "$(record "$state" afk-daemon launch.identity.workspace_id)" = "$(cut -f3 "$state/.afk-daemon-terminal")" ] || fail "the launch record must bind the terminal record's workspace"
  [ "$(record "$state" afk-daemon launch.identity.terminal_id)" = "$(cut -f5 "$state/.afk-daemon-terminal")" ] || fail "the launch record must bind the terminal record's terminal id"
  [ "$(record "$state" afk-daemon launch.identity_source)" = native-response ] || fail "the identity must come from the native create response"
  out=$(run_afk "$home" stop 2>&1) || fail "away-mode stop should succeed: $out"
  [ ! -f "$state/.afk" ] || fail "stop must clear away mode"
  [ "$(record "$state" afk-daemon launch.phase)" = stopped ] || fail "stop must record stopped, got '$(record "$state" afk-daemon launch.phase)'"
  fake_log "$home" | grep -q "^pane close $pane" || fail "stop must close the exact recorded pane"
  pass "away-mode launcher: intent precedes workspace create, identity matches the terminal record, readiness is the daemon lock, stop records a stop"
}

test_afk_launcher_create_refusal_is_uncertain_with_no_terminal_record() {
  local home out state
  home=$(new_afk_home afk-refused)
  printf '{"error":{"code":"internal","message":"boom"}}\n' > "$home/fail/workspace-create"
  out=$(run_afk "$home" start 2>&1) && fail "start should fail when Herdr refuses the workspace create: $out"
  state="$home/state"
  [ "$(record "$state" afk-daemon launch.phase)" = uncertain ] || fail "an issued create with no usable identity must read uncertain, got '$(record "$state" afk-daemon launch.phase)'"
  [ "$(record "$state" afk-daemon launch.reconcile.required)" = True ] || fail "the refused create must carry an obligation"
  [ ! -f "$state/.afk-daemon-terminal" ] || fail "no terminal record may be retained for a create that returned nothing usable"
  [ ! -f "$state/.afk" ] || fail "away mode must not stay on after a failed launch"
  # The next start settles the open launch (no live daemon lock) and succeeds.
  rm -f "$home/fail/workspace-create"
  : > "$home/fake/log"
  out=$(run_afk "$home" start 2>&1) || fail "the next start should settle the open launch and succeed: $out"
  [ "$(record "$state" afk-daemon launch.phase)" = ready ] || fail "the replacement launch must read ready"
  # The launcher settles an open launch whose daemon lock is not live as an
  # observed exit, then records the new launch; the old one is retained.
  python3 "$OWNER" --state "$state" show --helper afk-daemon | grep -q 'previous launch=.* phase=exited' \
    || fail "the uncertain launch must be retained as an observed exit"
  run_afk "$home" stop >/dev/null 2>&1 || true
  pass "away-mode launcher: a refused create stays uncertain with no terminal record, and the next start settles it"
}

# --- watcher cycle world -------------------------------------------------------------
# The real arm forks the real watcher into an isolated state directory (the
# shared wake fixture supplies the fake tmux and crew-state the watcher's
# triage needs). A python3 wrapper journals every launch-record command with
# whether the watcher's singleton lock existed at that moment, which is the
# ordering proof: intent is recorded while no watcher exists.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
ARM_PIDS=()
WRAP_LOG=
make_record_wrapper() {  # <dir> -> echoes the wrapper path; logs "<verb> lock=<present|absent>"
  local wrap="$1/wrap"
  mkdir -p "$wrap"
  cat > "$wrap/python3" <<'SH'
#!/usr/bin/env bash
verb=
for a in "$@"; do
  case "$a" in intend|created|ready|exit|fail|supersede|reconcile) verb=$a; break ;; esac
done
if [ -n "$verb" ]; then
  if [ -e "${FM_TEST_LOCK_PATH:?}" ]; then l=present; else l=absent; fi
  printf '%s lock=%s\n' "$verb" "$l" >> "${FM_TEST_WRAP_LOG:?}"
fi
exec "${FM_TEST_REAL_PYTHON:?}" "$@"
SH
  chmod +x "$wrap/python3"
  printf '%s\n' "$wrap/python3"
}
run_arm() {  # <state> <fakebin> <out> - starts the real arm; ARM_PID set
  PATH="$2:$PATH" FM_STATE_OVERRIDE="$1" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TEST_REAL_PYTHON="$(command -v python3)" FM_LAUNCH_RECORD_PYTHON="$WRAPPER" \
    FM_TEST_WRAP_LOG="$WRAP_LOG" FM_TEST_LOCK_PATH="$1/.watch.lock" \
    "$ROOT/bin/fm-watch-arm.sh" > "$3" &
  ARM_PID=$!
  ARM_PIDS+=("$ARM_PID")
}
wait_started() {  # <arm-out> -> echoes the started watcher pid
  local i=0 pid
  while [ "$i" -lt 200 ]; do
    pid=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1)
    [ -n "$pid" ] && { printf '%s\n' "$pid"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
wait_pid_gone() {  # <pid>
  local i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
cleanup_watchers() {
  local pid
  for pid in "${ARM_PIDS[@]+"${ARM_PIDS[@]}"}"; do
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
}
wrecord() {  # <state> <field>
  record "$1" watcher "$2"
}
wshow() {  # <state>
  python3 "$OWNER" --state "$1" show --helper watcher 2>&1 || true
}
sha_of() {  # <text>
  printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode("utf-8","surrogateescape")).hexdigest())'
}

test_watcher_cycle_records_intent_before_fork_identity_readiness_and_exit() {
  local dir state fakebin out pid
  dir=$(make_case watcher-cycle)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/arm.out"
  WRAPPER=$(make_record_wrapper "$dir"); WRAP_LOG="$dir/wrap.log"; : > "$WRAP_LOG"
  run_arm "$state" "$fakebin" "$out"
  pid=$(wait_started "$out") || fail "the arm did not start a watcher: $(cat "$out")"
  head -n 1 "$WRAP_LOG" | grep -q '^intend lock=absent$' || fail "intent must be recorded before any watcher exists, got: $(cat "$WRAP_LOG")"
  grep -q '^created ' "$WRAP_LOG" || fail "the forked child must be recorded"
  [ "$(wrecord "$state" launch.phase)" = ready ] || fail "a confirmed cycle must read ready, got '$(wrecord "$state" launch.phase)'"
  [ "$(wrecord "$state" launch.identity.pid)" = "$pid" ] || fail "the record must bind the started watcher's pid ($pid), got '$(wrecord "$state" launch.identity.pid)'"
  [ -n "$(wrecord "$state" launch.identity.pid_identity_sha256)" ] || fail "the record must bind the child's start identity digest"
  [ "$(wrecord "$state" launch.readiness.source)" = watcher-beacon ] || fail "readiness must come from the beacon confirmation"
  [ "$(wrecord "$state" launch.origin)" = cycle ] || fail "a plain cycle records origin cycle"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] || fail "the singleton lock must name the same watcher"
  kill -TERM "$pid" 2>/dev/null || fail "could not stop the watcher"
  wait_pid_gone "$ARM_PID" || fail "the arm did not finish after its watcher stopped"
  wait "$ARM_PID" 2>/dev/null || true
  [ "$(wrecord "$state" launch.phase)" = exited ] || fail "a finished cycle must read exited, got '$(wrecord "$state" launch.phase)': $(wshow "$state")"
  [ -n "$(wrecord "$state" launch.outcome.code)" ] || fail "the cycle's exit code must be retained"
  grep -q '+launch-unrecorded' "$state/.watch-cycle-exits.log" 2>/dev/null && fail "a recorded cycle must not be marked unrecorded in the ledger"
  pass "watcher: the arm records intent before the fork, the child's pid and identity, beacon readiness, and the cycle's exit"
}

test_watcher_interrupted_attempt_and_successor_chain_are_settled_by_the_next_arm() {
  local dir state fakebin out pid old sleeper digest
  dir=$(make_case watcher-settle)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/arm.out"
  WRAPPER=$(make_record_wrapper "$dir"); WRAP_LOG="$dir/wrap.log"; : > "$WRAP_LOG"
  # An arm interrupted between its intent and its fork leaves an intended
  # record with a gone launcher and no child: the next arm settles it as
  # launcher-gone before recording its own attempt.
  old=$(python3 "$OWNER" --state "$state" intend --helper watcher --owner fm-watch-arm.sh --origin cycle --launcher-pid 1 --launcher-identity stale-identity | sed 's/^launch=//')
  run_arm "$state" "$fakebin" "$out"
  pid=$(wait_started "$out") || fail "the arm did not start a watcher after an interrupted attempt: $(cat "$out")"
  wshow "$state" | grep -q "previous launch=$old phase=reconciled" || fail "the interrupted attempt must be retained as reconciled: $(wshow "$state")"
  python3 "$OWNER" --state "$state" show --helper watcher --json | grep -q '"verdict": "launcher-gone"' || fail "the interrupted attempt must reconcile as launcher-gone"
  kill -TERM "$pid" 2>/dev/null || true
  wait_pid_gone "$ARM_PID" || fail "the arm did not finish"
  wait "$ARM_PID" 2>/dev/null || true
  # The successor chain: a launch whose watcher (modelled by a live sleeper
  # with its recorded start identity) still runs is superseded, never refused,
  # and its later exit is still annotated on the superseded launch. A fresh
  # state keeps the previous cycle's downtime recovery out of this case.
  dir=$(make_case watcher-successor)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/arm.out"
  WRAPPER=$(make_record_wrapper "$dir"); WRAP_LOG="$dir/wrap.log"; : > "$WRAP_LOG"
  sleep 300 &
  sleeper=$!
  LOOP_PIDS+=("$sleeper")
  digest=$(sha_of "$(python3 "$OWNER" pid-identity "$sleeper")")
  [ -n "$digest" ] || fail "the sleeper's identity digest could not be computed"
  old=$(python3 "$OWNER" --state "$state" intend --helper watcher --owner fm-watch-arm.sh --origin cycle | sed 's/^launch=//')
  python3 "$OWNER" --state "$state" created --helper watcher --launch "$old" --identity-source process --identity "pid=$sleeper" --identity "pid_identity_sha256=$digest" >/dev/null || fail "predecessor record could not be written"
  python3 "$OWNER" --state "$state" ready --helper watcher --launch "$old" --source watcher-beacon >/dev/null || fail "predecessor readiness could not be written"
  : > "$out"
  run_arm "$state" "$fakebin" "$out"
  pid=$(wait_started "$out") || fail "the successor arm did not start a watcher: $(cat "$out")"
  wshow "$state" | grep -q "previous launch=$old phase=superseded" || fail "the running predecessor must read superseded, not refused: $(wshow "$state")"
  [ "$(wrecord "$state" launch.identity.pid)" = "$pid" ] || fail "the successor's own launch must be current"
  kill -TERM "$sleeper" 2>/dev/null || true
  python3 "$OWNER" --state "$state" exit --helper watcher --launch "$old" --reason "predecessor exited after handoff" --code 0 | grep -q 'phase=superseded exit=recorded' || fail "the predecessor's later exit must be annotated on its superseded launch"
  python3 "$OWNER" --state "$state" show --helper watcher --json | grep -q '"event": "exited-after-supersede"' || fail "the annotation must be in the predecessor's history"
  kill -TERM "$pid" 2>/dev/null || true
  wait_pid_gone "$ARM_PID" || fail "the successor arm did not finish"
  wait "$ARM_PID" 2>/dev/null || true
  pass "watcher: an interrupted attempt is settled launcher-gone and a running predecessor is superseded, never refused"
}

# --- process-event runner world ------------------------------------------------------
new_procevent_home() {  # <name> -> echoes home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/claims"
  cat > "$home/blocker.sh" <<'SH'
#!/usr/bin/env bash
trigger=$1; shift
while [ ! -e "$trigger" ]; do sleep 0.05; done
printf '%s\n' "$@"
SH
  chmod +x "$home/blocker.sh"
  printf '%s\n' "$home"
}
pe() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    FM_TEST_REAL_PYTHON="$(command -v python3)" FM_LAUNCH_RECORD_PYTHON="$WRAPPER" \
    FM_TEST_WRAP_LOG="$WRAP_LOG" FM_TEST_LOCK_PATH="$home/claims/${PE_ID:?}.claim" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}
pe_subject() {  # <source-id>
  printf 'procevent-%s-%s\n' "$1" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}
precord() {  # <home> <source-id> <field>
  record "$1/state" "$(pe_subject "$2")" "$3"
}

test_procevent_runner_records_intent_before_fork_claim_identity_start_and_exit() {
  local home trig out runner claim_pid i subject
  home=$(new_procevent_home procevent-run)
  WRAPPER=$(make_record_wrapper "$home"); WRAP_LOG="$home/wrap.log"; : > "$WRAP_LOG"
  PE_ID='src-a'
  trig="$home/trigger"
  pe "$home" register lavish src-a -- "$home/blocker.sh" "$trig" "payload a" > "$home/register.out" 2>&1 || fail "register failed: $(cat "$home/register.out")"
  pe "$home" start src-a > "$home/start.out" 2>&1 &
  runner=$!
  LOOP_PIDS+=("$runner")
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$home/claims/src-a.claim" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$home/claims/src-a.claim" ] || fail "the runner never claimed its source"
  sleep 0.5
  head -n 1 "$WRAP_LOG" | grep -q '^intend lock=absent$' || fail "intent must be recorded before the claim exists, got: $(cat "$WRAP_LOG")"
  subject=$(pe_subject src-a)
  [ "$(precord "$home" src-a launch.phase)" = ready ] || fail "a claimed runner whose wait began must read ready, got '$(precord "$home" src-a launch.phase)'"
  [ "$(precord "$home" src-a launch.readiness.source)" = runner-claimed ] || fail "readiness must be the claimed start, not a result"
  claim_pid=$(sed -n '2p' "$home/claims/src-a.claim")
  [ "$(precord "$home" src-a launch.identity.pid)" = "$claim_pid" ] || fail "the record must bind the claiming runner's pid ($claim_pid), got '$(precord "$home" src-a launch.identity.pid)'"
  [ -n "$(precord "$home" src-a launch.identity.pid_identity_sha256)" ] || fail "the runner's start identity digest must be recorded"
  # A second start while the runner blocks is refused by the claim and records
  # no new launch.
  pe "$home" start src-a > "$home/second.out" 2>&1 || true
  grep -q 'already owned' "$home/second.out" || fail "a second runner must be refused by the claim: $(cat "$home/second.out")"
  [ "$(precord "$home" src-a launch.identity.pid)" = "$claim_pid" ] || fail "the refused second start must not replace the running launch"
  : > "$trig"
  wait "$runner" 2>/dev/null || true
  [ "$(precord "$home" src-a launch.phase)" = exited ] || fail "a finished runner must read exited, got '$(precord "$home" src-a launch.phase)'"
  [ "$(precord "$home" src-a launch.outcome.code)" = 0 ] || fail "the runner's exit code must be retained"
  [ -f "$home/state/.launch-$subject" ] || fail "the record must live under the helper name"
  pe "$home" retire src-a >/dev/null 2>&1 || true
  [ ! -e "$home/state/.launch-$subject" ] || fail "retiring the source must remove its record"
  pass "procevent: intent precedes the fork, the claimed runner is the identity, the started wait is readiness, and the exit and retirement are recorded"
}

test_procevent_fork_that_cannot_claim_leaves_the_attempt_accounted() {
  local home trig old
  home=$(new_procevent_home procevent-noclaim)
  WRAPPER=$(make_record_wrapper "$home"); WRAP_LOG="$home/wrap.log"; : > "$WRAP_LOG"
  PE_ID='src-b'
  trig="$home/trigger"
  pe "$home" register lavish src-b -- "$home/blocker.sh" "$trig" "payload b" > "$home/register.out" 2>&1 || fail "register failed: $(cat "$home/register.out")"
  # The child cannot claim (its claim path is occupied): the pre-fork intent
  # and the refused claim are both on record, and nothing ran.
  mkdir -p "$home/claims/src-b.claim"
  pe "$home" start src-b > "$home/start.out" 2>&1 || true
  rmdir "$home/claims/src-b.claim"
  grep -q '^intend ' "$WRAP_LOG" || fail "the attempt must be recorded before the child runs: $(cat "$WRAP_LOG")"
  [ "$(precord "$home" src-b launch.phase)" = failed ] || fail "a child whose claim was refused must read failed, got '$(precord "$home" src-b launch.phase)': $(cat "$home/start.out")"
  [ "$(precord "$home" src-b launch.outcome.effect)" = none ] || fail "a refused claim ran nothing"
  # The claim owner reports an occupied claim path as "already owned" (claim
  # state 2) and an unwritable one as "could not be claimed"; both are the
  # accepted refusal: the launch is closed failed/none and nothing ran.
  assert_contains "$(precord "$home" src-b launch.outcome.reason)" "this runner ran nothing" "the reason must record that the refused runner ran nothing"
  # A child that died before claiming (an intent with a gone launcher and no
  # identity) is listed for reconciliation and settled by the next start.
  old=$(python3 "$OWNER" --state "$home/state" intend --helper "$(pe_subject src-b)" --owner fm-procevent.sh --origin wait --launcher-pid 1 --launcher-identity stale-identity | sed 's/^launch=//')
  python3 "$OWNER" --state "$home/state" list --reconcile | grep -q "$(pe_subject src-b)" || fail "the unsettled attempt must be listed for reconciliation"
  : > "$trig"
  pe "$home" start src-b > "$home/second.out" 2>&1 || fail "the next start must succeed: $(cat "$home/second.out")"
  python3 "$OWNER" --state "$home/state" show --helper "$(pe_subject src-b)" | grep -q "previous launch=$old phase=reconciled" || fail "the interrupted attempt must be retained as reconciled: $(python3 "$OWNER" --state "$home/state" show --helper "$(pe_subject src-b)")"
  [ "$(precord "$home" src-b launch.phase)" = exited ] || fail "the completed runner must read exited, got '$(precord "$home" src-b launch.phase)'"
  pe "$home" retire src-b >/dev/null 2>&1 || true
  pass "procevent: a refused claim and a fork that died before claiming both leave an accounted attempt the next start settles"
}

test_supervisor_establish_records_intent_identity_readiness_and_stop
test_supervisor_create_refusal_records_the_owner_uncertainty
test_afk_launcher_records_intent_identity_readiness_and_stop
test_afk_launcher_create_refusal_is_uncertain_with_no_terminal_record
test_watcher_cycle_records_intent_before_fork_identity_readiness_and_exit
test_watcher_interrupted_attempt_and_successor_chain_are_settled_by_the_next_arm
test_procevent_runner_records_intent_before_fork_claim_identity_start_and_exit
test_procevent_fork_that_cannot_claim_leaves_the_attempt_accounted
