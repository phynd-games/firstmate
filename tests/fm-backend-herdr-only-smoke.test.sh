#!/usr/bin/env bash
# tests/fm-backend-herdr-only-smoke.test.sh - real-Herdr smoke test for the
# Herdr-only runtime invariant (AGENTS.md hard rule 6; owner
# bin/fm-backend-policy-lib.sh), driving the REAL bin/fm-spawn.sh and
# bin/fm-teardown.sh end to end against a helper-provisioned, per-run named
# Herdr lab session with a scratch FM_HOME and a scratch local-only project.
#
# Two things only a real Herdr can prove:
#   1. A home that declares nothing is refused by name even though the spawn
#      runs with HERDR_ENV=1 - the Herdr marker never auto-selects - and the
#      refusal leaves no task record and creates nothing in the lab session.
#   2. A home that declares `herdr` in config/backend spawns for real: the
#      adapter's own native checks (herdr status protocol floor, server, pane
#      creation) accept the runtime, the meta records backend=herdr with its
#      exact endpoint fields, the launch command runs in the Herdr pane, and
#      teardown closes it.
# The deterministic, fake-binary counterpart for every other boundary is
# tests/fm-backend-herdr-only.test.sh.
#
# This suite runs OUTSIDE the regression lane on purpose: it never sources
# tests/lib.sh, and FM_BACKEND_LEGACY_TEST_LANE is explicitly unset, so the
# active-runtime policy is what is under test.
#
# Safety (2026-07-02 incident): every test-owned Herdr operation goes through
# bin/fm-herdr-lab.sh, which appends the named session flag and verifies the
# default fleet session is unchanged after teardown. Never replace the helper
# with an ambient HERDR_SESSION-only command.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

export FM_GATE_REFUSE_BYPASS=1
unset FM_BACKEND_LEGACY_TEST_LANE FM_BACKEND

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# A Herdr pane inherited from the terminal this suite was launched in must not
# follow spawn into the isolated lab session as a cross-session parent identity;
# each spawn below sets the Herdr markers it means to test explicitly.
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-backend-herdr-only-smoke.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-only-smoke) || {
  rm -rf "$TMP_ROOT"
  fail "could not generate an isolated Herdr lab session name"
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
ID="herdronlysmoke1"
WT=
cleanup_all() {
  local cleanup_status=0
  [ -n "$WT" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT" >/dev/null 2>&1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_status=$?
  rm -rf "$TMP_ROOT"
  return "$cleanup_status"
}
on_exit() {
  local status=$?
  cleanup_all || status=$?
  trap - EXIT
  exit "$status"
}
trap on_exit EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

# --- scratch world: one FM_HOME, one throwaway project ----------------------

STATE="$TMP_ROOT/state"; DATA="$TMP_ROOT/data"; CONFIG="$TMP_ROOT/config"
mkdir -p "$STATE" "$DATA/$ID" "$CONFIG"
# Selection is what is under test, so opt out of the default-on presentation
# projection and keep the assertions on the flat per-home workspace.
printf 'off\n' > "$CONFIG/herdr-presentation-spaces"
printf 'trivial herdr-only-smoke brief: nothing to do.\n' > "$DATA/$ID/brief.md"

PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

spawn() {  # <out> <err> <env...>
  local out=$1 err=$2; shift 2
  env -u TMUX -u FM_BACKEND -u FM_BACKEND_LEGACY_TEST_LANE PATH="$PATH" "$@" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" "sh -c 'echo herdr-only-smoke-ok'" --mode no-mistakes --yolo off \
    >"$out" 2>"$err"
}

# --- 1. undeclared home under HERDR_ENV=1: refused, nothing created --------

WORKSPACES_BEFORE=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list --json 2>/dev/null | jq -c '[.workspaces[]?.workspace_id] | sort' 2>/dev/null || printf '[]')
OUT_FILE="$TMP_ROOT/refused.out"; ERR_FILE="$TMP_ROOT/refused.err"
spawn "$OUT_FILE" "$ERR_FILE" HERDR_ENV=1
status=$?
[ "$status" -ne 0 ] || fail "fm-spawn.sh must refuse an undeclared home even under HERDR_ENV=1"$'\n'"--- stdout ---"$'\n'"$(cat "$OUT_FILE")"
[ ! -s "$OUT_FILE" ] || fail "a refused spawn must print nothing on stdout"$'\n'"$(cat "$OUT_FILE")"
assert_contains_local "$(cat "$ERR_FILE")" "REFUSED: neither FM_BACKEND nor $CONFIG/backend declares no backend identity" \
  "the refusal must name the undeclared inputs"
assert_contains_local "$(cat "$ERR_FILE")" "Herdr is the sole supported Firstmate runtime backend" \
  "the refusal must name Herdr"
assert_contains_local "$(cat "$ERR_FILE")" "never used for selection: HERDR_ENV=1" \
  "the refusal must show the Herdr marker was seen and ignored"
case "$(cat "$ERR_FILE")" in
  *NOTICE*) fail "an undeclared home must never print an auto-detect notice"$'\n'"$(cat "$ERR_FILE")" ;;
