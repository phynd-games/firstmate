#!/usr/bin/env bash
# tests/fm-launch-record-herdr-live-e2e.test.sh - the native Herdr facts the
# launch records rely on, checked against the INSTALLED Herdr in a named lab
# session provisioned and torn down only through bin/fm-herdr-lab.sh, with the
# live default session as a byte-identical tripwire.
#
# Opt in with FM_LAUNCH_RECORD_LIVE=1. What is proved, each with its control:
#   1. `workspace create` and `tab create` answer with exact workspace, tab, pane,
#      and terminal ids (what `created` binds).
#   2. `agent get` on a plain shell pane answers agent_not_found (the readiness
#      negative control: an acknowledged launch is not ready), and after
#      `pane report-agent` registers an agent it answers a live status (the
#      positive control) - the same registry `fm_backend_herdr_agent_state`
#      classifies, with no real agent launched.
#   3. `pane get` on the pane after `pane close` answers pane_not_found and the
#      presence classifier reads it dead (what `absent` reconciliation relies
#      on); closing the workspace's last pane leaves nothing behind.
#   4. The adapter's own classifier agrees on a present pane:
#      `fm_backend_herdr_agent_state` reads alive (reported agent) and dead
#      (no agent) on the exact recorded workspace/tab/pane. Its answer for a
#      closed pane is recorded as observed, not asserted, because its
#      target-ready gate needs a present pane.
#   5. `pane process-info` distinguishes an idle shell from a running foreground
#      command on the same agent-free pane (`fm_backend_herdr_pane_foreground_state`
#      reads idle, then busy while `sleep` runs, then idle again) - the proof
#      the launch owners need before treating agent_not_found as a husk.
# Every Herdr call goes through the lab helper's `run`; the helper appends the
# lab session, refuses default, and verifies the default session unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

if [ "${FM_LAUNCH_RECORD_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_LAUNCH_RECORD_LIVE=1 to run the live Herdr launch-record boundary check"
  exit 0
fi
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

herdr_forget_inherited_pane
unset HERDR_BIN_PATH

LAB="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB" name launch-record)
teardown() {
  "$LAB" teardown "$SESSION" || printf 'not ok - lab teardown or fleet-state tripwire failed for %s\n' "$SESSION" >&2
  fm_test_cleanup
}
trap teardown EXIT
"$LAB" provision "$SESSION" || fail "could not provision lab session $SESSION"

lab() { "$LAB" run "$SESSION" "$@"; }

TMP_ROOT=$(fm_test_tmproot fm-launch-record-live)
version=$(herdr --version 2>/dev/null | head -n 1)
printf 'herdr: %s\n' "$version"

# --- 1. exact ids from creation responses -----------------------------------------
ws_out=$(lab workspace create --cwd "$TMP_ROOT" --label "fm-lab-launch-record" --no-focus) || fail "workspace create failed"
ws=$(printf '%s' "$ws_out" | jq -r '.result.workspace.workspace_id // empty')
seed_tab=$(printf '%s' "$ws_out" | jq -r '.result.tab.tab_id // empty')
seed_pane=$(printf '%s' "$ws_out" | jq -r '.result.root_pane.pane_id // empty')
seed_term=$(printf '%s' "$ws_out" | jq -r '.result.root_pane.terminal_id // empty')
[ -n "$ws" ] && [ -n "$seed_tab" ] && [ -n "$seed_pane" ] && [ -n "$seed_term" ] || fail "workspace create must return workspace, tab, pane, and terminal ids: $ws_out"
tab_out=$(lab tab create --workspace "$ws" --cwd "$TMP_ROOT" --label "fm-launch-live" --no-focus) || fail "tab create failed"
tab=$(printf '%s' "$tab_out" | jq -r '.result.tab.tab_id // empty')
pane=$(printf '%s' "$tab_out" | jq -r '.result.root_pane.pane_id // empty')
term=$(printf '%s' "$tab_out" | jq -r '.result.root_pane.terminal_id // empty')
[ -n "$tab" ] && [ -n "$pane" ] && [ -n "$term" ] || fail "tab create must return tab, pane, and terminal ids: $tab_out"
[ "$(printf '%s' "$tab_out" | jq -r '.result.root_pane.workspace_id')" = "$ws" ] || fail "the created pane must name its workspace"
printf 'created: workspace=%s tab=%s pane=%s terminal=%s\n' "$ws" "$tab" "$pane" "$term"
pass "creation responses carry exact workspace, tab, pane, and terminal ids"

