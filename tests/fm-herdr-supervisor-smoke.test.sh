#!/usr/bin/env bash
# tests/fm-herdr-supervisor-smoke.test.sh - real-Herdr smoke for the
# Herdr-hosted watcher continuity owner (bin/fm-herdr-supervisor.sh).
#
# Every other case for this script fakes the CLI. This one talks to a REAL
# herdr server, because the whole claim - "a Herdr-tracked pane keeps the
# watcher armed" - rests on behavior no fake can vouch for: that `pane run`
# really hosts a long-lived process, that `pane process-info` really reports
# it, and that the pane really outlives the command that created it.
#
# Safety (2026-07-02 incident, tests/herdr-test-safety.sh): this ALWAYS runs on
# a private, named, throwaway HERDR_SESSION, never the default one, and cleans
# up only through herdr_safe_stop_and_delete. It never touches a captain's real
# Herdr usage, and it skips cleanly where herdr or jq is absent.
#
# The supervisor runs the real bin/fm-watch-arm.sh and bin/fm-watch.sh here, so
# the smoke proves the singleton lock and watcher lifecycle as well as hosting.
#
# The lab contract owns every lifecycle action here: a named non-default
# fm-lab-* session, provisioned and torn down only through bin/fm-herdr-lab.sh,
# with its fleet-state tripwire proving the captain's default session never
# changed.
#
# It PROVISIONS the lab server through fm_herdr_lab_provision before the
# supervisor runs. That is deliberate and it is also what the supervisor
# requires: bin/fm-herdr-supervisor.sh never starts a Herdr server, because
# `ensure` is invoked inside a command substitution on the session-start path
# and backgrounding a long-lived server from there wedges the caller. An earlier
# version of this suite only called fm_herdr_lab_prepare, left the supervisor to
# start its own server, and hung for exactly that reason.
#
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A live failure is worth its evidence: this is the only suite that can show
# what the real pane actually did, and reconstructing it by hand costs a full
# provision cycle.
dump_diagnostics() {
  [ -n "${SCRATCH:-}" ] || return 0
  printf -- '--- binding record ---\n' >&2
  cat "$SCRATCH/home/state/.herdr-supervisor" 2>&1 >&2 || true
  printf -- '--- live record ---\n' >&2
  cat "$SCRATCH/home/state/.herdr-supervisor-live" 2>&1 >&2 || printf '(absent)\n' >&2
  printf -- '--- ledger ---\n' >&2
  tr '\t' ' ' < "$SCRATCH/home/state/.herdr-supervisor.log" >&2 2>/dev/null || true
  printf -- '--- alarm ---\n' >&2
  cat "$SCRATCH/home/state/.herdr-supervisor-alarm" 2>&1 >&2 || printf '(none)\n' >&2
  printf -- '--- supervisor pane ---\n' >&2
  local ws pane
  ws=$(fm_herdr_lab_cli "$SESSION" workspace list 2>/dev/null \
    | jq -r '.result.workspaces[]? | select(.label|test("supervisor")) | .workspace_id' | head -1)
  if [ -n "$ws" ]; then
    pane=$(fm_herdr_lab_cli "$SESSION" pane list --workspace "$ws" 2>/dev/null \
      | jq -r '.result.panes[]?.pane_id' | head -1)
    [ -z "$pane" ] || fm_herdr_lab_cli "$SESSION" pane read "$pane" >&2 2>&1 || true
  else
    printf '(no supervisor workspace)\n' >&2
  fi
}

