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
mkdir -p "$(dirname "$sock")"
[ -e "$sock" ] || : > "$sock"

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
        for i in $(seq 1 $#); do
          if [ "${!i}" = --label ]; then j=$((i + 1)); printf '%s\n' "${!j}" > "$S/workspace-label"; fi
        done
        printf '{"result":{"workspace":{"workspace_id":"wZ"},"tab":{"tab_id":"wZ:t1"},"root_pane":{"pane_id":"wZ:p1"}}}\n'
        exit 0
        ;;
      close)
        [ ! -f "$S/close-fails" ] || exit 1
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
        race_stat=$(cat "$S/health-race-stat" 2>/dev/null || true)
        if [ -n "$race_stat" ] && [ ! -f "$S/health-raced" ]; then
          touch "$S/health-raced"
          sed 's/ [0-9][0-9]*$/ 999/' "$race_stat" > "$race_stat.new" \
            && mv "$race_stat.new" "$race_stat"
        fi
        exit 0
        ;;
      run)
        if [ -f "$S/run-fails" ]; then exit 1; fi
        cmd=${4:-}
        [ "${#cmd}" -lt 400 ] || exit 1
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
  cat > "$fb/herdr-workspace-control" <<'SH'
#!/usr/bin/env bash
set -u
operation=$3
workspace=${4:-}
S="${FM_FAKE_HERDR_STATE:?}"
case "$operation" in
  list)
    label=$(cat "$S/workspace-label" 2>/dev/null || true)
    printf '{"id":"fm-workspace-control","result":{"workspaces":[{"workspace_id":"%s","label":"%s"}]}}\n' \
      "$(cat "$S/workspace" 2>/dev/null || true)" "$label"
    ;;
  close)
    [ ! -f "$S/close-fails" ] || exit 1
    printf '%s\n' "$workspace" >> "$S/closed-workspaces"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fb/herdr-workspace-control"
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
if [ -f "\$FM_HOME/state/expected-arm-tuning" ]; then
  expected=\$(cat "\$FM_HOME/state/expected-arm-tuning")
  actual="\${FM_GUARD_GRACE:-}:\${FM_WATCHER_STALE_GRACE:-}:\${FM_ARM_CONFIRM_TIMEOUT:-}:\${FM_HERDR_SUPERVISOR_READY_TIMEOUT:-}"
  [ "\$actual" = "\$expected" ] || exit 1
  : > "\$FM_HOME/state/arm-consumer-ok"