# --- 2. readiness negative and positive controls -------------------------------------
if out=$(lab agent get "$pane" 2>&1); then
  fail "agent get on a plain shell pane must not succeed: $out"
fi
printf '%s' "$out" | jq -e '.error.code == "agent_not_found"' >/dev/null 2>&1 || fail "a plain pane must read agent_not_found, got: $out"
pass "a pane with no agent reads agent_not_found (an acknowledged launch is not ready)"
lab pane report-agent "$pane" --source fm-launch-live --agent claude --state idle >/dev/null || fail "pane report-agent failed"
out=$(lab agent get "$pane") || fail "agent get after report-agent failed: $out"
[ "$(printf '%s' "$out" | jq -r '.result.agent.agent_status')" = idle ] || fail "a reported agent must read idle, got: $out"
[ "$(printf '%s' "$out" | jq -r '.result.agent.pane_id')" = "$pane" ] || fail "the agent must be bound to the exact pane"
pass "a reported agent reads a live status on the exact pane (readiness positive control)"

# --- 4. the adapter classifier on the exact recorded identity ------------------------
classify() {  # -> alive|dead|missing|unreadable
  HERDR_SESSION="$SESSION" FM_BACKEND_HERDR_EXPECTED_TARGET="$SESSION:$pane" \
    FM_BACKEND_HERDR_EXPECTED_WORKSPACE_ID="$ws" FM_BACKEND_HERDR_EXPECTED_TAB_ID="$tab" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state "$1"' "$ROOT" "$SESSION:$pane"
}
state=$(classify) || true
[ "$state" = alive ] || fail "the adapter must classify a reported agent as alive, got '$state'"
lab pane release-agent "$pane" --source fm-launch-live --agent claude >/dev/null || fail "pane release-agent failed"
state=$(classify) || true
[ "$state" = dead ] || fail "the adapter must classify an agent-free pane as dead, got '$state'"
pass "the adapter classifies the exact recorded pane alive with an agent and dead without one"

# --- 5. idle versus busy foreground on an agent-free pane ---------------------------
foreground() {  # -> idle|busy (rc 2 unreadable)
  HERDR_SESSION="$SESSION" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_foreground_state "$1" "$2" "$3" "$4"' "$ROOT" "$SESSION" "$pane" "$ws" "$tab"
}
state=$(foreground) || fail "process-info must be readable on a present pane (rc $?)"
[ "$state" = idle ] || fail "a plain shell pane must read idle, got '$state'"
lab pane run "$pane" "sleep 4" >/dev/null || fail "pane run failed"
busy_seen=0
for _ in $(seq 1 20); do
  state=$(foreground) || true
  if [ "$state" = busy ]; then busy_seen=1; break; fi
  sleep 0.1
done
[ "$busy_seen" = 1 ] || fail "a pane running a foreground command must read busy, last '$state'"
printf 'observed: foreground state while sleep runs -> %s\n' "$state"
idle_again=0
for _ in $(seq 1 80); do
  state=$(foreground) || true
  if [ "$state" = idle ]; then idle_again=1; break; fi
  sleep 0.1
done
[ "$idle_again" = 1 ] || fail "the pane must read idle again once the command exits, last '$state'"
pass "process-info separates an idle shell from a running foreground command on an agent-free pane"

