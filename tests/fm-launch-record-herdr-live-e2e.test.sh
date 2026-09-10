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
#   6. The strict idle-shell proof refuses a delayed start and an attached
#      child but PASSES a detached, reparented process: recorded as the
#      counterevidence that makes the proof diagnostic only in every launch
#      owner (an open attempt is never settled on it).
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

# Prepare and verify the launch-owner fixture before any native lifecycle call.
# This portable check also runs without the live opt-in, so intake defects fail
# locally even when provisioning the named lab is unavailable.
TMP_ROOT=$(fm_test_tmproot fm-launch-record-live)
owner_home="$TMP_ROOT/owner-home"
owner_bin="$TMP_ROOT/owner-bin"
mkdir -p "$owner_home/state" "$owner_home/data" "$owner_home/config" "$owner_bin"
printf 'herdr\n' > "$owner_home/config/backend"
printf 'off\n' > "$owner_home/config/herdr-presentation-spaces"
printf 'manual\n' > "$owner_home/config/backlog-backend"
FM_HOME="$owner_home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$owner_home/state" \
  FM_DATA_OVERRIDE="$owner_home/data" FM_CONFIG_OVERRIDE="$owner_home/config" \
  "$ROOT/bin/fm-brief.sh" launch-live project --scout \
  --not-applicable "configuration: task=launch-live; target=tests/fm-launch-record-herdr-live-e2e.test.sh launch-owner fixture; action=exercise retained launch obligation" >/dev/null \
  || fail "could not prepare the launch-owner fixture"
fixture_out=$(FM_HOME="$owner_home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$owner_home/state" \
  FM_DATA_OVERRIDE="$owner_home/data" FM_CONFIG_OVERRIDE="$owner_home/config" \
  "$ROOT/bin/fm-lavish-intake.sh" check-brief launch-live "$owner_home/data/launch-live/brief.md") \
  || fail "launch-owner fixture failed intake verification"
assert_contains "$fixture_out" "status=not-applicable" "launch-owner fixture must retain its intake classification"
pass "launch-owner fixture prepares and verifies through the intake owner"

# Capture the delegate environment and executable before prefixing PATH.
# Both the portable preflight and the native launch use this same boundary.
LAB="$ROOT/bin/fm-herdr-lab.sh"
owner_lab_command() {
  local delegate_path=$PATH delegate
  delegate=$(command -v herdr) || return 96
  PATH="$owner_bin:$delegate_path" FM_TEST_LAB_PATH="$delegate_path" \
    FM_TEST_LAB_DELEGATE="$delegate" FM_TEST_LAB_HELPER="$LAB" "$@"
}
cat > "$owner_bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
# Refuse re-entry before calling another helper, even through an indirect shim.
[ "${FM_TEST_LAB_DELEGATING:-0}" = 0 ] || { echo "lab wrapper: recursive delegation refused" >&2; exit 96; }
delegate=$(PATH="$FM_TEST_LAB_PATH" command -v herdr) || exit 96
[ -x "$delegate" ] && [ "$delegate" -ef "$FM_TEST_LAB_DELEGATE" ] &&
  [ ! "$delegate" -ef "$0" ] || { echo "lab wrapper: unsafe delegate refused" >&2; exit 96; }
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  [ "${args[$((n-1))]}" = "$FM_TEST_LAB_SESSION" ] || exit 97
  args=("${args[@]:0:$((n-2))}")
fi
case "${args[0]} ${args[1]:-}" in
  'status --json'|'session list'|'pane get'|'pane list'|'pane process-info'|'agent get'|'agent list'|'workspace list'|'tab list') ;;
  *) printf '%s\n' "${args[*]}" >> "$FM_TEST_LAB_MUTATIONS"; exit 98 ;;
esac
exec env FM_TEST_LAB_DELEGATING=1 PATH="$FM_TEST_LAB_PATH" "$FM_TEST_LAB_HELPER" run "$FM_TEST_LAB_SESSION" "${args[@]}"
SH
chmod +x "$owner_bin/herdr"

# Exercise the real wrapper and lab run helper without native Herdr access.
# The fixture caps helper calls independently; a timeout is always a failure.
preflight_bin="$TMP_ROOT/preflight-bin"
mkdir -p "$preflight_bin"
cat > "$preflight_bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_LAB_CALLS"
if [ "${FM_TEST_LAB_REENTER:-0}" = 1 ]; then
  exec "$FM_TEST_LAB_WRAPPER" "$@"
