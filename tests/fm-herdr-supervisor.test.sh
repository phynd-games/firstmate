#!/usr/bin/env bash
# tests/fm-herdr-supervisor.test.sh - behavior tests for bin/fm-herdr-supervisor.sh,
# the Herdr-hosted watcher continuity owner.
#
# These drive the REAL script against a stateful fake `herdr` CLI plus a real
# (scripted) arm stub, so the continuity claim is proved by counting actual arm
# invocations rather than by reading the code. The incident this fixes had
# exactly one arm invocation per hand-start and successor=none; the central case
# below asserts many invocations from a single establish.
#
# jq is a real required tool for the herdr adapter and is never faked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# A Herdr pane identity leaked in from the developer's own terminal would make
# the adapter resolve a launcher this fake never models.
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-herdr-supervisor-tests)

SUPERVISOR="$ROOT/bin/fm-herdr-supervisor.sh"

# --- fake herdr ---------------------------------------------------------------
#
# Stateful, file-backed, and deliberately small: it models only what the
# supervisor actually asks of Herdr - client protocol, server running, session
# socket, workspace create, pane get, pane process-info, pane run, workspace
# close - and records every call so a test can assert what was and was not done.
#
# `pane run` genuinely executes the command in the background, so the supervisor
# loop under test is a real process with a real pid and a real identity. That is
# what makes the recycled-pid and duplicate-arm assertions meaningful.
make_fake_herdr() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_HERDR_STATE:?}"
mkdir -p "$S"
{
  for a in "$@"; do printf '%s\x1f' "$a"; done
  printf '\n'
} >> "$S/calls.log"

# Strip the trailing `--session <name>` the adapter always appends.
args=()
for a in "$@"; do args+=("$a"); done
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  unset 'args[n-1]'
  unset 'args[n-2]'
fi
set -- "${args[@]:-}"

sock=$(cat "$S/socket" 2>/dev/null || echo "$S/herdr.sock")