# --- 6. what the strict quiescence proof can and cannot see -------------------------
# The launch owners replace an agent-free pane only when
# fm_backend_herdr_pane_idle_shell_pid proves it: idle foreground, no child
# process of the shell in the OS table, sleeping shell. Each counterexample
# below is exercised on the real pane and its verdict recorded; the last one
# is the disclosed boundary, observed rather than asserted.
strict() {  # -> 0 proven, 1 not proven, 2 unprovable
  HERDR_SESSION="$SESSION" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=5 bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_idle_shell_pid "$1" "$2" "$3" "$4" >/dev/null' "$ROOT" "$SESSION" "$pane" "$ws" "$tab"
}
strict && rc=0 || rc=$?
[ "$rc" = 0 ] || fail "a plain idle pane must satisfy the strict proof, got rc $rc"
# delayed start: `sleep 2; true` holds the foreground group -> not proven
lab pane run "$pane" "sleep 2; true" >/dev/null || fail "pane run failed"
sleep 0.3
strict && rc=0 || rc=$?
[ "$rc" = 1 ] || fail "a delayed start (sleep in the foreground) must not be proven quiescent, got rc $rc"
sleep 2.5
# attached background child: `sleep 3 &` stays a child of the shell -> not proven
lab pane run "$pane" "sleep 3 &" >/dev/null || fail "pane run failed"
sleep 0.5
strict && rc=0 || rc=$?
[ "$rc" = 1 ] || fail "an attached background child must not be proven quiescent, got rc $rc"
printf 'observed: attached background child -> strict proof rc %s (refused)\n' "$rc"
sleep 3.5
# typed but unsubmitted input: the shell is idle; replacement closes the pane,
# so the pending text can never run there
lab pane send-text "$pane" "echo pending-launch" >/dev/null || fail "send-text failed"
sleep 0.5
strict && rc=0 || rc=$?
printf 'observed: pending unsubmitted input -> strict proof rc %s (an idle shell; replacement closes the pane before anything runs)\n' "$rc"
lab pane send-keys "$pane" ctrl-u >/dev/null 2>&1 || true
# the boundary: a process that already detached from the shell (`(sleep 3 &)`
# is reparented away) is invisible to every supported native check
lab pane run "$pane" "(sleep 3 &)" >/dev/null || fail "pane run failed"
sleep 0.7
strict && rc=0 || rc=$?
printf 'observed: detached (reparented) background process -> strict proof rc %s (the documented boundary: not detectable natively)\n' "$rc"
sleep 3
pass "the strict quiescence proof refuses a delayed start and an attached child; its boundary is recorded as observed"

# --- 3. closed pane reads pane_not_found ---------------------------------------------
lab pane close "$pane" >/dev/null || fail "pane close failed"
sleep 0.5
if out=$(lab pane get "$pane" 2>&1); then
  fail "pane get after close must not succeed: $out"
fi
printf '%s' "$out" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1 || fail "a closed pane must read pane_not_found, got: $out"
# The presence classifier is what reconciliation reads for a gone pane; the
# agent-state classifier needs a present pane and reports nothing here
# (observed on 0.8.2, recorded below), which is exactly why presence is read
# first.
presence=$(HERDR_SESSION="$SESSION" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_presence_state "$1" "$2" "$3" "$4"' "$ROOT" "$SESSION" "$pane" "$ws" "$tab") || true
[ "$presence" = dead ] || fail "the presence classifier must read a closed pane as dead, got '$presence'"
state=$(classify) || true
printf 'observed: agent-state classifier on a closed pane -> %s\n' "${state:-<empty>}"
lab pane close "$seed_pane" >/dev/null || fail "seed pane close failed"
sleep 0.5
# Closing a workspace's last tab removes the workspace itself (documented
# Herdr behavior), so "nothing left" is either zero tabs or no such workspace.
if lab workspace list 2>/dev/null | jq -e --arg w "$ws" '[.result.workspaces[] | select(.workspace_id == $w)] | length == 0' >/dev/null 2>&1; then
  remaining=0
else
  remaining=$(lab tab list --workspace "$ws" 2>/dev/null | jq -r '.result.tabs | length' 2>/dev/null || echo unknown)
fi
[ "$remaining" = 0 ] || fail "closing both panes must leave nothing in the lab workspace, got '$remaining'"
pass "a closed pane reads pane_not_found and the presence classifier reads it dead"