fi
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
  local supervisor_root supervisor
  shift 2
  supervisor_root="$home/supervisor-root"
  mkdir -p "$supervisor_root/bin"
  cp "$ROOT"/bin/*.sh "$supervisor_root/bin/"
  cp -R "$ROOT/bin/backends" "$supervisor_root/bin/"
  cp "$home/arm.sh" "$supervisor_root/bin/fm-watch-arm.sh"
  chmod +x "$supervisor_root/bin"/*.sh
  supervisor="$supervisor_root/bin/fm-herdr-supervisor.sh"
  PATH="$fakebin:$PATH" \
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_FAKE_HERDR_STATE="$home/fakestate" \
  FM_PROC_ROOT_OVERRIDE="${FM_PROC_ROOT_OVERRIDE:-}" \
  FM_TEST_ARM_COUNT="$home/arm.count" \
  FM_HERDR_WORKSPACE_CONTROL_HELPER="$fakebin/herdr-workspace-control" \
  FM_SUPERVISION_MODEL="${FM_TEST_SUPERVISION_MODEL:-extension}" \
  FM_TEST_UNKNOWN_ARM="${FM_TEST_UNKNOWN_ARM:-0}" \
  FM_HERDR_SUPERVISOR_UNKNOWN_ARM_TIMEOUT="${FM_TEST_UNKNOWN_ARM_TIMEOUT:-20}" \
  FM_HERDR_SUPERVISOR_UNKNOWN_ARM_RETRY_LIMIT="${FM_TEST_UNKNOWN_ARM_RETRY_LIMIT:-3}" \
  FM_HERDR_SUPERVISOR_READY_TIMEOUT="${FM_TEST_READY_TIMEOUT:-15}" \
  FM_HERDR_SUPERVISOR_RETRY_BASE=0 \
  FM_HERDR_SUPERVISOR_RETRY_MAX="${FM_TEST_RETRY_MAX:-0}" \
  FM_HERDR_SUPERVISOR_RAPID_CYCLE_SECONDS="${FM_HERDR_SUPERVISOR_RAPID_CYCLE_SECONDS:-1}" \
  FM_HERDR_SUPERVISOR_RAPID_CYCLE_LIMIT="${FM_HERDR_SUPERVISOR_RAPID_CYCLE_LIMIT:-20}" \
  FM_HERDR_SUPERVISOR_RAPID_CYCLE_FLOOR="${FM_HERDR_SUPERVISOR_RAPID_CYCLE_FLOOR:-5}" \
  FM_HERDR_SUPERVISOR_IDLE_INTERVAL=1 \
  HERDR_SESSION=default \
  "$supervisor" "$@"
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
# 1b. Herdr calls reject an unbounded timeout before creating any ownership.
# =============================================================================
HOME1B=$(new_home invalid-timeout)
make_arm_stub "$HOME1B/arm.sh" ok
fm_write_meta "$HOME1B/state/timeout-task.meta" "window=firstmate:fm-timeout-task"
out=$(FM_HERDR_SUPERVISOR_HERDR_TIMEOUT=0 run_supervisor "$HOME1B" "$FAKEBIN" ensure 2>&1) \
  && fail "zero Herdr timeout was accepted"
assert_contains "$out" "must be a positive integer" \
  "zero Herdr timeout names the validation failure"
assert_absent "$HOME1B/state/.herdr-supervisor" \
  "zero Herdr timeout creates no supervisor record"
pass "zero Herdr timeout is rejected before ownership"

# =============================================================================
# 2. A stale away marker alone does not own supervision.
# =============================================================================
HOME2=$(new_home afk)
make_arm_stub "$HOME2/arm.sh" ok
fm_write_meta "$HOME2/state/afk-task.meta" "window=firstmate:fm-afk-task"
: > "$HOME2/state/.afk"
out=$(run_supervisor "$HOME2" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a stale away marker does not suppress recovery"
pass "a stale away marker does not masquerade as a live owner"
stop_loop "$HOME2"

# =============================================================================
# 2b. Away mode owns supervision only while its lock names a live, identity-
#     matched daemon.
# =============================================================================
HOME2B=$(new_home live-afk)
make_arm_stub "$HOME2B/arm.sh" ok
fm_write_meta "$HOME2B/state/live-afk-task.meta" "window=firstmate:fm-live-afk-task"
: > "$HOME2B/state/.afk"
sleep 300 &
AFK_PID=$!
mkdir -p "$HOME2B/state/.supervise-daemon.lock"
printf '%s\n' "$AFK_PID" > "$HOME2B/state/.supervise-daemon.lock/pid"
fm_test_pid_identity "$AFK_PID" > "$HOME2B/state/.supervise-daemon.lock/pid-identity" \
  || fail "could not record the away daemon identity"
out=$(run_supervisor "$HOME2B" "$FAKEBIN" ensure 2>&1)
kill "$AFK_PID" 2>/dev/null || true
wait "$AFK_PID" 2>/dev/null || true
assert_contains "$out" "deferred" "a live away daemon defers the supervisor"
assert_contains "$out" "away mode" "the deferral names the live away owner"
assert_absent "$HOME2B/state/.herdr-supervisor" "a live away owner hosts no supervisor"
pass "away mode defers only to a live identity-matched daemon"

# =============================================================================
# 2c. A live away-daemon pid without matching identity is occupied, not free.
# =============================================================================
HOME2C=$(new_home ambiguous-afk)
make_arm_stub "$HOME2C/arm.sh" ok
fm_write_meta "$HOME2C/state/ambiguous-afk-task.meta" "window=firstmate:fm-ambiguous-afk-task"
: > "$HOME2C/state/.afk"
sleep 300 &
AFK_AMBIGUOUS_PID=$!
mkdir -p "$HOME2C/state/.supervise-daemon.lock"
printf '%s\n' "$AFK_AMBIGUOUS_PID" > "$HOME2C/state/.supervise-daemon.lock/pid"
rm -f "$HOME2C/state/.herdr-away-daemon-ambiguous" "$HOME2C/state/.herdr-supervisor-alarm"
status_out=$(run_supervisor "$HOME2C" "$FAKEBIN" status 2>&1)
assert_contains "$status_out" "other-owner: yes" "status recognizes an ambiguous away lock"
assert_absent "$HOME2C/state/.herdr-away-daemon-ambiguous" "status does not publish an ambiguity marker"
assert_absent "$HOME2C/state/.herdr-supervisor-alarm" "status does not escalate an ambiguity"
out=$(run_supervisor "$HOME2C" "$FAKEBIN" ensure 2>&1)
kill "$AFK_AMBIGUOUS_PID" 2>/dev/null || true
wait "$AFK_AMBIGUOUS_PID" 2>/dev/null || true
assert_contains "$out" "quarantined" "an ambiguous away lock defers the supervisor"
assert_absent "$HOME2C/state/.herdr-supervisor" "an ambiguous away owner hosts no supervisor"
assert_present "$HOME2C/state/.herdr-supervisor-alarm" "an ambiguous away lock leaves a durable alarm"
pass "away mode treats a live daemon with unknown identity as occupied"

# =============================================================================
# 3. A loaded Pi primary extension owns continuity; the supervisor stands down.
#    This is the negative control for the incident: when the extension IS
#    loaded, this new machinery must stay entirely out of the way.
# =============================================================================
HOME3=$(new_home pi-extension-loaded)
make_arm_stub "$HOME3/arm.sh" ok
fm_write_meta "$HOME3/state/ext-task.meta" "window=firstmate:fm-ext-task"
bash -c 'exec -a pi bash -c "sleep 300 & wait"' &
PI_OWNER_PID=$!
printf '%s\n' "$PI_OWNER_PID" > "$HOME3/state/.lock"
fm_test_pid_identity "$PI_OWNER_PID" > "$HOME3/state/.lock-pid-identity" \
  || fail "could not record the Pi session identity"
for pair in "fm-primary-pi-watch.ts:.pi-watch-extension-loaded" \
            "fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded"; do
  src=${pair%%:*}
  marker=${pair#*:}
  version=$(shasum -a 256 "$ROOT/.pi/extensions/$src" | awk '{print "sha256:" $1}')
  printf '%s\n%s\n' "$version" "$PI_OWNER_PID" > "$HOME3/state/$marker"
  fm_test_pid_identity "$PI_OWNER_PID" >> "$HOME3/state/$marker" \
    || fail "could not record the Pi extension marker identity"
done
out=$(run_supervisor "$HOME3" "$FAKEBIN" ensure 2>&1)
kill "$PI_OWNER_PID" 2>/dev/null || true
wait "$PI_OWNER_PID" 2>/dev/null || true
assert_contains "$out" "deferred" "a loaded Pi extension defers the supervisor"
assert_contains "$out" "Pi primary extension" "the deferral names the Pi extension owner"
assert_absent "$HOME3/state/.herdr-supervisor" "an extension-owned home hosts no supervisor"
pass "a loaded Pi extension is a provable owner and the supervisor stands down"

# =============================================================================
# 3a. The loaded Pi watcher extension defers takeover.
# =============================================================================
HOME3A=$(new_home pi-watch-extension-only)
make_arm_stub "$HOME3A/arm.sh" ok
fm_write_meta "$HOME3A/state/ext-only-task.meta" "window=firstmate:fm-ext-only-task"
bash -c 'exec -a pi bash -c "sleep 300 & wait"' &
PI_WATCH_OWNER_PID=$!
printf '%s\n' "$PI_WATCH_OWNER_PID" > "$HOME3A/state/.lock"
fm_test_pid_identity "$PI_WATCH_OWNER_PID" > "$HOME3A/state/.lock-pid-identity" \
  || fail "could not record the single-extension Pi session identity"
version=$(shasum -a 256 "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" | awk '{print "sha256:" $1}')
printf '%s\n%s\n' "$version" "$PI_WATCH_OWNER_PID" > "$HOME3A/state/.pi-watch-extension-loaded"
fm_test_pid_identity "$PI_WATCH_OWNER_PID" >> "$HOME3A/state/.pi-watch-extension-loaded" \
  || fail "could not record the single-extension marker identity"
out=$(run_supervisor "$HOME3A" "$FAKEBIN" ensure 2>&1)
kill "$PI_WATCH_OWNER_PID" 2>/dev/null || true
wait "$PI_WATCH_OWNER_PID" 2>/dev/null || true
assert_contains "$out" "deferred" "one loaded Pi extension defers the supervisor"
assert_absent "$HOME3A/state/.herdr-supervisor" "one loaded Pi extension hosts no supervisor"
pass "the individually loaded Pi watcher extension defers takeover"

# =============================================================================
# 3aa. The turn-end guard marker alone is not an ownership proof; its fallback
#      delegates arm and re-arm to Herdr instead of suppressing takeover.
# =============================================================================
HOME3AA=$(new_home turnend-extension-only)
make_arm_stub "$HOME3AA/arm.sh" ok
fm_write_meta "$HOME3AA/state/turnend-only-task.meta" "window=firstmate:fm-turnend-only-task"
bash -c 'exec -a pi bash -c "sleep 300 & wait"' &
PI_TURNEND_OWNER_PID=$!
printf '%s\n' "$PI_TURNEND_OWNER_PID" > "$HOME3AA/state/.lock"
fm_test_pid_identity "$PI_TURNEND_OWNER_PID" > "$HOME3AA/state/.lock-pid-identity" \
  || fail "could not record the turn-end-only Pi session identity"
version=$(shasum -a 256 "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" | awk '{print "sha256:" $1}')
printf '%s\n%s\n' "$version" "$PI_TURNEND_OWNER_PID" > "$HOME3AA/state/.pi-turnend-extension-loaded"
fm_test_pid_identity "$PI_TURNEND_OWNER_PID" >> "$HOME3AA/state/.pi-turnend-extension-loaded" \
  || fail "could not record the turn-end-only extension marker identity"
out=$(run_supervisor "$HOME3AA" "$FAKEBIN" ensure 2>&1)
kill "$PI_TURNEND_OWNER_PID" 2>/dev/null || true
wait "$PI_TURNEND_OWNER_PID" 2>/dev/null || true
assert_not_contains "$out" "deferred" "the turn-end marker alone does not defer the supervisor"
assert_present "$HOME3AA/state/.herdr-supervisor" "the turn-end-only fallback leaves Herdr continuity active"
pass "the turn-end marker alone does not suppress Herdr takeover"
stop_loop "$HOME3AA"

# =============================================================================
# 3b. A marker without process-instance identity never proves Pi ownership.
# =============================================================================
HOME3B=$(new_home pi-reused-pid)
make_arm_stub "$HOME3B/arm.sh" ok
fm_write_meta "$HOME3B/state/reused-task.meta" "window=firstmate:fm-reused-task"
printf '%s\n' "$$" > "$HOME3B/state/.lock"
for pair in "fm-primary-pi-watch.ts:.pi-watch-extension-loaded" \
            "fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded"; do
  src=${pair%%:*}
  marker=${pair#*:}
  version=$(shasum -a 256 "$ROOT/.pi/extensions/$src" | awk '{print "sha256:" $1}')
  printf '%s\n%s\n' "$version" "$$" > "$HOME3B/state/$marker"
done
out=$(run_supervisor "$HOME3B" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a non-harness pid does not suppress recovery"
pass "Pi ownership rejects a live non-harness pid despite matching markers"
stop_loop "$HOME3B"

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
# 5b. Identical rapid cycles back off before re-arming and write one alarm for
#     the episode without enqueueing a self-triggering supervisor wake.
# =============================================================================
HOME5B=$(new_home rapid-cycle)
fm_write_meta "$HOME5B/state/rapid-task.meta" "window=firstmate:fm-rapid-task"
cat > "$HOME5B/arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
C="${FM_TEST_ARM_COUNT:?}"
n=$(( $(cat "$C" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$C"
sleep 0.5
echo "signal: /fake/state/task.status"
SH
chmod +x "$HOME5B/arm.sh"
out=$(FM_HERDR_SUPERVISOR_RAPID_CYCLE_SECONDS=10 \
  FM_HERDR_SUPERVISOR_RAPID_CYCLE_LIMIT=2 \
  FM_HERDR_SUPERVISOR_RAPID_CYCLE_FLOOR=1 \
  run_supervisor "$HOME5B" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "rapid-cycle fixture establishes a supervisor"
wait_for 10 test -f "$HOME5B/state/.herdr-supervisor-rapid-episode" \
  || fail "identical rapid cycles did not create their episode marker"
before=$(cat "$HOME5B/arm.count")
sleep 0.2
after=$(cat "$HOME5B/arm.count")
[ "$after" = "$before" ] || fail "the rapid-cycle floor did not delay the next arm"
wait_for 5 arm_count_at_least "$HOME5B" $((before + 1)) \
  || fail "rapid-cycle supervision did not resume after its floor delay"
rows=$(awk '/check: herdr-supervisor/ { count++ } END { print count + 0 }' \
  "$HOME5B/state/.wake-queue" 2>/dev/null || echo 0)
[ "$rows" -le 1 ] || fail "rapid-cycle alarm appended $rows self-triggering queue rows"
assert_grep 'watcher cycles have been closing' "$HOME5B/state/.herdr-supervisor-alarm" \
  "rapid cycles leave one durable alarm"
pass "identical rapid cycles back off and emit one non-self-triggering alarm"
stop_loop "$HOME5B"

# =============================================================================
# 5c. A rapid episode clears only after three successful non-rapid cycles.
# =============================================================================
HOME5C=$(new_home stable-cycle)
fm_write_meta "$HOME5C/state/stable-task.meta" "window=firstmate:fm-stable-task"
cat > "$HOME5C/arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
C="${FM_TEST_ARM_COUNT:?}"
n=$(( $(cat "$C" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$C"
sleep 2
echo "signal: /fake/state/task.status"
SH
chmod +x "$HOME5C/arm.sh"
out=$(FM_HERDR_SUPERVISOR_RAPID_CYCLE_SECONDS=1 \
  run_supervisor "$HOME5C" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "stable-cycle fixture establishes a supervisor"
wait_for 5 arm_count_at_least "$HOME5C" 1 || fail "stable-cycle arm did not start"
printf 'reason=previous rapid episode\n' > "$HOME5C/state/.herdr-supervisor-alarm"
: > "$HOME5C/state/.herdr-supervisor-rapid-episode"
sleep 2.5
assert_present "$HOME5C/state/.herdr-supervisor-alarm" \
  "one non-rapid cycle does not clear the alarm"
wait_for 12 arm_count_at_least "$HOME5C" 4 \
  || fail "stable-cycle fixture did not produce three non-rapid cycles"
assert_absent "$HOME5C/state/.herdr-supervisor-alarm" \
  "three successful non-rapid cycles clear the alarm"
pass "rapid alarms clear only after three stable non-rapid cycles"
stop_loop "$HOME5C"

# =============================================================================
# 5d. The deterministic Herdr loop executes several cycles without invoking
#     any AI agent or model executable even when tripwires lead PATH.
# =============================================================================
HOME5D=$(new_home zero-ai-runtime)
make_arm_stub "$HOME5D/arm.sh" ok
fm_write_meta "$HOME5D/state/ai-task.meta" "window=firstmate:fm-ai-task"
mkdir -p "$HOME5D/fakebin"
cp "$FAKEBIN/herdr" "$HOME5D/fakebin/herdr"
cp "$FAKEBIN/herdr-workspace-control" "$HOME5D/fakebin/herdr-workspace-control"
for agent in pi claude codex opencode cursor grok kimi muse; do
  cat > "$HOME5D/fakebin/$agent" <<SH
#!/usr/bin/env bash
printf '%s\n' "$agent" > "\${FM_HOME}/ai-tripwire-fired"
exit 99
SH
  chmod +x "$HOME5D/fakebin/$agent"
done
out=$(FM_HERDR_SUPERVISOR_RAPID_CYCLE_SECONDS=0 \
  FM_HERDR_SUPERVISOR_RAPID_CYCLE_FLOOR=0 \
  run_supervisor "$HOME5D" "$HOME5D/fakebin" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "the zero-AI fixture establishes a supervisor"
wait_for 10 arm_count_at_least "$HOME5D" 3 \
  || fail "the zero-AI fixture did not complete several real arm cycles"
assert_absent "$HOME5D/ai-tripwire-fired" \
  "the Herdr runtime loop never invokes an AI executable"
pass "the Herdr runtime loop completes cycles without AI agents or model calls"
stop_loop "$HOME5D"

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

out=$(FM_TEST_READY_TIMEOUT=1 run_supervisor "$HOME5" "$FAKEBIN" run --generation "$GEN5" 2>&1) \
  && fail "an ordinary shell could launch the supervisor run path"
assert_contains "$out" "recorded Herdr pane and process" \
  "an ordinary shell cannot become an untracked supervisor"
pass "the public run path requires its recorded Herdr pane and process"

# =============================================================================
# 6b. A live watcher with a stale beacon is handed to the plain arm, whose
#      identity-safe singleton path handles stale recovery.
# =============================================================================
HOME6B=$(new_home stale-watcher)
fm_write_meta "$HOME6B/state/stale-task.meta" "window=firstmate:fm-stale-task"
sleep 300 &
STALE_WATCHER_PID=$!
mkdir -p "$HOME6B/state/.watch.lock"
printf '%s\n' "$HOME6B" > "$HOME6B/state/.watch.lock/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$HOME6B/state/.watch.lock/watcher-path"
fm_test_pid_identity "$STALE_WATCHER_PID" > "$HOME6B/state/.watch.lock/pid-identity" \
  || fail "could not record the stale watcher identity"
printf '%s\n' "$STALE_WATCHER_PID" > "$HOME6B/state/.watch.lock/pid"
touch -t 200001010000 "$HOME6B/state/.last-watcher-beat"
cat > "$HOME6B/arm.sh" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" > "$HOME6B/arm.args"
echo "signal: /fake/state/task.status"
SH
chmod +x "$HOME6B/arm.sh"
out=$(FM_WATCHER_STALE_GRACE=1 run_supervisor "$HOME6B" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a stale watcher still allows supervisor establishment"
wait_for 10 test -f "$HOME6B/arm.args" \
  || fail "the plain arm was not launched for a stale watcher"
[ -z "$(cat "$HOME6B/arm.args")" ] \
  || fail "the supervisor passed the forbidden restart mode to the arm"
pass "a stale watcher beacon uses the plain arm singleton path"
kill "$STALE_WATCHER_PID" 2>/dev/null || true
wait "$STALE_WATCHER_PID" 2>/dev/null || true
stop_loop "$HOME6B"

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
# 8b. Replacing an unhealthy generation retires its exact old workspace before
#     publishing the replacement, so no stale owner is left unreachable.
# =============================================================================
HOME8B=$(new_home replace-old-owner)
make_arm_stub "$HOME8B/arm.sh" ok
fm_write_meta "$HOME8B/state/replace-task.meta" "window=firstmate:fm-replace-task"
run_supervisor "$HOME8B" "$FAKEBIN" ensure >/dev/null 2>&1 \
  || fail "establish failed for replacement case"
GEN8B=$(record_field "$HOME8B" generation)
stop_loop "$HOME8B"
touch -t 200001010000 "$HOME8B/state/.herdr-supervisor-heartbeat"
out=$(run_supervisor "$HOME8B" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "an unhealthy owner is replaced"
[ "$(record_field "$HOME8B" generation)" != "$GEN8B" ] || fail "replacement reused the old generation"
assert_grep 'wZ' "$HOME8B/fakestate/closed-workspaces" \
  "replacement retired the exact old workspace before creating a successor"
[ "$(grep -c 'workspace.create' "$HOME8B/fakestate/calls.log")" = 2 ] \
  || fail "replacement did not create exactly one successor workspace"
pass "replacement retires the prior exact workspace before establishing a new generation"
stop_loop "$HOME8B"

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
# 10. A Herdr server restart changes the session socket and invalidates the
#     old binding without authorizing close through the replacement server.
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
old_socket_workspace_count=$(grep -c . "$HOME10/fakestate/closed-workspaces" 2>/dev/null || true)
out=$(run_supervisor "$HOME10" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "started" "a changed Herdr server permits a fresh supervisor generation"
quarantine_record=
for candidate in "$HOME10"/state/.herdr-supervisor-quarantine.*; do
  if [ -e "$candidate" ]; then
    quarantine_record=$candidate
    break
  fi
done
[ -n "$quarantine_record" ] || fail "the replaced server left no quarantine evidence"
new_socket_workspace_count=$(grep -c . "$HOME10/fakestate/closed-workspaces" 2>/dev/null || true)
[ "$new_socket_workspace_count" = "$old_socket_workspace_count" ] \
  || fail "server replacement closed a workspace through the new server"
pass "server replacement quarantines old ownership before fresh establishment"
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
# 10e. A supervisor identity change after the final pane query is unhealthy.
# =============================================================================
HOME10E=$(new_home identity-race)
make_arm_stub "$HOME10E/arm.sh" ok
fm_write_meta "$HOME10E/state/race-task.meta" "window=firstmate:fm-race-task"
run_supervisor "$HOME10E" "$FAKEBIN" ensure >/dev/null 2>&1 \
  || fail "establish failed for the identity-race case"
RACE_PID=$(cat "$HOME10E/fakestate/loop-pid")
mkdir -p "$HOME10E/fakeproc/$RACE_PID"
stat_tail=
for _ in $(seq 1 19); do stat_tail="$stat_tail 0"; done
stat_tail="$stat_tail 123"
printf '(bash)%s\n' "$stat_tail" > "$HOME10E/fakeproc/$RACE_PID/stat"
printf 'bash' > "$HOME10E/fakeproc/$RACE_PID/cmdline"
case "$(uname -s)" in
  Linux) race_identity_prefix=linux-starttime ;;
  *) race_identity_prefix=proc-starttime ;;
esac
sed "s/^loop_identity=.*/loop_identity=$race_identity_prefix=123 cmdline-hex=62617368/" \
  "$HOME10E/state/.herdr-supervisor-live" > "$HOME10E/state/.herdr-supervisor-live.new"