esac
[ ! -e "$STATE/$ID.meta" ] || fail "a refused spawn must not write a task record"
WORKSPACES_AFTER=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list --json 2>/dev/null | jq -c '[.workspaces[]?.workspace_id] | sort' 2>/dev/null || printf '[]')
[ "$WORKSPACES_BEFORE" = "$WORKSPACES_AFTER" ] || fail "a refused spawn must create nothing in the lab session (before=$WORKSPACES_BEFORE after=$WORKSPACES_AFTER)"
pass "real herdr: HERDR_ENV=1 alone never selects - an undeclared home is refused by name and nothing is created"

# --- 2. declared herdr: the adapter's native checks accept and spawn ---------

printf 'herdr\n' > "$CONFIG/backend"
OUT_FILE="$TMP_ROOT/spawn.out"; ERR_FILE="$TMP_ROOT/spawn.err"
spawn "$OUT_FILE" "$ERR_FILE" HERDR_ENV=1
status=$?
[ "$status" -eq 0 ] || fail "fm-spawn.sh did not succeed with config/backend=herdr"$'\n'"--- stdout ---"$'\n'"$(cat "$OUT_FILE")"$'\n'"--- stderr ---"$'\n'"$(cat "$ERR_FILE")"
case "$(cat "$ERR_FILE")" in
  *NOTICE*) fail "a declared herdr home must spawn silently, never as auto-detected"$'\n'"$(cat "$ERR_FILE")" ;;
  *REFUSED*) fail "a declared herdr home must not be refused"$'\n'"$(cat "$ERR_FILE")" ;;
esac
pass "real herdr: fm-spawn.sh accepts the declared herdr home silently"

META="$STATE/$ID.meta"
[ -f "$META" ] || fail "fm-spawn.sh did not write a meta file for $ID"
assert_contains_local "$(cat "$META")" "backend=herdr" "spawn did not record backend=herdr in meta"
assert_contains_local "$(cat "$META")" "endpoint_task_id=$ID" "spawn did not record the endpoint task binding"
assert_contains_local "$(cat "$META")" "herdr_session=$HERDR_LAB_SESSION" "spawn did not record the isolated herdr_session in meta"
WORKSPACE=$(grep '^herdr_workspace_id=' "$META" | cut -d= -f2-)
[ -n "$WORKSPACE" ] || fail "spawn meta is missing herdr_workspace_id"
TAB=$(grep '^herdr_tab_id=' "$META" | cut -d= -f2-)
[ -n "$TAB" ] || fail "spawn meta is missing herdr_tab_id"
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  fail "spawn did not report a real worktree path"
fi
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ -n "$PANE" ] || fail "spawn meta is missing herdr_pane_id"
pass "real herdr: the spawn records backend=herdr and its exact herdr_session/workspace/tab/pane endpoint fields"

# --- the launch command actually ran in the herdr pane ----------------------

sleep 1
CAPTURED=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent --lines 200) || \
  fail "capture failed on the spawned herdr pane"
CAPTURED=$(printf '%s\n' "$CAPTURED" | tail -n 30)
case "$CAPTURED" in
  *herdr-only-smoke-ok*) : ;;
  *) fail "the raw launch command did not run in the herdr pane"$'\n'"$CAPTURED" ;;
esac
pass "real herdr: the launch command actually ran in the herdr pane"

# --- teardown completes the trivial spawn/teardown cycle --------------------

TEARDOWN_OUT="$TMP_ROOT/teardown.out"
env -u FM_BACKEND_LEGACY_TEST_LANE FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_CONFIG_OVERRIDE="$CONFIG" \
  "$ROOT/bin/fm-teardown.sh" "$ID" >"$TEARDOWN_OUT" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "fm-teardown.sh failed for the herdr task"$'\n'"$(cat "$TEARDOWN_OUT")"
[ -f "$META" ] && fail "fm-teardown.sh did not remove $META"
if "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$PANE" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close the herdr pane"
fi
WT=
pass "real herdr: teardown completes the spawn/teardown cycle (meta cleared, pane closed)"

if ! cleanup_all; then
  trap - EXIT
  fail "isolated Herdr lab teardown failed or the default fleet session changed"
fi
trap - EXIT
pass "real herdr: isolated lab session removed and default fleet session unchanged"