fi
printf 'fixture native response\n'
exit "${FM_TEST_LAB_EXIT:-0}"
SH
cat > "$TMP_ROOT/preflight-helper" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'call\n' >> "$FM_TEST_LAB_HELPER_CALLS"
[ "$(wc -l < "$FM_TEST_LAB_HELPER_CALLS")" -le 2 ] || exit 99
exec "$FM_TEST_LAB_REAL_HELPER" "$@"
SH
chmod +x "$preflight_bin/herdr" "$TMP_ROOT/preflight-helper"
FM_TEST_LAB_REAL_HELPER="$LAB" LAB="$TMP_ROOT/preflight-helper" \
  PATH="$preflight_bin:$PATH" FM_TEST_LAB_SESSION=fm-lab-wrapper \
  FM_TEST_LAB_HELPER_CALLS="$TMP_ROOT/preflight-helper-calls" \
  FM_TEST_LAB_MUTATIONS="$TMP_ROOT/preflight-mutations" \
  FM_TEST_LAB_CALLS="$TMP_ROOT/preflight-calls" FM_TEST_LAB_WRAPPER="$owner_bin/herdr" \
  owner_lab_command python3 - "$owner_bin/herdr" "$TMP_ROOT" <<'PYTHON' || fail "lab wrapper preflight failed"
import os
from pathlib import Path
import subprocess
import sys

wrapper, root = sys.argv[1:]
calls = Path(os.environ["FM_TEST_LAB_CALLS"])
mutations = Path(os.environ["FM_TEST_LAB_MUTATIONS"])
helper_calls = Path(os.environ["FM_TEST_LAB_HELPER_CALLS"])

def run(args, expected, changes=None, expected_calls=0):
    calls.write_text("")
    mutations.write_text("")
    helper_calls.write_text("")
    env = dict(os.environ, **(changes or {}))
    result = subprocess.run([wrapper, *args], env=env, capture_output=True,
                            text=True, timeout=5)
    assert result.returncode == expected, (result.returncode, result.stderr)
    assert len(calls.read_text().splitlines()) == expected_calls, calls.read_text()
    assert len(helper_calls.read_text().splitlines()) == expected_calls, helper_calls.read_text()
    return result

args = ["pane", "get", "pane-fixture", "--session", "fm-lab-wrapper"]
result = run(args, 0, expected_calls=1)
assert result.stdout == "fixture native response\n", result.stdout
assert calls.read_text() == "pane get pane-fixture --session fm-lab-wrapper\n"
assert not mutations.read_text()
run(args, 23, {"FM_TEST_LAB_EXIT": "23"}, expected_calls=1)
run(["pane", "get", "pane-fixture", "--session", "default"], 97)
run(["workspace", "create"], 98)
assert mutations.read_text() == "workspace create\n"
# Detect the original contaminated PATH before a second helper can start.
run(args, 96, {"FM_TEST_LAB_PATH": os.environ["PATH"]})
run(args, 96, {"FM_TEST_LAB_PATH": os.environ["PATH"],
               "FM_TEST_LAB_DELEGATE": wrapper})
alias = Path(root) / "alias-bin"
alias.mkdir()
(alias / "herdr").symlink_to(wrapper)
run(args, 96, {"FM_TEST_LAB_PATH": str(alias) + ":" + os.environ["PATH"],
               "FM_TEST_LAB_DELEGATE": str(alias / "herdr")})
run(args, 96, {"FM_TEST_LAB_DELEGATING": "1"})
run(args, 96, {"FM_TEST_LAB_REENTER": "1"}, expected_calls=1)
PYTHON
pass "lab wrapper delegates once, preserves refusals, and rejects self-resolution and recursion"