mv "$HOME10E/state/.herdr-supervisor-live.new" "$HOME10E/state/.herdr-supervisor-live"
printf '%s\n' "$HOME10E/fakeproc/$RACE_PID/stat" > "$HOME10E/fakestate/health-race-stat"
out=$(FM_PROC_ROOT_OVERRIDE="$HOME10E/fakeproc" run_supervisor "$HOME10E" "$FAKEBIN" status 2>&1)
assert_contains "$out" "supervisor: unhealthy" \
  "an identity change during health checking is unhealthy"
assert_contains "$out" "identity changed" \
  "the unhealthy reason names the post-query identity change"
pass "health revalidates supervisor identity after the pane query"
stop_loop "$HOME10E"

# =============================================================================
# 11. A repeatedly failing arm reaches an exact retry bound, alarms durably,
#     escalates through the existing wake queue, and leaves the continuity owner
#     alive for another recovery round.
# =============================================================================
HOME11=$(new_home failing-arm)
make_arm_stub "$HOME11/arm.sh" fail
fm_write_meta "$HOME11/state/failing-task.meta" "window=firstmate:fm-failing-task"
out=$(FM_TEST_READY_TIMEOUT=15 FM_TEST_RETRY_MAX=1 run_supervisor "$HOME11" "$FAKEBIN" ensure 2>&1) || true
alarm_has_retry_bound() { grep -q "retry bound was reached" "$1/state/.herdr-supervisor-alarm" 2>/dev/null; }
wait_for 25 alarm_has_retry_bound "$HOME11" \
  || fail "a repeatedly failing arm left no durable retry-bound alarm"
