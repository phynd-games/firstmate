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
# The arm is a scripted stub, never the real bin/fm-watch-arm.sh: this proves
# the HOSTING and CONTINUITY contract, and driving a real watcher would mutate
# a real home's supervision state.
#
# STATUS: NOT YET VERIFIED. This is committed as the intended live contract, but
# it has not completed a green run, and it is gated OFF by default for two
# reasons.
#
# 1. It needs a Herdr-lab brief. Running it starts a real Herdr server, creates
#    workspaces and panes, and stops and deletes a session. That is exactly the
#    lifecycle class `bin/fm-brief.sh --herdr-lab` exists to authorize, and the
#    brief this file was written under did not carry that guard.
# 2. It has an unresolved hang. On herdr 0.8.2 the first `ensure` blocks with no
#    output. Read-only session-scoped calls return promptly, so the block is in
#    the shared server-start path (`fm_backend_herdr_server_ensure`, which
#    backgrounds `herdr server` for a not-yet-running named session) when that
#    call sits inside a caller's command substitution. That is pre-existing
#    shared-adapter behavior, not something this task changed, and diagnosing it
#    means driving more real Herdr lifecycle.
#
# Set FM_HERDR_SUPERVISOR_SMOKE=1 to run it, and only from a brief that
# authorizes Herdr lifecycle work. Its family is `real-herdr-gated`, so it is
# already excluded from every portable CI lane.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

[ "${FM_HERDR_SUPERVISOR_SMOKE:-0}" = 1 ] || {
  echo "skip: set FM_HERDR_SUPERVISOR_SMOKE=1 to run this real-Herdr smoke (see the header: it needs a --herdr-lab brief and has an unresolved server-start hang)"
  exit 0
}
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# The supervisor resolves its own Herdr session, so a pane identity inherited
# from the terminal that launched this suite must not follow it into the lab.
herdr_forget_inherited_pane

SESSION="fm-lab-supervisor-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  if [ -n "$SCRATCH" ] && [ -f "$SCRATCH/home/state/.herdr-supervisor" ]; then
    run_supervisor retire --reason "smoke cleanup" >/dev/null 2>&1 || true
  fi
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-supervisor-smoke.XXXXXX") || exit 1
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'herdr\n' > "$HOME_DIR/config/backend"
# One in-flight task so supervision is genuinely needed.
printf 'window=%s:fm-smoke\n' "$SESSION" > "$HOME_DIR/state/smoke.meta"

# A scripted arm that counts invocations and returns one actionable reason,
# exactly like a real watcher cycle closing on a wake.
cat > "$SCRATCH/arm.sh" <<'ARM'
#!/usr/bin/env bash
set -u
C="${FM_TEST_ARM_COUNT:?}"
printf '%s\n' "$(( $(cat "$C" 2>/dev/null || echo 0) + 1 ))" > "$C"
echo "signal: smoke"
exit 0
ARM
chmod +x "$SCRATCH/arm.sh"

run_supervisor() {
  FM_HOME="$HOME_DIR" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_WATCH_ARM_SCRIPT="$SCRATCH/arm.sh" \
  FM_TEST_ARM_COUNT="$SCRATCH/arm.count" \
  FM_SUPERVISION_MODEL=extension \
  FM_HERDR_SUPERVISOR_IDLE_INTERVAL=2 \
  FM_HERDR_SUPERVISOR_RETRY_BASE=1 \
  HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-herdr-supervisor.sh" "$@"
}

record_field() { grep -m1 "^$1=" "$HOME_DIR/state/.herdr-supervisor" 2>/dev/null | sed "s/^$1=//"; }
live_field() { grep -m1 "^$1=" "$HOME_DIR/state/.herdr-supervisor-live" 2>/dev/null | sed "s/^$1=//"; }
arm_count() { cat "$SCRATCH/arm.count" 2>/dev/null || echo 0; }

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
TRACKED=$(herdr pane process-info --pane "$PANE" --session "$SESSION" 2>/dev/null \
  | jq -r '.result.process_info.shell_pid // empty')
[ "$TRACKED" = "$LOOP_PID" ] \
  || fail "Herdr tracks pid '$TRACKED' in $PANE but the supervisor published $LOOP_PID"
kill -0 "$LOOP_PID" 2>/dev/null || fail "the published supervisor pid is not alive"
pass "Herdr's own process tracking names the live supervisor in its pane"

# --- 3. continuity: one establish keeps re-arming -----------------------------
# The incident's signature was one cycle per hand-start with successor=none.
wait_until 40 test "$(arm_count)" -ge 3 \
  || fail "one establish produced only $(arm_count) arm cycles in a real pane; continuity is not restored"
pass "one establish keeps re-arming the watcher inside its Herdr pane"

# --- 4. no duplicate supervisor ----------------------------------------------
out=$(run_supervisor ensure --reason "second call" 2>&1)
case "$out" in
  *'herdr-supervisor: unchanged'*) ;;
  *) fail "a repeat ensure was not a no-op: $out" ;;
esac
[ "$(record_field generation)" = "$GEN" ] || fail "a repeat ensure minted a new generation"
SUPERVISOR_PANES=$(herdr pane list --workspace "$WS" --session "$SESSION" 2>/dev/null \
  | jq -r '[.result.panes[]?] | length')
[ "$SUPERVISOR_PANES" = 1 ] \
  || fail "the supervisor workspace holds $SUPERVISOR_PANES panes; exactly one host is allowed"
pass "a repeated ensure adds no second supervisor pane and no second owner"

# --- 5. a killed supervisor is detected and re-established --------------------
kill -KILL "$LOOP_PID" 2>/dev/null || fail "could not kill the supervisor for the recovery case"
wait_until 20 sh -c "! kill -0 $LOOP_PID 2>/dev/null" \
  || fail "the supervisor did not die"
out=$(run_supervisor status 2>&1)
case "$out" in
  *'supervisor: unhealthy'*) ;;
  *) fail "a killed supervisor still reported healthy: $out" ;;
esac
BEFORE=$(arm_count)
out=$(run_supervisor ensure --reason "after kill" 2>&1) \
  || fail "re-establish after a kill failed: $out"
case "$out" in
  *'herdr-supervisor: started'*) ;;
  *) fail "re-establish did not start a replacement: $out" ;;
esac
[ "$(record_field generation)" != "$GEN" ] || fail "re-establish reused the dead generation"
wait_until 40 test "$(arm_count)" -gt "$((BEFORE + 1))" \
  || fail "the replacement supervisor never resumed arming"
pass "a killed supervisor is detected as unhealthy and a new generation takes over"

# --- 6. retire releases exactly its own workspace -----------------------------
RETIRE_WS=$(record_field workspace)
out=$(run_supervisor retire --reason "smoke" 2>&1) || fail "retire failed: $out"
[ ! -e "$HOME_DIR/state/.herdr-supervisor" ] || fail "retire left the ownership record behind"
wait_until 20 sh -c \
  "! herdr workspace list --session '$SESSION' 2>/dev/null | jq -e --arg w '$RETIRE_WS' '[.result.workspaces[]? | select(.workspace_id == \$w)] | length == 1' >/dev/null" \
  || fail "retire left its workspace $RETIRE_WS behind"
pass "retire releases the record and its own Herdr workspace"

echo "all fm-herdr-supervisor smoke checks passed"