if [ "${FM_LAUNCH_RECORD_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_LAUNCH_RECORD_LIVE=1 to run the live Herdr launch-record boundary check"
  exit 0
fi
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fm_git_worktree "$TMP_ROOT/owner-project" "$TMP_ROOT/owner-worktree" fm/launch-live

herdr_forget_inherited_pane
unset HERDR_BIN_PATH

SESSION=$("$LAB" name launch-record)
trap 'herdr_finish_test "$?" "$SESSION"' EXIT
"$LAB" provision "$SESSION" || fail "could not provision lab session $SESSION"

lab() { "$LAB" run "$SESSION" "$@"; }

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
# fm_backend_herdr_pane_idle_shell_pid is diagnostic only: idle foreground,
# no child process of the shell in the OS table, sleeping shell. Each counterexample
# below is exercised on the real pane and its verdict recorded; the last one
# is the disclosed boundary, observed rather than asserted.
# Use the adapter's supported bounded settle window, including prompt helpers.
unset FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS
strict() {  # -> 0 proven, 1 not proven, 2 unprovable
  HERDR_SESSION="$SESSION" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_idle_shell_pid "$1" "$2" "$3" "$4" >/dev/null' "$ROOT" "$SESSION" "$pane" "$ws" "$tab"
}
strict && rc=0 || rc=$?
[ "$rc" = 0 ] || fail "a plain idle pane must satisfy the strict proof, got rc $rc"
# Sample the refusal controls while their known command is still active;
# waiting for that command to finish would test eventual idle instead.
# delayed start: `sleep 2; true` holds the foreground group -> not proven
lab pane run "$pane" "sleep 2; true" >/dev/null || fail "pane run failed"
sleep 0.3
FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 strict && rc=0 || rc=$?
[ "$rc" = 1 ] || fail "a delayed start (sleep in the foreground) must not be proven quiescent, got rc $rc"
sleep 2.5
# attached background child: `sleep 3 &` stays a child of the shell -> not proven
lab pane run "$pane" "sleep 3 &" >/dev/null || fail "pane run failed"
sleep 0.5
FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 strict && rc=0 || rc=$?
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
FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 strict && rc=0 || rc=$?
printf 'observed: detached (reparented) background process -> strict proof rc %s (the documented boundary: not detectable natively)\n' "$rc"
owner_record() {
  python3 "$ROOT/bin/fm-launch-record.py" --state "$owner_home/state" "$@" --task launch-live
}
owner_record intend --owner fm-spawn.sh --origin fresh >/dev/null || fail "could not seed launch intent"
owner_id=$(owner_record get launch.id)
owner_record created --launch "$owner_id" --identity backend=herdr --identity session="$SESSION" \
  --identity workspace_id="$ws" --identity tab_id="$tab" --identity pane_id="$pane" \
  --identity terminal_id="$term" >/dev/null || fail "could not bind the existing pane"
owner_before=$(cksum < "$owner_home/state/launch-live.launch")
: > "$TMP_ROOT/owner-mutations"
owner_out=$(FM_TEST_LAB_SESSION="$SESSION" FM_TEST_LAB_MUTATIONS="$TMP_ROOT/owner-mutations" \
  HERDR_SESSION="$SESSION" FM_HOME="$owner_home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$owner_home/state" FM_DATA_OVERRIDE="$owner_home/data" \
  FM_CONFIG_OVERRIDE="$owner_home/config" FM_PROJECTS_OVERRIDE="$TMP_ROOT" FM_SPAWN_NO_GUARD=1 \
  owner_lab_command "$ROOT/bin/fm-spawn.sh" launch-live "$TMP_ROOT/owner-project" --scout "sh -c true" 2>&1)
owner_rc=$?
expect_code 1 "$owner_rc" "a present agent-free pane must refuse a replacement: $owner_out"
assert_contains "$owner_out" "recorded endpoint $SESSION:$pane is present with an open launch record" \
  "the refusal must come from the launch owner after inspecting the exact pane"
[ ! -s "$TMP_ROOT/owner-mutations" ] || fail "spawn attempted a native mutation: $(cat "$TMP_ROOT/owner-mutations")"
[ "$(cksum < "$owner_home/state/launch-live.launch")" = "$owner_before" ] || fail "spawn changed the retained launch"
owner_record check >/dev/null && owner_rc=0 || owner_rc=$?
expect_code 3 "$owner_rc" "the existing pane must retain its open obligation"
lab pane get "$pane" >/dev/null || fail "spawn removed the recorded pane"
pass "the spawn owner refuses a present agent-free pane, retains its obligation, and issues no replacement create"

sleep 3
pass "the strict quiescence proof refuses a delayed start and an attached child, passes a detached process, and is therefore diagnostic only - never permission to replace"

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