assert_grep "retry bound was reached" "$HOME11/state/.herdr-supervisor-alarm" \
  "the alarm names the exact retry-bound exhaustion"
assert_grep "continuity owner remains active" "$HOME11/state/.herdr-supervisor-alarm" \
  "the alarm confirms the continuity owner remains alive"
queue_has_escalation() { grep -q 'herdr-supervisor' "$1/state/.wake-queue" 2>/dev/null; }
wait_for 10 queue_has_escalation "$HOME11" \
  || fail "the failure was not escalated onto the durable wake queue"
assert_grep 'check' "$HOME11/state/.wake-queue" "the escalation is a check-kind wake"
count=$(cat "$HOME11/arm.count" 2>/dev/null || echo 0)
[ "$count" -le 20 ] || fail "the failing arm retried $count times; the retry rounds were not bounded"
assert_no_grep 'attempt=6' "$HOME11/state/.herdr-supervisor.log" \
  "a retry round exceeded the configured five-attempt bound"
failure_pid=$(cat "$HOME11/fakestate/loop-pid" 2>/dev/null || true)
kill -0 "$failure_pid" 2>/dev/null || fail "retry exhaustion exited the sole continuity owner"
pass "a repeatedly failing arm is bounded, alarms, escalates, and keeps its owner alive"
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
rm -f "$HOME13/fakestate/create-incomplete"
out=$(run_supervisor "$HOME13" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a verified absent incomplete create can be retried"
find "$HOME13/state" -maxdepth 1 -name '.herdr-supervisor-quarantine.pending.*' -print -quit | grep -q . \
  || fail "invisible incomplete create was not retained as quarantine evidence"
assert_grep 'incomplete or ambiguous Herdr create was quarantined' "$HOME13/state/.herdr-supervisor-alarm" \
  "the quarantined incomplete create leaves an actionable alarm"
assert_absent "$HOME13/state/.herdr-supervisor-pending-cleanup" "quarantining the incomplete create releases the active pending slot"
stop_loop "$HOME13"
pass "verified absence of an incomplete create does not permanently block recovery"

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
assert_grep "workspace=wPART" "$HOME13B/state/.herdr-supervisor-pending-cleanup" \
  "the pending cleanup receipt preserves the returned workspace id"
assert_grep "tab=wPART:t1" "$HOME13B/state/.herdr-supervisor-pending-cleanup" \
  "the pending cleanup receipt preserves the returned tab id"
[ "$(cat "$HOME13B/arm.count" 2>/dev/null || echo 0)" = 0 ] \
  || fail "a partial establish armed the watcher anyway"
rm -f "$HOME13B/fakestate/create-partial"
out=$(run_supervisor "$HOME13B" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a quarantined partial create permits a fresh establish"
PARTIAL_QUARANTINE=$(find "$HOME13B/state" -maxdepth 1 -name '.herdr-supervisor-quarantine.pending.*' -print -quit)
[ -n "$PARTIAL_QUARANTINE" ] || fail "partial create quarantine evidence was not retained"
assert_grep "workspace=wPART" "$PARTIAL_QUARANTINE" \
  "the quarantine preserves the partial workspace id without adopting it"
assert_absent "$HOME13B/fakestate/closed-workspaces" \
  "reconciling a partial response never closes its ambiguous workspace"
pass "a partial Herdr create response is quarantined without label adoption or cleanup"
stop_loop "$HOME13B"

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
printf '17:19:23:15\n' > "$HOME13E/state/expected-arm-tuning"
out=$(FM_GUARD_GRACE=17 FM_WATCHER_STALE_GRACE=19 FM_ARM_CONFIRM_TIMEOUT=23 \
  run_supervisor "$HOME13E" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a long home path still establishes"
wait_for 10 test -f "$HOME13E/state/arm-consumer-ok" \
  || fail "the pane consumer rejected the caller's tuning"
pass "the Herdr pane consumer executes a short launcher with caller tuning"
stop_loop "$HOME13E"

# =============================================================================
# 13f. The supervisor remains healthy while a foreground arm is waiting, and
#      termination cleans up that exact arm child before releasing the record.
# =============================================================================
HOME13F=$(new_home foreground-arm)
fm_write_meta "$HOME13F/state/foreground-task.meta" "window=firstmate:fm-foreground-task"
cat > "$HOME13F/arm.sh" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$\$" > "$HOME13F/arm.pid"
sleep 300
echo "signal: /fake/state/task.status"
SH
chmod +x "$HOME13F/arm.sh"
out=$(FM_HERDR_SUPERVISOR_HEARTBEAT_GRACE=10 run_supervisor "$HOME13F" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "a waiting arm still establishes"
sleep 4
out=$(FM_HERDR_SUPERVISOR_HEARTBEAT_GRACE=10 run_supervisor "$HOME13F" "$FAKEBIN" status 2>&1)
assert_contains "$out" "supervisor: healthy" "a waiting arm keeps the supervisor heartbeat fresh"
ARM_PID=$(cat "$HOME13F/arm.pid" 2>/dev/null || true)
[ -n "$ARM_PID" ] || fail "the foreground arm did not publish its child pid"
LOOP_PID=$(cat "$HOME13F/fakestate/loop-pid" 2>/dev/null || true)
kill -TERM "$LOOP_PID" 2>/dev/null || fail "could not terminate the foreground supervisor"
wait_for 10 sh -c "! kill -0 $ARM_PID 2>/dev/null" \
  || fail "terminating the supervisor left its foreground arm child alive"
pass "foreground arm heartbeat and exact-child cleanup remain bounded"

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

# =============================================================================
# 17b. Changing config/herdr-supervisor to off retires the exact running owner
#      without waiting for another ensure call.
# =============================================================================
HOME17B=$(new_home opt-out-transition)
make_arm_stub "$HOME17B/arm.sh" ok
fm_write_meta "$HOME17B/state/off-transition-task.meta" "window=firstmate:fm-off-transition-task"
run_supervisor "$HOME17B" "$FAKEBIN" ensure >/dev/null 2>&1 \
  || fail "establish failed for the opt-out transition"
printf 'off\n' > "$HOME17B/config/herdr-supervisor"
record_gone() { [ ! -f "$1/state/.herdr-supervisor" ]; }
wait_for 10 record_gone "$HOME17B" \
  || fail "the running owner did not retire after config changed to off"
assert_grep 'wZ' "$HOME17B/fakestate/closed-workspaces" \
  "config off retired the exact supervisor workspace"
pass "config/herdr-supervisor=off retires a running owner on the next loop pass"

# =============================================================================
# 18. A foreign owner is a handoff, not a teardown: the Herdr owner remains as
#     a standby and resumes when the foreign owner disappears.
# =============================================================================
HOME18=$(new_home handoff-standby)
make_arm_stub "$HOME18/arm.sh" ok
fm_write_meta "$HOME18/state/handoff-task.meta" "window=firstmate:fm-handoff-task"
run_supervisor "$HOME18" "$FAKEBIN" ensure >/dev/null 2>&1 \
  || fail "establish failed for the handoff case"
wait_for 10 arm_count_at_least "$HOME18" 2 \
  || fail "the handoff supervisor did not reach a steady arm cycle"
before=$(cat "$HOME18/arm.count" 2>/dev/null || echo 0)
: > "$HOME18/state/.afk"
sleep 300 &
HANDOFF_PID=$!
mkdir -p "$HOME18/state/.supervise-daemon.lock"
printf '%s\n' "$HANDOFF_PID" > "$HOME18/state/.supervise-daemon.lock/pid"
fm_test_pid_identity "$HANDOFF_PID" > "$HOME18/state/.supervise-daemon.lock/pid-identity" \
  || fail "could not record the handoff daemon identity"
sleep 2
after=$(cat "$HOME18/arm.count" 2>/dev/null || echo 0)
[ "$after" = "$before" ] || fail "the standby supervisor armed while a foreign owner was live"
assert_present "$HOME18/state/.herdr-supervisor" \
  "the handoff retains the exact supervisor binding"
kill "$HANDOFF_PID" 2>/dev/null || true
wait "$HANDOFF_PID" 2>/dev/null || true
rm -rf "$HOME18/state/.supervise-daemon.lock" "$HOME18/state/.afk"
wait_for 10 arm_count_at_least "$HOME18" $((before + 1)) \
  || fail "the standby supervisor did not resume after the foreign owner disappeared"
pass "handoff retains a standby owner and resumes after foreign ownership ends"
stop_loop "$HOME18"

# =============================================================================
# 19. A failed cleanup keeps the exact binding quarantined until a later retry
#     closes it, and only then permits a replacement.
# =============================================================================
HOME19=$(new_home cleanup-quarantine)
make_arm_stub "$HOME19/arm.sh" ok
fm_write_meta "$HOME19/state/quarantine-task.meta" "window=firstmate:fm-quarantine-task"
run_supervisor "$HOME19" "$FAKEBIN" ensure >/dev/null 2>&1 \
  || fail "establish failed for the cleanup case"
old_generation=$(record_field "$HOME19" generation)
: > "$HOME19/fakestate/close-fails"
out=$(run_supervisor "$HOME19" "$FAKEBIN" retire --reason "cleanup test" 2>&1) \
  && fail "retire reported success when Herdr close failed"
assert_present "$HOME19/state/.herdr-supervisor" \
  "cleanup failure preserves the supervisor binding"
[ "$(record_field "$HOME19" mode)" = quarantine ] \
  || fail "cleanup failure did not quarantine the binding"
assert_absent "$HOME19/fakestate/closed-workspaces" \
  "cleanup failure does not claim a workspace was closed"
rm -f "$HOME19/fakestate/close-fails"
out=$(run_supervisor "$HOME19" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "started" "a later ensure retries quarantined cleanup"
[ "$(record_field "$HOME19" generation)" != "$old_generation" ] \
  || fail "cleanup retry reused the quarantined generation"
assert_grep 'wZ' "$HOME19/fakestate/closed-workspaces" \
  "cleanup retry closes the exact quarantined workspace"
pass "cleanup failures quarantine exact ownership before replacement"
stop_loop "$HOME19"

# =============================================================================
# 20. A failed arm leaves durable evidence even when the next attempt succeeds.
# =============================================================================
HOME20=$(new_home arm-evidence)
fm_write_meta "$HOME20/state/evidence-task.meta" "window=firstmate:fm-evidence-task"
cat > "$HOME20/arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
C="${FM_TEST_ARM_COUNT:?}"
n=$(( $(cat "$C" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$C"
if [ "$n" -eq 1 ]; then
  echo "watcher: FAILED - injected first arm failure"
  exit 1
fi
echo "signal: /fake/state/task.status"
SH
chmod +x "$HOME20/arm.sh"
run_supervisor "$HOME20" "$FAKEBIN" ensure >/dev/null 2>&1 \
  || fail "establish failed for the arm-evidence case"
wait_for 10 arm_count_at_least "$HOME20" 2 \
  || fail "the arm did not recover after its first failure"
assert_grep 'cycle-failed' "$HOME20/state/.herdr-supervisor.log" \
  "the failed arm remains in the durable ledger"
assert_grep 'check' "$HOME20/state/.wake-queue" \
  "the failed arm remains in the durable wake queue after recovery"
assert_grep 'reason=' "$HOME20/state/.herdr-supervisor-alarm" \
  "the latest durable alarm remains actionable after recovery"
assert_grep 'reason=watcher arm attempt' "$HOME20/state/.herdr-supervisor-alarm-history" \
  "the failed arm remains in the per-attempt alarm history"
pass "each failed arm leaves durable evidence after a later success"
stop_loop "$HOME20"

# =============================================================================
# 21. An unverifiable arm child is abandoned after bounded cleanup, while the
#     same Herdr-owned supervisor immediately keeps trying fresh arms.
# =============================================================================
HOME21=$(new_home unknown-arm-abandon)
fm_write_meta "$HOME21/state/unknown-arm-task.meta" "window=firstmate:fm-unknown-arm-task"
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for arg in "$@"; do
  [ "$previous" = -p ] && pid=$arg
  previous=$arg
done
if [ -n "$pid" ] && [ -f "${FM_HOME:-}/first-unknown-arm.pid" ] \
  && [ "$pid" = "$(cat "$FM_HOME/first-unknown-arm.pid")" ] \
  && [[ " $* " == *" lstart="* ]]; then
  exit 1
fi
exec /bin/ps "$@"
SH
chmod +x "$FAKEBIN/ps"
cat > "$HOME21/arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
C="${FM_TEST_ARM_COUNT:?}"
n=$(( $(cat "$C" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$C"
if [ "$n" -eq 1 ]; then
  printf '%s\n' "$$" > "$FM_HOME/first-unknown-arm.pid"
  sleep 10
fi
echo "signal: /fake/state/task.status"
SH
chmod +x "$HOME21/arm.sh"
out=$(FM_TEST_UNKNOWN_ARM=1 FM_TEST_UNKNOWN_ARM_TIMEOUT=1 FM_TEST_UNKNOWN_ARM_RETRY_LIMIT=1 \
  FM_HERDR_SUPERVISOR_RAPID_CYCLE_SECONDS=999999 \
  FM_PROC_ROOT_OVERRIDE="$HOME21/fakeproc" run_supervisor "$HOME21" "$FAKEBIN" ensure 2>&1)
assert_contains "$out" "herdr-supervisor: started" "an unverifiable arm still establishes the supervisor"
wait_for 10 arm_count_at_least "$HOME21" 2 \
  || fail "the supervisor did not launch a fresh arm after abandoning the unknown child"
assert_present "$HOME21/state/.herdr-supervisor" \
  "abandoning an unknown arm retains the supervisor binding"
assert_present "$HOME21/state/.herdr-supervisor-live" \
  "abandoning an unknown arm retains the supervisor liveness record"
assert_grep 'abandoning child pid=' "$HOME21/state/.herdr-supervisor-alarm" \
  "abandoning an unknown arm leaves a durable child diagnostic"
UNKNOWN_ARM_PID=$(cat "$HOME21/first-unknown-arm.pid" 2>/dev/null || true)
stop_loop "$HOME21"
if [ -n "$UNKNOWN_ARM_PID" ]; then
  kill -TERM "$UNKNOWN_ARM_PID" 2>/dev/null || true
  wait "$UNKNOWN_ARM_PID" 2>/dev/null || true
fi
pass "unknown arm children are abandoned without stopping supervisor recovery"

echo "all fm-herdr-supervisor tests passed"
