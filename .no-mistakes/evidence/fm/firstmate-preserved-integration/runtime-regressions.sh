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
. /Users/criz/.no-mistakes/worktrees/da589fef49ee/01M2KC5KRP89F2TMQNEXSZEMN5/tests/lib.sh
# shellcheck source=tests/herdr-test-safety.sh
. /Users/criz/.no-mistakes/worktrees/da589fef49ee/01M2KC5KRP89F2TMQNEXSZEMN5/tests/herdr-test-safety.sh

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# A Herdr pane identity leaked in from the developer's own terminal would make
# the adapter resolve a launcher this fake never models.
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-herdr-supervisor-tests)

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
scoped=0
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  scoped=1
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
    if [ "$scoped" -eq 1 ]; then
      scoped_count=$(( $(cat "$S/scoped-status-count" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$scoped_count" > "$S/scoped-status-count"
    fi
    if { [ -f "$S/hang-version-status" ] && [ "$scoped" -eq 0 ]; } \
      || { [ -f "$S/hang-session-status" ] && [ "$scoped" -eq 1 ] && [ "$((scoped_count % 2))" -eq 0 ]; }; then
      printf '%s\n' "$$" >> "$S/hung-pids"
      sleep 300
      exit 0
    fi
    printf '%s\n' "$scoped" >> "$S/completed-status"
    running=true
    server_status=running
    compatible=true
    [ ! -f "$S/server-stopped" ] || { running=false; server_status=stopped; }
    [ ! -f "$S/server-incompatible" ] || compatible=false
    # The shape fm_backend_herdr_server_status_healthy requires: status,
    # compatibility, and the server protocol, not only the running flag.
    printf '{"client":{"version":"0.8.2","protocol":16},"server":{"running":%s,"status":"%s","compatible":%s,"protocol":16}}\n' \
      "$running" "$server_status" "$compatible"
    exit 0
    ;;
  session)
    if [ "${2:-}" = list ]; then
      if [ -f "$S/hang-session-list" ]; then
        printf '%s\n' "$$" >> "$S/hung-pids"
        sleep 300
        exit 0
      fi
      [ ! -f "$S/session-list-fails" ] || exit 3
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
        # A freshly created workspace is live again even if an earlier
        # generation's exact workspace of the same fake id was closed.
        rm -f "$S/workspace-closed"
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
  # The workspace-control helper is honest about closure the way the real
  # bin/backends/herdr-workspace-control.py is against a real server: a closed
  # workspace disappears from `list`, and closing it again fails (the real
  # helper exits 4 on Herdr's workspace_not_found error).
  # `close-abruptly-crashes-loop` models an ABRUPT loss of the supervisor loop's
  # process tree at the exact moment the native close of its own hosting
  # workspace succeeds - deliberately unhandled (SIGKILL, from a child of the
  # loop, sent only to the loop pid this test's own fixture recorded), because
  # production's own termination trap answers HUP/TERM/INT identically and a
  # signal that trap can catch would exercise graceful shutdown, not the crash
  # this fixture exists to model. This is a fixture-modeled abrupt loss, not a
  # proven reproduction of the real backend's exact signal sequence or of
  # whole-process-tree termination; treat it as that model, not as native-
  # equivalence evidence. Graceful HUP handling has its own deterministic
  # coverage, parameterized alongside TERM in section 24 below.
  cat > "$fb/herdr-workspace-control" <<'SH'
#!/usr/bin/env bash
set -u
operation=$3
workspace=${4:-}
S="${FM_FAKE_HERDR_STATE:?}"
printf 'wsctl\x1f%s\x1f%s\n' "$operation" "$workspace" >> "$S/calls.log"
case "$operation" in
  list)
    [ ! -f "$S/list-fails" ] || exit 3
    if [ -f "$S/list-response" ]; then
      cat "$S/list-response"
      exit 0
    fi
    live=$(cat "$S/workspace" 2>/dev/null || true)
    label=$(cat "$S/workspace-label" 2>/dev/null || true)
    if [ -n "$live" ] && [ ! -f "$S/workspace-closed" ]; then
      printf '{"id":"fm-workspace-control","result":{"workspaces":[{"workspace_id":"%s","label":"%s"}]}}\n' \
        "$live" "$label"
    else
      printf '{"id":"fm-workspace-control","result":{"workspaces":[]}}\n'
    fi
    ;;
  close)
    [ ! -f "$S/close-fails" ] || exit 1
    if [ "$workspace" = "$(cat "$S/workspace" 2>/dev/null || true)" ] && [ -f "$S/workspace-closed" ]; then
      exit 4
    fi
    printf '%s\n' "$workspace" >> "$S/closed-workspaces"
    [ "$workspace" != "$(cat "$S/workspace" 2>/dev/null || true)" ] || : > "$S/workspace-closed"
    if [ -f "$S/close-abruptly-crashes-loop" ]; then
      loop=$(cat "$S/loop-pid" 2>/dev/null || true)
      [ -z "$loop" ] || kill -9 "$loop" 2>/dev/null || true
    fi
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
  # Install ONCE per home. The loop this establishes runs
  # `exec bash <supervisor_root>/bin/fm-herdr-supervisor.sh run`, so re-copying
  # on every call truncates and rewrites the exact file a live loop is still
  # reading. Bash re-reads a script at each command boundary, so the loop then
  # reads garbage or hits EOF and dies without a word - which is why a later
  # call in the same home would return no output at all and an assertion would
  # fail with an empty result, non-deterministically and only under load.
  # Each home stubs its arm before its first call, so one install is enough.
  supervisor_root="$home/supervisor-root"
  if [ ! -e "$supervisor_root/.installed" ]; then
    mkdir -p "$supervisor_root/bin"
    cp "$ROOT"/bin/*.sh "$supervisor_root/bin/"
    cp -R "$ROOT/bin/backends" "$supervisor_root/bin/"
    cp "$home/arm.sh" "$supervisor_root/bin/fm-watch-arm.sh"
    chmod +x "$supervisor_root/bin"/*.sh
    : > "$supervisor_root/.installed"
  fi
  supervisor="$supervisor_root/bin/fm-herdr-supervisor.sh"
  HOME="$home" \
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

claim_alarm_delivery_test() {
  local home wake_count
  home=$(new_home claim-alarm-delivery)
  make_arm_stub "$home/arm.sh" ok
  printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
  printf 'unreadable queue lock\n' > "$home/state/.wake-queue.lock"

  HOME="$home" FM_HERDR_SUPERVISOR_LOCK_TRIES=2 \
    run_supervisor "$home" "$FAKEBIN" ensure > "$home/ensure.out" 2>&1 \
    && fail "an undelivered claim alarm reported success: $(cat "$home/ensure.out")"
  assert_grep 'queue_persistence=1' "$home/state/.herdr-supervisor-emergency" \
    "the first claim alarm did not exercise queue persistence failure"
  assert_absent "$home/state/.herdr-supervisor-claim-alarm" \
    "failed alarm delivery suppressed subsequent retries"
  assert_absent "$home/state/.wake-queue" \
    "a blocked queue unexpectedly received the alarm"

  rm "$home/state/.wake-queue.lock"
  HOME="$home" FM_HERDR_SUPERVISOR_LOCK_TRIES=2 \
    run_supervisor "$home" "$FAKEBIN" ensure > "$home/ensure.out" 2>&1 \
    && fail "an unresolved claim reported success after queue recovery"
  assert_grep 'the continuity ownership claim could not be acquired within its bounded retry window' \
    "$home/state/.wake-queue" "the claim alarm was not retried after queue recovery"
  assert_grep 'unresolved' "$home/state/.herdr-supervisor-claim-alarm" \
    "successful alarm delivery did not record suppression"

  HOME="$home" FM_HERDR_SUPERVISOR_LOCK_TRIES=2 \
    run_supervisor "$home" "$FAKEBIN" ensure > "$home/ensure.out" 2>&1 \
    && fail "a repeatedly unresolved claim reported success"
  wake_count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
  [ "$wake_count" -eq 1 ] || fail "successful delivery was repeated ($wake_count wakes)"
  assert_absent "$home/arm.count" "claim alarm delivery unexpectedly armed a watcher"
  pass "failed claim alarm delivery retries until persisted, then suppresses repeats"
}

claim_probe() {
  local home=$1
  shift
  HOME="$home" PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$home/fakestate" \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SUPERVISION_MODEL=extension FM_HERDR_SUPERVISOR_LOCK_TRIES="${FM_TEST_CLAIM_LOCK_TRIES:-2}" \
  FM_SUP_SCRIPT="$ROOT/bin/fm-herdr-supervisor.sh" exec bash "$@"
}

# shellcheck disable=SC2016 # Probe scripts expand variables in the child bash.
claim_alarm_concurrent_test() (
  home=$(new_home claim-alarm-concurrent)
  pids=()
  trap 'for pid in "${pids[@]:-}"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done; wait' EXIT
  printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
  # Four real processes contend on the episode lock; give them a bounded
  # contention budget instead of the two-try budget used by fault probes.
  for n in 1 2 3 4; do
    FM_TEST_CLAIM_LOCK_TRIES=100 claim_probe "$home" -c '
      set --
      . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
      cmd_ensure "concurrent probe"
    ' > "$home/ensure-$n.out" 2>&1 &
    pids+=("$!")
  done
  for probe_pid in "${pids[@]}"; do
    wait "$probe_pid" && fail "a concurrent unresolved claim reported success"
  done
  pids=()
  count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue" 2>/dev/null || true)
  [ "$count" = 1 ] || fail "concurrent ensure calls published $count alarms: $(cat "$home"/ensure-*.out)"
  pass "concurrent ensure calls publish one alarm for an unresolved episode"
)

# shellcheck disable=SC2016 # Probe scripts expand variables in the child bash.
claim_alarm_loop_test() (
  mode=$1
  home=$(new_home "claim-alarm-loop-$mode")
  loop_pid='' owner_pid=''
  trap 'for pid in "$loop_pid" "$owner_pid"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done; wait' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'generation=fixture\nmode=active\n' > "$home/state/.herdr-supervisor"
  touch "$home/state/task.meta"
  printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
  claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    printf "%s\n" "${BASHPID:-$$}" > "$STATE/loop-test-pid"
    LOOP_GENERATION=fixture
    IDLE_INTERVAL=123
    loop_launch_wait() { return 0; }
    sleep() {
      if [ "$1" != 123 ]; then command sleep "$@"; return; fi
      # loop_sleep backgrounds this call (bin/fm-herdr-supervisor.sh), forking
      # a fresh subshell on every idle cycle, so a shell-variable step counter
      # would never see its own prior increment and would re-touch paused-1
      # forever. Derive the step from durable paused-N markers instead.
      local n=1
      while [ -e "$STATE/paused-$n" ]; do n=$((n + 1)); done
      touch "$STATE/paused-$n"
      deadline=$(( $(date +%s) + 30 ))
      while [ ! -e "$STATE/resume-$n" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || exit 1
        command sleep 0.05
      done
    }
    cmd_run
  ' > "$home/loop.out" 2>&1 &
  loop_pid=$!
  wait_for 10 test -s "$home/state/loop-test-pid" || fail "the loop process did not start"
  [ "$(cat "$home/state/loop-test-pid")" = "$loop_pid" ] || fail "the loop probe is not the registered child"
  wait_for 20 test -e "$home/state/paused-1" || fail "the loop did not reach its failed-claim pause: $(cat "$home/loop.out")"
  assert_grep 'could not be acquired before arming' "$home/state/.wake-queue" \
    "the loop did not publish its initial claim alarm"
  if [ "$mode" = shared ]; then
    (claim_probe "$home" -c '
      set --
      . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
      cmd_ensure "same episode"
    ') > "$home/ensure.out" 2>&1 && fail "an unresolved ensure claim reported success"
    count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
    [ "$count" = 1 ] || fail "ensure and loop published $count alarms for one episode"
  fi
  rm "$home/state/.supervision-claim.lock"
  claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    fm_supervision_claim_acquire "$SUPERVISION_CLAIM" 20 || exit 1
    trap "fm_lock_release \"\$SUPERVISION_CLAIM\"" EXIT
    trap "exit 0" TERM INT
    printf "%s\n" "${BASHPID:-$$}" > "$STATE/owner-test-pid"
    touch "$STATE/owner-ready"
    while :; do sleep 0.05; done
  ' > "$home/owner.out" 2>&1 &
  owner_pid=$!
  wait_for 10 test -e "$home/state/owner-ready" || fail "the recovery owner did not acquire its claim"
  [ "$(cat "$home/state/owner-test-pid")" = "$owner_pid" ] || fail "the owner probe is not the registered child"
  touch "$home/state/resume-1"
  wait_for 20 test -e "$home/state/paused-2" || fail "the loop did not observe the recovery owner"
  kill "$owner_pid"
  wait "$owner_pid" || fail "the recovery owner failed to release its claim: $(cat "$home/owner.out")"
  owner_pid=
  assert_absent "$home/state/.supervision-claim.lock" "the recovery owner retained its claim"
  printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
  touch "$home/state/resume-2"
  wait_for 20 test -e "$home/state/paused-3" || fail "the loop did not reach the later failure"
  count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
  [ "$count" = 2 ] || fail "the loop failed to alarm after actual owner recovery ($count alarms)"
  printf 'generation=retired\n' > "$home/state/.herdr-supervisor"
  touch "$home/state/resume-3"
  wait "$loop_pid" || fail "the loop did not stop after generation retirement"
  loop_pid=
  pass "the $mode loop episode alarms again after a healthy owner comes and goes"
)

# shellcheck disable=SC2016 # Probe scripts expand variables in the child bash.
claim_alarm_monitor_test() (
  home=$(new_home claim-alarm-monitor)
  monitor_pid='' owner_pid=''
  trap 'for pid in "$monitor_pid" "$owner_pid"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done; wait' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf '%s\n' "${BASHPID:-$$}" > "$home/state/.lock"
  touch "$home/state/task.meta"
  printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
  claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    monitor_sleep() {
      touch "$STATE/monitor-paused"
      deadline=$(( $(date +%s) + 30 ))
      while [ ! -e "$STATE/monitor-resume" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 0.05
      done
    }
    cmd_monitor_run "$(session_owner_identity)"
  ' > "$home/monitor.out" 2>&1 &
  monitor_pid=$!
  wait_for 20 test -e "$home/state/monitor-paused" || fail "the monitor did not reach its failed-claim pause"
  assert_grep 'could not be acquired within its bounded retry window' "$home/state/.wake-queue" \
    "the monitor did not publish its initial claim alarm"
  cp "$home/state/.herdr-supervisor-claim-alarm" "$home/alarm-before-status"
  cp "$home/state/.wake-queue" "$home/queue-before-status"
  rm "$home/state/.supervision-claim.lock"
  claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    fm_supervision_claim_acquire "$SUPERVISION_CLAIM" 20 || exit 1
    trap "fm_lock_release \"\$SUPERVISION_CLAIM\"" EXIT
    trap "exit 0" TERM INT
    touch "$STATE/owner-ready"
    while :; do sleep 0.05; done
  ' > "$home/owner.out" 2>&1 &
  owner_pid=$!
  wait_for 10 test -e "$home/state/owner-ready" || fail "the monitor recovery owner did not acquire its claim"
  (claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    cmd_status 0
  ') > "$home/status.out" 2>&1 || fail "the read-only status probe failed"
  assert_grep 'other-owner: yes' "$home/status.out" "status did not recognize the recovered owner"
  cmp -s "$home/alarm-before-status" "$home/state/.herdr-supervisor-claim-alarm" \
    || fail "read-only status changed claim alarm suppression"
  cmp -s "$home/queue-before-status" "$home/state/.wake-queue" \
    || fail "read-only status changed the durable wake queue"
  assert_absent "$home/state/.herdr-supervisor-claim-alarm.lock" "read-only status left an alarm lock"
  touch "$home/state/monitor-resume"
  wait "$monitor_pid" || fail "the monitor did not stand down for the recovered owner"
  monitor_pid=
  assert_grep 'stood down: another continuity owner' "$home/state/.herdr-supervisor.log" \
    "the monitor did not take its healthy-owner handoff path"
  assert_absent "$home/state/.herdr-supervisor-monitor" "the monitor retained its record after handoff"
  kill "$owner_pid"
  wait "$owner_pid" || fail "the monitor recovery owner failed to release its claim"
  owner_pid=
  assert_absent "$home/state/.supervision-claim.lock" "the monitor recovery owner retained its claim"
  printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
  (claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    cmd_ensure "failure after monitor handoff"
  ') > "$home/ensure.out" 2>&1 && fail "a later unresolved claim reported success"
  count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
  [ "$count" = 2 ] || fail "monitor handoff suppressed the later failure ($count alarms)"
  pass "monitor handoff resets claim alarms while status remains read-only"
)

# shellcheck disable=SC2016 # Probe scripts expand variables in the child bash.
claim_alarm_contended_recovery_test() (
  mode=$1
  home=$(new_home "claim-alarm-contention-$mode")
  writer_pid='' monitor_pid='' owner_pid=''
  trap 'for pid in "$writer_pid" "$monitor_pid" "$owner_pid"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done; wait' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf '%s\n' "${BASHPID:-$$}" > "$home/state/.lock"
  touch "$home/state/task.meta"
  printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
  start_contended_owner() {
  rm -f "$home/state/owner-ready"
  claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    fm_supervision_claim_acquire "$SUPERVISION_CLAIM" 20 || exit 1
    trap "fm_lock_release \"\$SUPERVISION_CLAIM\"" EXIT
    trap "exit 0" TERM INT
    touch "$STATE/owner-ready"
    while :; do sleep 0.05; done
  ' > "$home/owner.out" 2>&1 &
  owner_pid=$!
  wait_for 10 test -e "$home/state/owner-ready" || fail "the contended recovery owner did not acquire its claim"
  }
  start_contended_monitor() {
  claim_probe "$home" -c '
    probe_mode=$1
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    if { [ "$probe_mode" = identity-arrival ] || [ "$probe_mode" = identity-replaced ]; }; then
      claim_alarm_episode() {
        local snapshot rc
        snapshot=$(bash -c ". \"\$FM_SUP_SCRIPT\" \"\" >/dev/null 2>&1 || true; claim_alarm_episode")
        rc=$?
        if [ ! -e "$STATE/snapshot-paused" ]; then
          touch "$STATE/snapshot-paused"
          deadline=$(( $(date +%s) + 45 ))
          while [ ! -e "$STATE/snapshot-resume" ]; do
            [ "$(date +%s)" -lt "$deadline" ] || return 1
            sleep 0.05
          done
        fi
        printf "%s" "$snapshot"
        return "$rc"
      }
    fi
    step=0
    monitor_sleep() {
      step=$((step + 1))
      touch "$STATE/monitor-paused-$step"
      deadline=$(( $(date +%s) + 45 ))
      while [ ! -e "$STATE/monitor-resume-$step" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 0.05
      done
    }
    cmd_monitor_run "$(session_owner_identity)" || exit 1
    touch "$STATE/monitor-finished"
  ' _ "$mode" > "$home/monitor.out" 2>&1 &
  monitor_pid=$!
  }
  expected_count=2
  if [ "$mode" = identity-replaced ]; then
    (claim_probe "$home" "$ROOT/bin/fm-herdr-supervisor.sh" ensure) \
      > "$home/initial-episode.out" 2>&1 && fail "the initial unresolved claim reported success"
    expected_count=3
  fi
  if { [ "$mode" = identity-arrival ] || [ "$mode" = identity-replaced ]; }; then
    start_contended_monitor
    wait_for 20 test -e "$home/state/snapshot-paused" || fail "the monitor did not capture its initial episode"
    if [ "$mode" = identity-arrival ]; then
      assert_absent "$home/state/.herdr-supervisor-claim-episode" "an episode existed before the monitor snapshot"
    else
      rm "$home/state/.supervision-claim.lock"
      start_contended_owner
      (claim_probe "$home" "$ROOT/bin/fm-herdr-supervisor.sh" ensure) \
        > "$home/initial-recovery.out" 2>&1 || fail "the initial episode did not recover"
      kill "$owner_pid"
      wait "$owner_pid" || fail "the initial recovery owner did not release its claim"
      owner_pid=
      printf "unreadable claim\n" > "$home/state/.supervision-claim.lock"
    fi
  fi
  claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    fm_wake_append() {
      touch "$STATE/writer-paused"
      deadline=$(( $(date +%s) + 45 ))
      while [ ! -e "$STATE/writer-resume" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 0.05
      done
      bash -c '\''. "$FM_SUP_SCRIPT" "" >/dev/null 2>&1 || true; fm_wake_append "$@"'\'' _ "$@"
    }
    cmd_ensure "concurrent alarm writer"
  ' > "$home/writer.out" 2>&1 &
  writer_pid=$!
  wait_for 20 test -e "$home/state/writer-paused" || fail "the alarm writer did not pause before queue publication"
  assert_absent "$home/state/.herdr-supervisor-claim-alarm" "the writer suppressed delivery before publication"
  rm "$home/state/.supervision-claim.lock"
  start_contended_owner
  if [ "$mode" = observation-blocked ]; then
    printf "unreadable observation lock\n" > "$home/state/.herdr-supervisor-claim-observation.lock"
    (claim_probe "$home" "$ROOT/bin/fm-herdr-supervisor.sh" ensure) \
      > "$home/blocked-observation.out" 2>&1 && fail "ensure completed an unserialized owner observation"
    assert_absent "$home/state/.wake-queue" "an incomplete observation raised a false alarm"
    (claim_probe "$home" "$ROOT/bin/fm-herdr-supervisor.sh" status) \
      > "$home/blocked-status.out" 2>&1 || fail "read-only status failed during observation contention"
    assert_grep 'other-owner: yes' "$home/blocked-status.out" "observation contention hid the live owner from status"
    rm "$home/state/.herdr-supervisor-claim-observation.lock"
  fi
  if [ "$mode" = ensure-exit ] || [ "$mode" = ensure-substitution ]; then
    if [ "$mode" = ensure-exit ]; then
      (claim_probe "$home" "$ROOT/bin/fm-herdr-supervisor.sh" ensure) \
        > "$home/recovery.out" 2>&1 && fail "ensure claimed completed recovery while publication was locked"
    else
      (claim_probe "$home" -c '
        result=$("$FM_SUP_SCRIPT" ensure 2>&1)
        rc=$?
        printf "%s\n" "$result"
        exit "$rc"
      ') > "$home/recovery.out" 2>&1 && fail "subprocess ensure claimed completed recovery while publication was locked"
    fi
    kill "$owner_pid"
    wait "$owner_pid" || fail "the ensure recovery owner did not release its claim"
    owner_pid=
    printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
    touch "$home/state/writer-resume"
    wait "$writer_pid" && fail "the unresolved writer claim reported success"
    writer_pid=
    (claim_probe "$home" "$ROOT/bin/fm-herdr-supervisor.sh" ensure) \
      > "$home/later-failure.out" 2>&1 && fail "the later unresolved claim reported success"
    count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
    [ "$count" = 2 ] || fail "exited ensure lost recovery ($count alarms)"
    pass "$mode preserves the recovered episode after process exit"
    exit 0
  fi
  if { [ "$mode" = identity-arrival ] || [ "$mode" = identity-replaced ]; }; then
    touch "$home/state/snapshot-resume"
  else
    start_contended_monitor
  fi
  # shellcheck disable=SC2329 # Invoked indirectly by wait_for below.
  monitor_observed() { [ -e "$home/state/monitor-paused-1" ] || [ -e "$home/state/monitor-finished" ]; }
  wait_for 20 monitor_observed || fail "the monitor did not observe the contended recovery"
  if [ "$mode" != identity-arrival ] && [ "$mode" != identity-replaced ]; then
    assert_absent "$home/state/monitor-finished" "monitor completed handoff before recovery bookkeeping persisted"
    kill -0 "$monitor_pid" || fail "the monitor exited while recovery bookkeeping was pending"
  fi
  (claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    cmd_status 0
  ') > "$home/status.out" 2>&1 || fail "status failed during recovery contention"
  assert_grep 'other-owner: yes' "$home/status.out" "contention hid the healthy owner"
  assert_absent "$home/state/.herdr-supervisor-claim-alarm" "status mutated the pending alarm"
  if [ "$mode" = identity-replaced ]; then
    count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
    [ "$count" = 1 ] || fail "status or the paused writer changed the earlier queue evidence"
  else
    assert_absent "$home/state/.wake-queue" "status queued an alarm during recovery contention"
  fi
  if [ "$mode" = disappears ]; then
    kill "$owner_pid"
    wait "$owner_pid" || fail "the recovered owner did not release its claim"
    owner_pid=
    printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
  fi
  touch "$home/state/writer-resume"
  wait "$writer_pid" && fail "the unresolved writer claim reported success"
  writer_pid=
  assert_grep unresolved "$home/state/.herdr-supervisor-claim-alarm" "the writer did not finish its delayed publication"
  if [ "$mode" = stale-retry ]; then
    (claim_probe "$home" "$ROOT/bin/fm-herdr-supervisor.sh" ensure) \
      > "$home/other-recovery.out" 2>&1 || fail "another ensure did not finish the old recovery"
    assert_grep 'deferred - another continuity owner' "$home/other-recovery.out" \
      "the intervening ensure did not recognize the recovered owner"
    kill "$owner_pid"
    wait "$owner_pid" || fail "the intervening recovery owner did not release its claim"
    owner_pid=
    printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
    (claim_probe "$home" "$ROOT/bin/fm-herdr-supervisor.sh" ensure) \
      > "$home/new-episode.out" 2>&1 && fail "the newer unresolved claim reported success"
    count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
    [ "$count" = 2 ] || fail "the newer episode did not publish its alarm"
    cp "$home/state/.herdr-supervisor-claim-alarm" "$home/newer-suppression"
  fi
  touch "$home/state/monitor-resume-1"
  if [ "$mode" = disappears ] || [ "$mode" = stale-retry ]; then
    wait_for 20 test -e "$home/state/monitor-paused-2" || fail "the monitor lost recovery after the owner disappeared"
    if [ "$mode" = stale-retry ]; then
      count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
      [ "$count" = 2 ] || fail "stale recovery erased the newer episode ($count alarms)"
      cmp -s "$home/newer-suppression" "$home/state/.herdr-supervisor-claim-alarm" \
        || fail "the old retry changed the newer suppression identity"
    fi
    rm "$home/state/.lock"
    touch "$home/state/monitor-resume-2"
  else
    wait_for 20 test -e "$home/state/monitor-finished" || fail "the monitor did not finish recovery before handoff"
    assert_absent "$home/state/.herdr-supervisor-claim-alarm" "handoff retained stale suppression"
    kill "$owner_pid"
    wait "$owner_pid" || fail "the recovered owner did not release its claim"
    owner_pid=
    printf 'unreadable claim\n' > "$home/state/.supervision-claim.lock"
    (claim_probe "$home" -c '
      set --
      . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
      cmd_ensure "failure after contended recovery"
    ') > "$home/ensure.out" 2>&1 && fail "the later unresolved claim reported success"
  fi
  wait "$monitor_pid" || fail "the monitor did not stop cleanly after recovery"
  monitor_pid=
  count=$(grep -c 'herdr-supervisor' "$home/state/.wake-queue")
  [ "$count" = "$expected_count" ] || fail "contended recovery suppressed the later failure ($count alarms)"
  pass "contended recovery retries when the recovered owner $mode"
)

claim_alarm_owner_cleanup() {
  [ -n "${LIVE_OWNER_PID:-}" ] || return 0
  kill "$LIVE_OWNER_PID" 2>/dev/null || true
  wait "$LIVE_OWNER_PID" 2>/dev/null || true
  LIVE_OWNER_PID=
}

claim_alarm_owner_tests() {
# =============================================================================
# 2026-09-06 audit finding 3: cmd_ensure escalated the instant its claim-acquire
# attempt failed, with no check for whether a healthy other owner already held
# it. A live, identity-verified holder read as a false "claim could not be
# acquired" alarm; seven of those over 18 hours were seven false alarms about
# one healthy, unchanging state. This drives the REAL cmd_ensure directly
# (sourced with the same technique as the alarm-priority case above) against a
# REAL claim lock acquired by a real background process, so the
# held-by-other/live/unknown distinction is proved by the genuine
# fm_supervision_claim_* code, never a hand-built lock fixture.
#
# A genuinely DEAD or identity-mismatched holder is deliberately NOT exercised
# as an escalation case here: fm_lock_try_acquire already treats both as
# reclaimable (a dead pid is stolen with no time-based grace; a live pid whose
# identity no longer matches its record is stolen too, since a mismatch is
# read as "possibly reused, not provably still the recorded owner" rather than
# "still definitely held") - correct, pre-existing, and outside this fix. What
# actually remains unresolvable - and is what genuinely reaches cmd_ensure's
# escalate-or-defer decision - is a claim record fm_lock_try_acquire cannot
# interpret as a live pid at all (garbage instead of the real owner-dir
# protocol): not stealable, and not a live pid fm_supervision_claim_held_by_other
# can call held-by-other, so it is exactly the audit's "unknown owner" case.
# =============================================================================

# --- 3a. a live, identity-verified other owner defers, with no alarm ---------
# The background holder sources fm-herdr-supervisor.sh itself (the same
# technique the alarm-priority case above uses), not fm-wake-lib.sh directly:
# the lock/identity helpers assume the PATH and SCRIPT_DIR context their own
# entry script establishes, so acquiring through that same fully-booted
# context is what makes the fabricated lock byte-identical to a real one.
HOMEB=$(new_home claim-alarm-live-owner)
HOME="$HOMEB" PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$HOMEB/fakestate" \
FM_HOME="$HOMEB" FM_STATE_OVERRIDE="$HOMEB/state" FM_CONFIG_OVERRIDE="$HOMEB/config" \
FM_SUP_SCRIPT="$ROOT/bin/fm-herdr-supervisor.sh" bash -c '
set -u
set --
. "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
fm_supervision_claim_acquire "$SUPERVISION_CLAIM" 20 || exit 1
touch "$FM_HOME/state/other-owner-ready"
# A plain trailing "sleep 20" here is a tail call bash can exec-replace this
# process image with, which changes the /proc or ps identity fm_pid_identity
# reads mid-test even though the pid never changes - a genuine holder must
# keep the SAME visible command running, so loop a builtin sleep instead.
while :; do sleep 1; done
' &
LIVE_OWNER_PID=$!
trap 'claim_alarm_owner_cleanup; fm_test_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
i=0
while [ ! -e "$HOMEB/state/other-owner-ready" ] && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -e "$HOMEB/state/other-owner-ready" ] || fail "the background claim holder never signaled ready"

ENSURE_OUT_LIVE="$HOMEB/ensure-live-owner.out"
HOME="$HOMEB" PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$HOMEB/fakestate" \
FM_HOME="$HOMEB" FM_STATE_OVERRIDE="$HOMEB/state" FM_CONFIG_OVERRIDE="$HOMEB/config" \
FM_SUPERVISION_MODEL=extension FM_HERDR_SUPERVISOR_LOCK_TRIES=2 \
FM_SUP_SCRIPT="$ROOT/bin/fm-herdr-supervisor.sh" bash -c '
set -u
set --
. "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
cmd_ensure "test probe"
printf "rc=%s\n" "$?"
' > "$ENSURE_OUT_LIVE" 2>&1

claim_alarm_owner_cleanup

assert_grep 'rc=0' "$ENSURE_OUT_LIVE" \
  "cmd_ensure did not return success while deferring to a live other owner"
assert_grep 'deferred - another continuity owner is completing its ownership claim' "$ENSURE_OUT_LIVE" \
  "a live, identity-verified other owner is deferred, not alarmed"
assert_absent "$HOMEB/state/.herdr-supervisor-alarm" \
  "a healthy live claim holder must not raise an alarm"
assert_absent "$HOMEB/state/.wake-queue" \
  "a healthy live claim holder must not queue a wake"
cat "$ENSURE_OUT_LIVE"
pass "a live, identity-verified other owner defers cmd_ensure without a false alarm"

# --- 3b. an unknown (unstealable, unprovable) claim record alarms, and the
#         same unresolved episode does not alarm twice ----------------------
# A plain file at the claim path - not the real owner-dir-plus-symlink
# protocol fm_lock_try_create writes - has no readable pid at all. It is not
# fresh-enough-to-ignore forever (fm_lock_mid_acquire_is_fresh's grace window
# is for a record with NO pid; this one is durably unreadable), so acquire
# keeps failing every poll, and fm_supervision_claim_held_by_other correctly
# finds no live, identity-verified pid to defer to either: a genuine unknown
# owner, exactly the audit's "distinguish from dead/stale/unknown" case.
HOMEC=$(new_home claim-alarm-unknown-record)
printf 'not the real owner-dir protocol\n' > "$HOMEC/state/.supervision-claim.lock"

ENSURE_OUT_UNKNOWN="$HOMEC/ensure-unknown-record.out"
HOME="$HOMEC" PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$HOMEC/fakestate" \
FM_HOME="$HOMEC" FM_STATE_OVERRIDE="$HOMEC/state" FM_CONFIG_OVERRIDE="$HOMEC/config" \
FM_SUPERVISION_MODEL=extension FM_HERDR_SUPERVISOR_LOCK_TRIES=2 \
FM_SUP_SCRIPT="$ROOT/bin/fm-herdr-supervisor.sh" bash -c '
set -u
set --
. "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
cmd_ensure "test probe"
printf "rc1=%s\n" "$?"
cmd_ensure "test probe"
printf "rc2=%s\n" "$?"
' > "$ENSURE_OUT_UNKNOWN" 2>&1

assert_grep 'rc1=1' "$ENSURE_OUT_UNKNOWN" \
  "an unresolvable (unknown) claim record must fail, not defer"
assert_grep 'the continuity ownership claim could not be acquired within its bounded retry window' \
  "$HOMEC/state/.wake-queue" \
  "an unknown owner still raises the real acquisition-failure reason in the durable queue"
assert_grep 'rc2=1' "$ENSURE_OUT_UNKNOWN" \
  "the same unresolved episode continues to fail on a second poll"
WAKE_COUNT=$(grep -c 'herdr-supervisor' "$HOMEC/state/.wake-queue" 2>/dev/null || true)
[ "${WAKE_COUNT:-0}" -eq 1 ] || fail \
  "an unresolved claim episode alarmed ${WAKE_COUNT:-0} times across two polls, expected exactly 1"
cat "$ENSURE_OUT_UNKNOWN" "$HOMEC/state/.wake-queue"
pass "an unknown claim record alarms once, and the same unresolved episode does not alarm twice"

# --- 3c. after the episode resolves, a later genuinely new failure alarms
#         again (recovery clears the dedupe key) -----------------------------
HOME="$HOMEC" PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$HOMEC/fakestate" \
FM_HOME="$HOMEC" FM_STATE_OVERRIDE="$HOMEC/state" FM_CONFIG_OVERRIDE="$HOMEC/config" \
FM_SUPERVISION_MODEL=extension FM_HERDR_SUPERVISOR_LOCK_TRIES=2 \
FM_SUP_SCRIPT="$ROOT/bin/fm-herdr-supervisor.sh" bash -c '
set -u
set --
. "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
rm "$SUPERVISION_CLAIM"
cmd_ensure "recovery probe" || exit 1
printf "not the real owner-dir protocol\n" > "$SUPERVISION_CLAIM"
cmd_ensure "test probe"
printf "rc3=%s\n" "$?"
' > "$HOMEC/ensure-reappear.out" 2>&1

WAKE_COUNT2=$(grep -c 'herdr-supervisor' "$HOMEC/state/.wake-queue" 2>/dev/null || true)
assert_grep 'rc3=1' "$HOMEC/ensure-reappear.out" \
  "the reappearance probe did not observe the same still-unresolved failure"
[ "${WAKE_COUNT2:-0}" -eq 2 ] || fail \
  "clearing the dedupe key did not let a new failure episode alarm again (count=${WAKE_COUNT2:-0})"
cat "$HOMEC/ensure-reappear.out" "$HOMEC/state/.wake-queue"
pass "successful claim acquisition lets a later failure episode alarm again"

}

# The competing owner arrives after the loop's first ownership check but
# before its acquisition attempt, exercising the second check at the arm path.
# shellcheck disable=SC2016 # Probe scripts expand variables in the child bash.
claim_alarm_loop_arrival_test() (
  home=$(new_home claim-alarm-loop-arrival)
  loop_pid='' owner_pid=''
  trap 'for pid in "$loop_pid" "$owner_pid"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done; wait' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'generation=fixture\nmode=active\n' > "$home/state/.herdr-supervisor"
  touch "$home/state/task.meta"
  claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    LOOP_GENERATION=fixture
    IDLE_INTERVAL=123
    loop_launch_wait() { return 0; }
    eval "$(declare -f fm_supervision_claim_acquire | sed "1s/fm_supervision_claim_acquire/original_claim_acquire/")"
    fm_supervision_claim_acquire() {
      touch "$STATE/before-acquire"
      deadline=$(( $(date +%s) + 30 ))
      while [ ! -e "$STATE/owner-ready" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || exit 1
        command sleep 0.05
      done
      original_claim_acquire "$@"
    }
    sleep() {
      if [ "$1" = 123 ]; then touch "$STATE/idle-reached"; return 0; fi
      command sleep "$@"
    }
    cmd_run
  ' > "$home/loop.out" 2>&1 &
  loop_pid=$!
  wait_for 10 test -e "$home/state/before-acquire" || fail "the loop did not reach claim acquisition"
  claim_probe "$home" -c '
    set --
    . "$FM_SUP_SCRIPT" >/dev/null 2>&1 || true
    fm_supervision_claim_acquire "$SUPERVISION_CLAIM" 20 || exit 1
    trap "fm_lock_release \"\$SUPERVISION_CLAIM\"" EXIT
    trap "exit 0" TERM INT
    touch "$STATE/owner-ready"
    while :; do sleep 0.05; done
  ' > "$home/owner.out" 2>&1 &
  owner_pid=$!
  # loop_sleep backgrounds the interval sleep so a real TERM lands at once
  # (see bin/fm-herdr-supervisor.sh), so the mocked sleep above cannot exit
  # the whole probe from that background job; it marks arrival instead and
  # this driver ends the loop explicitly once it observes that mark.
  wait_for 10 test -e "$home/state/idle-reached" \
    || fail "the loop did not reach an idle sleep after owner arrival: $(cat "$home/loop.out")"
  kill "$loop_pid"
  wait "$loop_pid" 2>/dev/null
  loop_pid=
  assert_absent "$home/state/.wake-queue" "a live owner arriving before arming raised a false alarm"
  assert_absent "$home/state/.herdr-supervisor-alarm" "a live owner arriving before arming raised an emergency"
  printf 'loop owner-arrival: wake queue absent; emergency alarm absent\n'
  kill "$owner_pid"
  wait "$owner_pid" || fail "the arriving owner did not release its claim"
  owner_pid=
  pass "the arm path rechecks a live owner arriving during claim acquisition"
)

server_restart_test() (
  HOME10=$(new_home server-restart)
  trap 'stop_loop "$HOME10"' EXIT
  cat > "$HOME10/arm.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/arm-entered"
exec sleep 300
SH
  chmod +x "$HOME10/arm.sh"
  fm_write_meta "$HOME10/state/socket-task.meta" "window=firstmate:fm-socket-task"
  run_supervisor "$HOME10" "$FAKEBIN" ensure >/dev/null 2>&1 || fail "establish failed for the socket case"
  wait_for 10 test -e "$HOME10/arm-entered" || fail "the old loop never armed"
  # The loop stays alive on purpose: this must prove the SERVER identity check
  # fails on its own, not that a dead process was noticed first.
  printf '%s\n' "$HOME10/fakestate/restarted.sock" > "$HOME10/fakestate/socket"
  out=$(run_supervisor "$HOME10" "$FAKEBIN" status 2>&1)
  assert_contains "$out" "supervisor: unhealthy" "a replaced Herdr server is unhealthy"
  assert_contains "$out" "socket changed" "the unhealthy reason names the lost server"
  pass "a Herdr server restart is detected as a lost supervisor, not as healthy"
  # A real server restart also ends its pane processes. Keep the old loop alive
  # only for the read-only identity assertion above, then model that lifecycle
  # before asking ensure to replace it. Otherwise its valid claim correctly
  # defers replacement, depending on when its arm cycle releases the claim.
  stop_loop "$HOME10"
  wait_for 10 test ! -e "$HOME10/state/.supervision-claim.lock" \
    || fail "the restarted server's old loop did not release its claim"
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
)

stopped_server_test() (
  HOME13C=$(new_home no-server)
  trap 'stop_loop "$HOME13C"' EXIT
  make_arm_stub "$HOME13C/arm.sh" ok
  fm_write_meta "$HOME13C/state/noserver-task.meta" "window=firstmate:fm-noserver-task"
  : > "$HOME13C/fakestate/server-stopped"
  out=$(run_supervisor "$HOME13C" "$FAKEBIN" ensure 2>&1) && fail "a stopped Herdr server reported success: $out"
  assert_contains "$out" "no running server" "the refusal names the missing Herdr server"
  assert_absent "$HOME13C/state/.herdr-supervisor" "a stopped server leaves no supervisor record"
  assert_present "$HOME13C/state/.herdr-supervisor-alarm" "a stopped server leaves a durable alarm"
  assert_no_grep "server" "$HOME13C/fakestate/calls.log" "the supervisor must never invoke a Herdr server command"
  pass "a Herdr session with no running server is refused loudly and starts no server"
  rm "$HOME13C/fakestate/server-stopped"
  : > "$HOME13C/fakestate/server-incompatible"
  out=$(run_supervisor "$HOME13C" "$FAKEBIN" ensure 2>&1) \
    && fail "an incompatible Herdr server reported success: $out"
  assert_contains "$out" "incompatible or unreadable server capabilities" \
    "the refusal preserves the native capability check"
  assert_absent "$HOME13C/state/.herdr-supervisor" "an incompatible server leaves no supervisor record"
  assert_no_grep "server" "$HOME13C/fakestate/calls.log" "an incompatible server grants no lifecycle authority"
  pass "an incompatible Herdr server is refused without establishing continuity"
)


CURRENT_ROOT=/Users/criz/.no-mistakes/worktrees/da589fef49ee/01M2KC5KRP89F2TMQNEXSZEMN5
BASELINE_ROOT=/Users/criz/.no-mistakes/worktrees/da589fef49ee/01M2KC5KRP89F2TMQNEXSZEMN5/.test-phase-tmp/pre-fix

FAKEBIN=$(make_fake_herdr "$TMP_ROOT/client")
for variant in before after; do
  ROOT=$CURRENT_ROOT
  [ "$variant" != before ] || ROOT=$BASELINE_ROOT
  home=$(new_home "evidence-$variant")
  make_arm_stub "$home/arm.sh" ok
  fm_write_meta "$home/state/stopped-task.meta" "kind=ship"
  : > "$home/fakestate/server-stopped"
  out=$(run_supervisor "$home" "$FAKEBIN" ensure 2>&1)
  status=$?
  printf '\n[%s fix] fm-herdr-supervisor.sh ensure (stopped server)\nexit=%s\n%s\n' "$variant" "$status" "$out"
  [ "$status" -ne 0 ] || fail 'stopped server accepted'
  if [ "$variant" = after ]; then
    assert_contains "$out" 'no running server' 'attributed stopped-server diagnosis'
    printf 'Persisted alarm:\n'; cat "$home/state/.herdr-supervisor-alarm"
  else
    assert_contains "$out" 'capability check failed' 'baseline must reproduce generic load failure'
  fi
  assert_absent "$home/state/.herdr-supervisor" 'must not revive workers'
  printf 'Supervisor record: absent; arm invocations: %s\n' "$(cat "$home/arm.count" 2>/dev/null || echo 0)"
  out=$(HOME="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_HERDR_STATE="$home/fakestate" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh" 2>&1)
  status=$?
  printf '\n[%s fix] fm-herdr-session-cleanup.sh (no candidate)\nexit=%s\n%s\n' "$variant" "$status" "${out:-<no output>}"
  [ "$status" -eq 0 ] || fail 'cleanup failed'
  if [ "$variant" = after ]; then
    [ -z "$out" ] || fail 'cleanup probes without candidates'
  else
    assert_contains "$out" 'capability check failed' 'baseline must reproduce premature probe'
  fi
done