fail() { printf 'not ok - %s\n' "$1" >&2; dump_diagnostics; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# The supervisor resolves its own Herdr session, so a pane identity inherited
# from the terminal that launched this suite must not follow it into the lab.
herdr_forget_inherited_pane

SESSION=$(fm_herdr_lab_name supsmoke)
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  local loop_pid
  if [ -n "${DUP_PID:-}" ]; then
    kill -TERM "$DUP_PID" 2>/dev/null || true
    wait "$DUP_PID" 2>/dev/null || true
  fi
  if [ -n "$SCRATCH" ] && [ -f "$SCRATCH/home/state/.herdr-supervisor" ]; then
    run_supervisor retire --reason "smoke cleanup" >/dev/null 2>&1 || true
  fi
  # Retire clears the record, which the loop notices on its next pass, but it
  # may still be mid-cycle; wait it out before deleting the tree it writes into.
  if [ -n "$SCRATCH" ] && [ -f "$SCRATCH/home/state/.herdr-supervisor-live" ]; then
    loop_pid=$(grep -m1 '^loop_pid=' "$SCRATCH/home/state/.herdr-supervisor-live" 2>/dev/null | sed 's/^loop_pid=//')
    if [ -n "$loop_pid" ]; then
      kill -TERM "$loop_pid" 2>/dev/null || true
      wait_until 5 sh -c "! kill -0 $loop_pid 2>/dev/null" || true
    fi
  fi
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH" 2>/dev/null
  fm_herdr_lab_teardown "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT
fm_herdr_lab_provision "$SESSION" || fail "could not provision the isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-supervisor-smoke.XXXXXX") || exit 1
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'herdr\n' > "$HOME_DIR/config/backend"
# One in-flight task so supervision is genuinely needed.
printf 'window=%s:fm-smoke\n' "$SESSION" > "$HOME_DIR/state/smoke.meta"
printf 'done: smoke one\n' > "$HOME_DIR/state/smoke.status"

run_supervisor() {
  FM_HOME="$HOME_DIR" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SIGNAL_GRACE=0 \
  FM_POLL=1 \
  FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 \
  FM_WATCH_ARM_ATTACH_POLL=0.1 \
  FM_SUPERVISION_MODEL=extension \
  FM_HERDR_SUPERVISOR_IDLE_INTERVAL=2 \
  FM_HERDR_SUPERVISOR_RETRY_BASE=1 \
  HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-herdr-supervisor.sh" "$@"
}

record_field() { grep -m1 "^$1=" "$HOME_DIR/state/.herdr-supervisor" 2>/dev/null | sed "s/^$1=//"; }
live_field() { grep -m1 "^$1=" "$HOME_DIR/state/.herdr-supervisor-live" 2>/dev/null | sed "s/^$1=//"; }
cycle_count() { grep -c '^arm_pid=' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null || echo 0; }
cycle_count_at_least() { [ "$(cycle_count)" -ge "$1" ]; }

wait_until() {  # <seconds> <cmd...>
  local budget=$1 i=0
  shift
  while [ "$i" -lt $((budget * 5)) ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# --- 1. establish inside a real Herdr server ---------------------------------
out=$(run_supervisor ensure --reason smoke 2>&1) \
  || fail "establish failed against a real Herdr server: $out"
case "$out" in
  *'herdr-supervisor: started'*) ;;
  *) fail "establish did not report a started supervisor: $out" ;;
esac
GEN=$(record_field generation)
PANE=$(record_field pane)
WS=$(record_field workspace)
[ -n "$GEN" ] && [ -n "$PANE" ] && [ -n "$WS" ] || fail "establish recorded an incomplete binding"
pass "the supervisor establishes in a real Herdr session"

# --- 2. Herdr really tracks the supervisor process ---------------------------
LOOP_PID=$(live_field loop_pid)
[ -n "$LOOP_PID" ] || fail "no supervisor pid was published"
TRACKED=$(fm_herdr_lab_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null \
  | jq -r '.result.process_info.shell_pid // empty')
[ "$TRACKED" = "$LOOP_PID" ] \
  || fail "Herdr tracks pid '$TRACKED' in $PANE but the supervisor published $LOOP_PID"
kill -0 "$LOOP_PID" 2>/dev/null || fail "the published supervisor pid is not alive"
pass "Herdr's own process tracking names the live supervisor in its pane"

# --- 3. continuity: one establish keeps re-arming -----------------------------
# The incident's signature was one cycle per hand-start with successor=none.
wait_until 40 cycle_count_at_least 1 \
  || fail "the real watcher did not complete its first cycle in a real pane"
printf 'done: smoke two\n' > "$HOME_DIR/state/smoke.status"
wait_until 40 cycle_count_at_least 2 \
  || fail "one establish did not re-arm the real watcher after its first wake"