case "${1:-}" in
  status)
    if [ -f "$S/hang" ]; then sleep 300; exit 0; fi
    running=true
    [ ! -f "$S/server-stopped" ] || running=false
    printf '{"client":{"version":"0.8.2","protocol":16},"server":{"running":%s}}\n' "$running"
    exit 0
    ;;
  session)
    if [ "${2:-}" = list ]; then
      printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"}]}\n' \
        "${HERDR_SESSION:-default}" "$sock"
      exit 0
    fi
    exit 1
    ;;
  workspace)
    case "${2:-}" in
      create)
        if [ -f "$S/create-incomplete" ]; then
          printf '{"result":{"workspace":{}}}\n'
          exit 0
        fi
        if [ -f "$S/create-partial" ]; then
          # A workspace id came back but the pane did not: the response names
          # something real yet cannot prove which pane is ours.
          printf '{"result":{"workspace":{"workspace_id":"wPART"},"tab":{"tab_id":"wPART:t1"}}}\n'
          exit 0
        fi
        if [ -f "$S/create-fails" ]; then exit 1; fi
        printf 'wZ\n' > "$S/workspace"
        printf '{"result":{"workspace":{"workspace_id":"wZ"},"tab":{"tab_id":"wZ:t1"},"root_pane":{"pane_id":"wZ:p1"}}}\n'
        exit 0
        ;;
      close)
        printf '%s\n' "${3:-}" >> "$S/closed-workspaces"
        exit 0
        ;;
    esac
    exit 1
    ;;
  pane)
    case "${2:-}" in
      get)
        pane=${3:-}
        [ "$pane" = "$(cat "$S/pane" 2>/dev/null || echo wZ:p1)" ] || exit 1
        printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' \
          "$pane" \
          "$(cat "$S/pane-tab" 2>/dev/null || echo wZ:t1)" \
          "$(cat "$S/pane-workspace" 2>/dev/null || echo wZ)"
        exit 0
        ;;
      process-info)
        pane=""
        for i in $(seq 1 $#); do
          if [ "${!i}" = --pane ]; then j=$((i+1)); pane=${!j}; fi
        done
        pid=$(cat "$S/loop-pid" 2>/dev/null || echo 0)
        [ ! -s "$S/process-pid-override" ] || pid=$(cat "$S/process-pid-override")
        printf '{"result":{"process_info":{"pane_id":"%s","shell_pid":%s}}}\n' "$pane" "$pid"
        exit 0
        ;;
      run)
        if [ -f "$S/run-fails" ]; then exit 1; fi
        cmd=${4:-}
        # Run it for real, detached from this CLI call, and record the pid the
        # pane would track. `exec` in the command keeps that pid stable.
        bash -c "$cmd" >>"$S/loop.out" 2>&1 &
        printf '%s\n' "$!" > "$S/loop-pid"
        exit 0
        ;;
    esac
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_arm_stub: a scripted stand-in for bin/fm-watch-arm.sh. It counts its own
# invocations so continuity is asserted by invocation count, and it can be told
# to succeed with an actionable reason or to fail.
make_arm_stub() {  # <path> <mode:ok|fail>
  local path=$1 mode=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
set -u
C="\${FM_TEST_ARM_COUNT:?}"
n=\$(( \$(cat "\$C" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$C"
if [ "$mode" = fail ]; then
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
fi
echo "signal: /fake/state/task.status"
exit 0
SH
  chmod +x "$path"
}

# new_home: a fresh, fully isolated firstmate home wired to the fake herdr.
new_home() {  # <name> -> echoes home dir
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/fakestate"
  printf 'herdr\n' > "$home/config/backend"
  printf '%s\n' "$home"
}

# run_supervisor: invoke the real script with one home's environment.
run_supervisor() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" \
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_FAKE_HERDR_STATE="$home/fakestate" \
  FM_TEST_ARM_COUNT="$home/arm.count" \
  FM_WATCH_ARM_SCRIPT="$home/arm.sh" \
  FM_SUPERVISION_MODEL="${FM_TEST_SUPERVISION_MODEL:-extension}" \
  FM_HERDR_SUPERVISOR_READY_TIMEOUT="${FM_TEST_READY_TIMEOUT:-15}" \
  FM_HERDR_SUPERVISOR_RETRY_BASE=0 \
  FM_HERDR_SUPERVISOR_RETRY_MAX=0 \
  FM_HERDR_SUPERVISOR_IDLE_INTERVAL=1 \
  HERDR_SESSION=default \
  "$SUPERVISOR" "$@"
}

# stop_loop: end a home's supervisor loop so a test never leaks a process.
stop_loop() {  # <home>
  local home=$1 pid
  pid=$(cat "$home/fakestate/loop-pid" 2>/dev/null || true)
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  pkill -P "$pid" 2>/dev/null || true
}

record_field() {  # <home> <key>
  grep -m1 "^$2=" "$1/state/.herdr-supervisor" 2>/dev/null | sed "s/^$2=//"
}

wait_for() {  # <seconds> <predicate...>
  local budget=$1
  shift
  local i=0
  while [ "$i" -lt $((budget * 10)) ]; do
    if "$@"; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

arm_count_at_least() {  # <home> <n>
  local c
  c=$(cat "$1/arm.count" 2>/dev/null || echo 0)
  [ "$c" -ge "$2" ]
}

FAKEBIN=$(make_fake_herdr "$TMP_ROOT")

# =============================================================================
# 1. A non-herdr home is never eligible and nothing is created.
# =============================================================================
HOME1=$(new_home not-herdr)
printf 'tmux\n' > "$HOME1/config/backend"
make_arm_stub "$HOME1/arm.sh" ok
out=$(run_supervisor "$HOME1" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "not eligible" "non-herdr home refuses to host a supervisor"
assert_contains "$out" "not herdr" "non-herdr home names the backend as the reason"
assert_absent "$HOME1/state/.herdr-supervisor" "non-herdr home writes no supervisor record"
pass "a non-herdr home is not eligible and creates nothing"

# =============================================================================
# 2. Away mode owns supervision; the supervisor stands down.
# =============================================================================
HOME2=$(new_home afk)
make_arm_stub "$HOME2/arm.sh" ok
fm_write_meta "$HOME2/state/afk-task.meta" "window=firstmate:fm-afk-task"
: > "$HOME2/state/.afk"
out=$(run_supervisor "$HOME2" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "deferred" "away mode defers the supervisor"
assert_contains "$out" "away mode" "the deferral names away mode"
assert_absent "$HOME2/state/.herdr-supervisor" "an away-mode home hosts no supervisor"
pass "away mode is a provable owner and the supervisor stands down"

# =============================================================================
# 3. A loaded Pi primary extension owns continuity; the supervisor stands down.
#    This is the negative control for the incident: when the extension IS
#    loaded, this new machinery must stay entirely out of the way.
# =============================================================================
HOME3=$(new_home pi-extension-loaded)
make_arm_stub "$HOME3/arm.sh" ok
fm_write_meta "$HOME3/state/ext-task.meta" "window=firstmate:fm-ext-task"
printf '%s\n' "$$" > "$HOME3/state/.lock"
for pair in "fm-primary-pi-watch.ts:.pi-watch-extension-loaded" \
            "fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded"; do
  src=${pair%%:*}
  marker=${pair#*:}
  version=$(shasum -a 256 "$ROOT/.pi/extensions/$src" | awk '{print "sha256:" $1}')
  printf '%s\n%s\n' "$version" "$$" > "$HOME3/state/$marker"
done
out=$(run_supervisor "$HOME3" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "deferred" "a loaded Pi extension defers the supervisor"
assert_contains "$out" "Pi primary extension" "the deferral names the Pi extension owner"
assert_absent "$HOME3/state/.herdr-supervisor" "an extension-owned home hosts no supervisor"
pass "a loaded Pi extension is a provable owner and the supervisor stands down"

# =============================================================================
# 4. No supervision need means nothing is established.
# =============================================================================
HOME4=$(new_home idle)
make_arm_stub "$HOME4/arm.sh" ok
out=$(run_supervisor "$HOME4" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "not needed" "an idle home establishes nothing"
assert_absent "$HOME4/state/.herdr-supervisor" "an idle home writes no supervisor record"
pass "a home with nothing in flight establishes no supervisor"

# =============================================================================
# 5. THE CENTRAL CASE. One establish must yield MANY arm cycles.
#    The incident's signature was one cycle per hand-start with successor=none.
# =============================================================================
HOME5=$(new_home continuity)
make_arm_stub "$HOME5/arm.sh" ok
fm_write_meta "$HOME5/state/live-task.meta" "window=firstmate:fm-live-task"
out=$(run_supervisor "$HOME5" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "establish reports a started supervisor"
GEN5=$(record_field "$HOME5" generation)
[ -n "$GEN5" ] || fail "establish recorded no generation"
[ -f "$HOME5/state/.herdr-supervisor-live" ] || fail "established supervisor published no live record"
wait_for 20 arm_count_at_least "$HOME5" 3 \
  || fail "one establish produced only $(cat "$HOME5/arm.count" 2>/dev/null || echo 0) arm cycles; continuity is not restored"
pass "one establish keeps re-arming the watcher across many actionable closes"

# =============================================================================
# 6. ensure is idempotent: a second call attaches to the same generation and
#    starts no second owner.
# =============================================================================
out=$(run_supervisor "$HOME5" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "unchanged" "a repeat ensure is a no-op"
[ "$(record_field "$HOME5" generation)" = "$GEN5" ] || fail "a repeat ensure minted a new generation"
created=$(grep -c 'workspace.create' "$HOME5/fakestate/calls.log" 2>/dev/null || echo 0)
[ "$created" -le 1 ] || fail "a repeat ensure created $created workspaces; exactly one owner is allowed"
pass "a repeated ensure is idempotent and creates no second supervisor"

# =============================================================================
# 7. A recycled pid never reads as healthy.
# =============================================================================
sed 's/^loop_identity=.*/loop_identity=not-the-real-identity/' \
  "$HOME5/state/.herdr-supervisor-live" > "$HOME5/state/.herdr-supervisor-live.new"
mv "$HOME5/state/.herdr-supervisor-live.new" "$HOME5/state/.herdr-supervisor-live"
out=$(run_supervisor "$HOME5" "$FAKEBIN" status 2>&1)
assert_contains "$out" "supervisor: unhealthy" "a mismatched process identity is unhealthy"
assert_contains "$out" "recycled" "the unhealthy reason names pid recycling"
pass "a recycled pid is never reported healthy"
stop_loop "$HOME5"

# =============================================================================
# 8. A stale supervisor heartbeat is unhealthy, and ensure re-establishes with
#    a NEW generation rather than trusting the old record.
# =============================================================================
HOME8=$(new_home stale-heartbeat)
make_arm_stub "$HOME8/arm.sh" ok
fm_write_meta "$HOME8/state/beat-task.meta" "window=firstmate:fm-beat-task"
run_supervisor "$HOME8" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the heartbeat case"
GEN8=$(record_field "$HOME8" generation)
stop_loop "$HOME8"
touch -t 200001010000 "$HOME8/state/.herdr-supervisor-heartbeat"
out=$(run_supervisor "$HOME8" "$FAKEBIN" status 2>&1)
assert_contains "$out" "supervisor: unhealthy" "a stale supervisor heartbeat is unhealthy"
assert_contains "$out" "heartbeat" "the unhealthy reason names the heartbeat"
out=$(run_supervisor "$HOME8" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a stale heartbeat is repaired by re-establishing"
[ "$(record_field "$HOME8" generation)" != "$GEN8" ] || fail "re-establish reused the stale generation"
pass "a stale supervisor heartbeat is unhealthy and re-establishes a new generation"
stop_loop "$HOME8"

# =============================================================================
# 9. An unknown or contradictory Herdr pane is never healthy.
# =============================================================================
HOME9=$(new_home unknown-pane)
make_arm_stub "$HOME9/arm.sh" ok
fm_write_meta "$HOME9/state/pane-task.meta" "window=firstmate:fm-pane-task"
run_supervisor "$HOME9" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the pane case"
printf 'wOTHER\n' > "$HOME9/fakestate/pane-workspace"
out=$(run_supervisor "$HOME9" "$FAKEBIN" status 2>&1)
assert_contains "$out" "supervisor: unhealthy" "a pane that moved workspace is unhealthy"
assert_contains "$out" "no longer matches" "the unhealthy reason names the broken pane binding"
pass "an unknown or contradictory Herdr pane is never healthy"
stop_loop "$HOME9"

# =============================================================================
# 10. A Herdr server restart changes the session socket, and that is unhealthy.
#     This is the boundary the docs promise no recovery across - it must be
#     detected and reported, never silently treated as fine.
# =============================================================================
HOME10=$(new_home server-restart)
make_arm_stub "$HOME10/arm.sh" ok
fm_write_meta "$HOME10/state/socket-task.meta" "window=firstmate:fm-socket-task"
run_supervisor "$HOME10" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the socket case"
# The loop stays alive on purpose: this must prove the SERVER identity check
# fails on its own, not that a dead process was noticed first.
printf '%s\n' "$HOME10/fakestate/restarted.sock" > "$HOME10/fakestate/socket"
out=$(run_supervisor "$HOME10" "$FAKEBIN" status 2>&1)
assert_contains "$out" "supervisor: unhealthy" "a replaced Herdr server is unhealthy"
assert_contains "$out" "socket changed" "the unhealthy reason names the lost server"
pass "a Herdr server restart is detected as a lost supervisor, not as healthy"
stop_loop "$HOME10"

# =============================================================================
# 10b. A live record left behind by a superseded generation is never healthy.
#      Everything else about it still checks out - live process, matching
#      identity, fresh heartbeat, intact pane - so only the generation pairing
#      can reject it.
# =============================================================================
HOME10B=$(new_home superseded-live)
make_arm_stub "$HOME10B/arm.sh" ok
fm_write_meta "$HOME10B/state/gen-task.meta" "window=firstmate:fm-gen-task"
run_supervisor "$HOME10B" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the generation case"
sed 's/^generation=.*/generation=a-superseded-generation/' \
  "$HOME10B/state/.herdr-supervisor-live" > "$HOME10B/state/.herdr-supervisor-live.new"
mv "$HOME10B/state/.herdr-supervisor-live.new" "$HOME10B/state/.herdr-supervisor-live"
out=$(run_supervisor "$HOME10B" "$FAKEBIN" status 2>&1)
assert_contains "$out" "supervisor: unhealthy" "a superseded live record is unhealthy"
assert_contains "$out" "superseded generation" "the unhealthy reason names the superseded generation"
pass "a live record from a superseded generation is never read as healthy"
stop_loop "$HOME10B"

# =============================================================================
# 10c. A STOPPED supervisor is alive, identity-matched, and still tracked by its
#      pane - only its heartbeat goes stale. That isolates the heartbeat gate
#      from every process check, the same counterfactual the watcher-lock suite
#      uses to separate a live pid from a stale beacon.
# =============================================================================
HOME10C=$(new_home stopped-supervisor)
make_arm_stub "$HOME10C/arm.sh" ok
fm_write_meta "$HOME10C/state/stopped-task.meta" "window=firstmate:fm-stopped-task"
run_supervisor "$HOME10C" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the stopped case"
STOPPED_PID=$(cat "$HOME10C/fakestate/loop-pid")
kill -STOP "$STOPPED_PID" 2>/dev/null || fail "could not stop the supervisor for the heartbeat case"
touch -t 200001010000 "$HOME10C/state/.herdr-supervisor-heartbeat"
out=$(run_supervisor "$HOME10C" "$FAKEBIN" status 2>&1)
kill -CONT "$STOPPED_PID" 2>/dev/null || true
fm_pid_alive_check() { kill -0 "$1" 2>/dev/null; }
fm_pid_alive_check "$STOPPED_PID" || fail "the stopped supervisor died; the counterfactual proves nothing"
assert_contains "$out" "supervisor: unhealthy" "a wedged supervisor with a stale heartbeat is unhealthy"
assert_contains "$out" "heartbeat" "the unhealthy reason names the stale heartbeat, not a dead process"
pass "a live but wedged supervisor is unhealthy on its heartbeat alone"
stop_loop "$HOME10C"

# =============================================================================
# 10d. A pane that tracks some other process is never healthy, even while the
#      recorded supervisor process is alive and identity-matched.
# =============================================================================
HOME10D=$(new_home foreign-pane-process)
make_arm_stub "$HOME10D/arm.sh" ok
fm_write_meta "$HOME10D/state/foreign-task.meta" "window=firstmate:fm-foreign-task"
run_supervisor "$HOME10D" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the pane-process case"
printf '%s\n' "$$" > "$HOME10D/fakestate/process-pid-override"
out=$(run_supervisor "$HOME10D" "$FAKEBIN" status 2>&1)
assert_contains "$out" "supervisor: unhealthy" "a pane tracking another process is unhealthy"
assert_contains "$out" "tracks pid" "the unhealthy reason names the foreign tracked process"
pass "a Herdr pane tracking a different process is never read as healthy"
stop_loop "$HOME10D"

# =============================================================================
# 11. A repeatedly failing arm is bounded, alarms durably, and escalates through
#     the existing wake queue.
# =============================================================================
HOME11=$(new_home failing-arm)
make_arm_stub "$HOME11/arm.sh" fail
fm_write_meta "$HOME11/state/failing-task.meta" "window=firstmate:fm-failing-task"
out=$(FM_TEST_READY_TIMEOUT=15 run_supervisor "$HOME11" "$FAKEBIN" ensure 2>&1) || true
wait_for 25 test -f "$HOME11/state/.herdr-supervisor-alarm" \
  || fail "a repeatedly failing arm left no durable alarm"
assert_grep "supervision is DOWN" "$HOME11/state/.herdr-supervisor-alarm" \
  "the alarm states supervision is down"
queue_has_escalation() { grep -q 'herdr-supervisor' "$1/state/.wake-queue" 2>/dev/null; }
wait_for 10 queue_has_escalation "$HOME11" \
  || fail "the failure was not escalated onto the durable wake queue"
assert_grep 'check' "$HOME11/state/.wake-queue" "the escalation is a check-kind wake"
count=$(cat "$HOME11/arm.count" 2>/dev/null || echo 0)
[ "$count" -le 8 ] || fail "the failing arm retried $count times; the retry bound did not hold"
pass "a repeatedly failing arm is bounded, alarms durably, and escalates"
stop_loop "$HOME11"

# =============================================================================
# 12. A superseded generation never arms. This is the duplicate-arm guard.
# =============================================================================
HOME12=$(new_home superseded)
make_arm_stub "$HOME12/arm.sh" ok
fm_write_meta "$HOME12/state/dup-task.meta" "window=firstmate:fm-dup-task"
out=$(run_supervisor "$HOME12" "$FAKEBIN" run --generation not-the-current-one 2>&1) || true
assert_contains "$out" "standing down" "a stale generation stands down instead of arming"
[ "$(cat "$HOME12/arm.count" 2>/dev/null || echo 0)" = 0 ] \
  || fail "a superseded generation armed the watcher"
pass "a superseded generation refuses to arm, so a duplicate arm cannot start"

# =============================================================================
# 13. An incomplete Herdr create response grants no cleanup authority.
# =============================================================================
HOME13=$(new_home incomplete-create)
make_arm_stub "$HOME13/arm.sh" ok
fm_write_meta "$HOME13/state/incomplete-task.meta" "window=firstmate:fm-incomplete-task"
: > "$HOME13/fakestate/create-incomplete"
out=$(run_supervisor "$HOME13" "$FAKEBIN" ensure 2>&1) && fail "an incomplete create response reported success"
assert_contains "$out" "incomplete workspace-create response" "the failure names the incomplete response"
assert_absent "$HOME13/fakestate/closed-workspaces" \
  "an incomplete response must not guess at a workspace to close"
assert_absent "$HOME13/state/.herdr-supervisor" "a failed establish leaves no live record"
assert_present "$HOME13/state/.herdr-supervisor-alarm" "a failed establish leaves a durable alarm"
pass "an incomplete Herdr response fails loudly and closes nothing it cannot identify"

# =============================================================================
# 13b. A PARTIAL Herdr create response is refused, closes nothing, and names the
#      workspace that may have been orphaned. Distinct from the fully empty
#      response above: here an id really did come back, and the guard must still
#      refuse rather than act on a half-identified binding.
# =============================================================================
HOME13B=$(new_home partial-create)
make_arm_stub "$HOME13B/arm.sh" ok
fm_write_meta "$HOME13B/state/partial-task.meta" "window=firstmate:fm-partial-task"
: > "$HOME13B/fakestate/create-partial"
out=$(run_supervisor "$HOME13B" "$FAKEBIN" ensure 2>&1) && fail "a partial create response reported success"
assert_contains "$out" "incomplete workspace-create response" "the partial response is refused"
assert_absent "$HOME13B/fakestate/closed-workspaces" \
  "a partial response must not close a workspace it cannot prove is ours"
assert_absent "$HOME13B/state/.herdr-supervisor" "a partial establish leaves no live record"
assert_grep "wPART" "$HOME13B/state/.herdr-supervisor-alarm" \
  "the alarm names the workspace that may have been orphaned"
[ "$(cat "$HOME13B/arm.count" 2>/dev/null || echo 0)" = 0 ] \
  || fail "a partial establish armed the watcher anyway"
pass "a partial Herdr create response is refused and names its possible orphan"

# =============================================================================
# 13c. A Herdr session with no running server is refused loudly. The supervisor
#      must never try to START one: `ensure` runs inside a command substitution
#      on the session-start path, and backgrounding a long-lived server from
#      there is what wedged the first live smoke. A dead server is also the one
#      boundary this design says it cannot recover across, so it belongs in the
#      alarm, not in a retry.
# =============================================================================
HOME13C=$(new_home no-server)
make_arm_stub "$HOME13C/arm.sh" ok
fm_write_meta "$HOME13C/state/noserver-task.meta" "window=firstmate:fm-noserver-task"
: > "$HOME13C/fakestate/server-stopped"
out=$(run_supervisor "$HOME13C" "$FAKEBIN" ensure 2>&1) && fail "a stopped Herdr server reported success"
assert_contains "$out" "no running server" "the refusal names the missing Herdr server"
assert_absent "$HOME13C/state/.herdr-supervisor" "a stopped server leaves no supervisor record"
assert_present "$HOME13C/state/.herdr-supervisor-alarm" "a stopped server leaves a durable alarm"
assert_no_grep "server" "$HOME13C/fakestate/calls.log" "the supervisor must never invoke a Herdr server command"
pass "a Herdr session with no running server is refused loudly and starts no server"

# =============================================================================
# 13d. A Herdr CLI that never returns cannot wedge the caller. `ensure` is
#      invoked inside a command substitution by bootstrap, so an unbounded
#      adapter call would hang session start itself - strictly worse than the
#      supervision lapse this exists to fix.
# =============================================================================
HOME13D=$(new_home hanging-cli)
make_arm_stub "$HOME13D/arm.sh" ok
fm_write_meta "$HOME13D/state/hang-task.meta" "window=firstmate:fm-hang-task"
: > "$HOME13D/fakestate/hang"
HANG_START=$(date +%s)
out=$(FM_HERDR_SUPERVISOR_HERDR_TIMEOUT=3 run_supervisor "$HOME13D" "$FAKEBIN" ensure 2>&1) \
  && fail "a hanging Herdr CLI reported success"
HANG_ELAPSED=$(( $(date +%s) - HANG_START ))
[ "$HANG_ELAPSED" -lt 30 ] \
  || fail "a hanging Herdr CLI blocked ensure for ${HANG_ELAPSED}s; the bound did not hold"
assert_contains "$out" "could not read herdr status" "the bound is reported as a status read failure"
assert_present "$HOME13D/state/.herdr-supervisor-alarm" "a hanging Herdr CLI leaves a durable alarm"
pass "a hanging Herdr CLI is bounded and can never wedge the caller"

# =============================================================================
# 13e. The pane command must stay SHORT and constant, with everything the loop
#      needs in a launcher script.
#
#      `herdr pane run` types its command into the pane's shell, so it is bound
#      by that terminal's line-length limit. A long FM_HOME pushed the inlined
#      form past it: Herdr reported success, the pane silently ran a command
#      truncated mid-argument, and the only symptom was a loop that never
#      confirmed. Caught on the real-Herdr smoke, pinned here.
# =============================================================================
HOME13E=$(new_home "launcher-$(printf 'x%.0s' $(seq 1 60))")
make_arm_stub "$HOME13E/arm.sh" ok
fm_write_meta "$HOME13E/state/launch-task.meta" "window=firstmate:fm-launch-task"
out=$(run_supervisor "$HOME13E" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a long home path still establishes"
PANE_CMD=$(tr '\037' ' ' < "$HOME13E/fakestate/calls.log" | grep 'pane run' | head -1)
[ -n "$PANE_CMD" ] || fail "no pane run call was recorded"
# The invariant is that the command carries ONE path and nothing else. The
# inlined form repeated the home path four times and added every tuning value,
# which is what pushed it past the limit; this must stay flat as tuning grows.
[ "${#PANE_CMD}" -lt 400 ] \
  || fail "the pane command is ${#PANE_CMD} chars; it must stay short enough to survive a terminal line limit"
case "$PANE_CMD" in
  *FM_HERDR_SUPERVISOR_RETRY_LIMIT*|*FM_CONFIG_OVERRIDE*|*FM_WATCH_ARM_SCRIPT*)
    fail "the pane command inlines the loop environment; that is what got truncated in a real pane" ;;
  *.herdr-supervisor-launch.sh*) ;;
  *) fail "the pane command does not reference the launcher script" ;;
esac
assert_present "$HOME13E/state/.herdr-supervisor-launch.sh" "a launcher script carries the loop's environment"
assert_grep "FM_STATE_OVERRIDE" "$HOME13E/state/.herdr-supervisor-launch.sh" \
  "the launcher exports the state directory the pane shell cannot inherit"
assert_grep "FM_WATCH_ARM_SCRIPT" "$HOME13E/state/.herdr-supervisor-launch.sh" \
  "the launcher exports the arm script the pane shell cannot inherit"
[ -x "$HOME13E/state/.herdr-supervisor-launch.sh" ] || fail "the launcher script is not executable"
pass "the pane command stays short and the loop's environment travels in a launcher script"
stop_loop "$HOME13E"

# =============================================================================
# 14. retire clears the record and closes exactly the workspace it created.
# =============================================================================
HOME14=$(new_home retire)
make_arm_stub "$HOME14/arm.sh" ok
fm_write_meta "$HOME14/state/retire-task.meta" "window=firstmate:fm-retire-task"
run_supervisor "$HOME14" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the retire case"
out=$(run_supervisor "$HOME14" "$FAKEBIN" retire --reason "test" 2>&1)
assert_contains "$out" "retired" "retire reports the stand-down"
assert_absent "$HOME14/state/.herdr-supervisor" "retire clears the ownership record"
assert_absent "$HOME14/state/.herdr-supervisor-live" "retire clears the live record"
assert_absent "$HOME14/state/.herdr-supervisor-launch.sh" "retire clears the launcher script"
assert_grep 'wZ' "$HOME14/fakestate/closed-workspaces" "retire closed exactly its own workspace"
[ "$(grep -c . "$HOME14/fakestate/closed-workspaces")" = 1 ] \
  || fail "retire closed more than the one workspace it owns"
pass "retire releases the record and closes exactly the workspace it owns"

# =============================================================================
# 15. The supervisor never writes to the watcher's own beacon. Only the watcher
#     may touch state/.last-watcher-beat, or a wedged watcher could look alive.
# =============================================================================
HOME15=$(new_home beacon-separation)
make_arm_stub "$HOME15/arm.sh" ok
fm_write_meta "$HOME15/state/beacon-task.meta" "window=firstmate:fm-beacon-task"
run_supervisor "$HOME15" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the beacon case"
wait_for 20 arm_count_at_least "$HOME15" 2 || fail "the beacon case never armed"
assert_absent "$HOME15/state/.last-watcher-beat" \
  "the supervisor must never write the watcher's own liveness beacon"
pass "the supervisor never touches the watcher's liveness beacon"
stop_loop "$HOME15"

# =============================================================================
# 16. A non-extension supervision model needs a deliberate opt-in, so no home
#     ever ends up with two continuity owners by default.
# =============================================================================
HOME16=$(new_home autoarm-default)
make_arm_stub "$HOME16/arm.sh" ok
fm_write_meta "$HOME16/state/autoarm-task.meta" "window=firstmate:fm-autoarm-task"
out=$(FM_TEST_SUPERVISION_MODEL=autoarm run_supervisor "$HOME16" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "not eligible" "an auto-arm home does not host a supervisor by default"
assert_contains "$out" "herdr-supervisor" "the refusal names the opt-in setting"
printf 'on\n' > "$HOME16/config/herdr-supervisor"
out=$(FM_TEST_SUPERVISION_MODEL=autoarm run_supervisor "$HOME16" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "an explicit opt-in hosts the supervisor anyway"
pass "a non-extension harness needs an explicit opt-in before Herdr hosts continuity"
stop_loop "$HOME16"

# =============================================================================
# 17. config/herdr-supervisor=off is honored absolutely.
# =============================================================================
HOME17=$(new_home opted-out)
make_arm_stub "$HOME17/arm.sh" ok
fm_write_meta "$HOME17/state/off-task.meta" "window=firstmate:fm-off-task"
printf 'off\n' > "$HOME17/config/herdr-supervisor"
out=$(run_supervisor "$HOME17" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "not eligible" "an opted-out home hosts nothing"
assert_contains "$out" "is off" "the refusal names the opt-out"
assert_absent "$HOME17/state/.herdr-supervisor" "an opted-out home writes no record"
pass "config/herdr-supervisor=off is honored"

echo "all fm-herdr-supervisor tests passed"