printf 'done: smoke three\n' > "$HOME_DIR/state/smoke.status"
wait_until 40 cycle_count_at_least 3 \
  || fail "one establish did not keep re-arming the real watcher"
pass "one establish keeps re-arming the real watcher inside its Herdr pane"

# --- 4. duplicate arm attaches to the existing real watcher ------------------
DUP_OUT="$SCRATCH/duplicate-arm.out"
FM_HOME="$HOME_DIR" \
FM_ROOT_OVERRIDE="$ROOT" \
FM_STATE_OVERRIDE="$HOME_DIR/state" \
FM_SIGNAL_GRACE=0 \
FM_POLL=1 \
FM_CHECK_INTERVAL=999999 \
FM_HEARTBEAT=999999 \
FM_WATCH_ARM_ATTACH_POLL=0.1 \
HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-watch-arm.sh" > "$DUP_OUT" 2>&1 &
DUP_PID=$!
wait_until 20 grep -q '^watcher: attached pid=' "$DUP_OUT" \
  || fail "a duplicate real arm did not attach to the existing watcher"
WATCH_LOCK_PID=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$WATCH_LOCK_PID" ] || fail "the real watcher lock did not name a live watcher"
kill -TERM "$DUP_PID" 2>/dev/null || true
wait "$DUP_PID" 2>/dev/null || true
DUP_PID=
pass "a duplicate real arm attaches without creating a second watcher"

# --- 5. no duplicate supervisor ----------------------------------------------
out=$(run_supervisor ensure --reason "second call" 2>&1)
case "$out" in
  *'herdr-supervisor: unchanged'*) ;;
  *) fail "a repeat ensure was not a no-op: $out" ;;
esac
[ "$(record_field generation)" = "$GEN" ] || fail "a repeat ensure minted a new generation"
SUPERVISOR_PANES=$(fm_herdr_lab_cli "$SESSION" pane list --workspace "$WS" 2>/dev/null \
  | jq -r '[.result.panes[]?] | length')
[ "$SUPERVISOR_PANES" = 1 ] \
  || fail "the supervisor workspace holds $SUPERVISOR_PANES panes; exactly one host is allowed"
pass "a repeated ensure adds no second supervisor pane and no second owner"

# --- 6. a killed supervisor is detected and re-established --------------------
kill -KILL "$LOOP_PID" 2>/dev/null || fail "could not kill the supervisor for the recovery case"
wait_until 20 sh -c "! kill -0 $LOOP_PID 2>/dev/null" \
  || fail "the supervisor did not die"
out=$(run_supervisor status 2>&1)
case "$out" in
  *'supervisor: unhealthy'*) ;;
  *) fail "a killed supervisor still reported healthy: $out" ;;
esac
BEFORE=$(cycle_count)
out=$(run_supervisor ensure --reason "after kill" 2>&1) \
  || fail "re-establish after a kill failed: $out"
case "$out" in
  *'herdr-supervisor: started'*) ;;
  *) fail "re-establish did not start a replacement: $out" ;;
esac
[ "$(record_field generation)" != "$GEN" ] || fail "re-establish reused the dead generation"
wait_until 40 cycle_count_at_least "$((BEFORE + 2))" \
  || fail "the replacement supervisor never resumed arming"
pass "a killed supervisor is detected as unhealthy and a new generation takes over"

# --- 6. retire releases exactly its own workspace -----------------------------
RETIRE_WS=$(record_field workspace)
out=$(run_supervisor retire --reason "smoke" 2>&1) || fail "retire failed: $out"
[ ! -e "$HOME_DIR/state/.herdr-supervisor" ] || fail "retire left the ownership record behind"
workspace_gone() {
  ! fm_herdr_lab_cli "$SESSION" workspace list 2>/dev/null \
    | jq -e --arg w "$RETIRE_WS" '[.result.workspaces[]? | select(.workspace_id == $w)] | length == 1' >/dev/null 2>&1
}
wait_until 20 workspace_gone || fail "retire left its workspace $RETIRE_WS behind"
pass "retire releases the record and its own Herdr workspace"

echo "all fm-herdr-supervisor smoke checks passed"
