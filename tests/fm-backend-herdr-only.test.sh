#!/usr/bin/env bash
# tests/fm-backend-herdr-only.test.sh - the Herdr-only runtime invariant
# (AGENTS.md hard rule 6; owner bin/fm-backend-policy-lib.sh).
#
# Every case runs OUTSIDE the regression lane: tests/lib.sh exports
# FM_BACKEND_LEGACY_TEST_LANE=1 for the retained-adapter suites, so this file
# strips it (the same way tests/fm-gate-refuse.test.sh strips
# FM_GATE_REFUSE_BYPASS) together with every runtime marker the developer's own
# terminal could leak (TMUX, HERDR_ENV, CMUX_WORKSPACE_ID, ...), and then proves,
# deterministically and without a real backend binary:
#
#   - selection never falls back: absent/empty/legacy/unknown config/backend,
#     FM_BACKEND, and --backend all refuse; declared herdr is accepted;
#   - runtime markers, nested or alone, never select (no auto-detect, no tmux);
#   - retained adapters are unreachable through every dispatcher, including the
#     tmux arm that used to call the tmux CLI directly;
#   - fm-spawn refuses before any worktree/runtime side effect, and a missing or
#     below-floor Herdr refuses WITHOUT ever invoking tmux (a recording fake
#     tmux on PATH stays empty);
#   - inherited secondmate config/backend is judged by the same rule;
#   - supervisor-pane discovery has no tmux default and refuses non-Herdr;
#   - legacy task metadata (no backend=, or a retained backend) is refused
#     read-only by the metadata helpers and by fm-crew-state, fm-peek, fm-send,
#     fm-control, and fm-teardown, with the record left byte-identical;
#   - a Herdr record and a Herdr endpoint pass every boundary;
#   - every refusal prints nothing on stdout, exactly one REFUSED line on stderr
#     naming Herdr and a remediation,
#     and exits non-zero.
#
# The real-Herdr counterpart (config-declared herdr actually spawns; HERDR_ENV=1
# alone does not) is tests/fm-backend-herdr-only-smoke.test.sh in the
# real-herdr-gated lane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-only)

# Every marker the environment could contribute, stripped for every case.
STRIP=(-u FM_BACKEND_LEGACY_TEST_LANE -u FM_BACKEND -u FM_BACKEND_TEST_HARNESS
  -u FM_BACKEND_TEST_ROOT -u FM_BACKEND_TEST_OWNER_PID -u FM_BACKEND_TEST_OWNER_IDENTITY
  -u FM_BACKEND_TEST_CAPABILITY_FD
  -u TMUX -u TMUX_PANE
  -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID
  -u HERDR_SOCKET_PATH -u HERDR_SESSION -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID
  -u __CFBundleIdentifier -u FM_SUPERVISOR_BACKEND -u FM_SUPERVISOR_TARGET)

# policy_env <var=value...> -- <command...>: run <command> with the lane and every
# marker stripped, then the given assignments applied.
policy_env() {
  local -a vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env "${STRIP[@]}" ${vars[@]+"${vars[@]}"} "$@"
}

# lib_probe <var=value...> -- <bash snippet>: source bin/fm-backend.sh (and the
# supervisor lib) in a stripped subshell and run the snippet there.
lib_probe() {
  local -a vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env "${STRIP[@]}" ${vars[@]+"${vars[@]}"} bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-supervisor-target-lib.sh"; shift; eval "$*"' _ "$ROOT" "$@"
}

# run_capture <dir-prefix> <command...>: run, capturing stdout/stderr/status into
# OUT/ERR/RC for the assertions below.
OUT=""; ERR=""; RC=0
run_capture() {
  local tag=$1; shift
  local o="$TMP_ROOT/$tag.out" e="$TMP_ROOT/$tag.err"
  "$@" >"$o" 2>"$e"
  RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
}

# assert_refusal <label> [expected-fragment...]: the shared diagnostic-safety
# contract - non-zero exit, EMPTY stdout (no usable backend name can leak to a
# caller), exactly one REFUSED line, which names Herdr and never a fallback.
assert_refusal() {
  local label=$1; shift
  [ "$RC" -ne 0 ] || fail "$label: expected a refusal exit, got 0"$'\n'"stdout: $OUT"$'\n'"stderr: $ERR"
  [ -z "$OUT" ] || fail "$label: a refusal must print nothing on stdout, got: $OUT"
  [ "$(printf '%s\n' "$ERR" | grep -c '^REFUSED: ')" -eq 1 ] \
    || fail "$label: expected exactly one REFUSED line"$'\n'"$ERR"
  assert_contains "$ERR" "Herdr is the sole supported Firstmate runtime backend" "$label: refusal must name Herdr"
  local frag
  for frag in "$@"; do
    assert_contains "$ERR" "$frag" "$label: refusal missing '$frag'"
  done
}

LEGACY_NAMES="tmux zellij orca cmux"

# --- selection --------------------------------------------------------------

test_known_sets_are_herdr_only() {
  local out config="$TMP_ROOT/known-config" lane_config="$TMP_ROOT/lane-config"
  mkdir -p "$config"
  mkdir -p "$lane_config"
  printf 'herdr\n' > "$config/backend"
  run_capture active-herdr lib_probe "FM_CONFIG_OVERRIDE=$config" -- 'fm_backend_name'
  [ "$RC" -eq 0 ] && [ "$OUT" = herdr ] || fail "active public selection must accept declared herdr: rc=$RC out=$OUT err=$ERR"
  run_capture active-tmux lib_probe -- 'fm_backend_validate_spawn tmux'
  assert_refusal "active public spawn validation for tmux" "resolves 'tmux'"
  out=$(env "${STRIP[@]}" FM_BACKEND_LEGACY_TEST_LANE=1 FM_BACKEND_TEST_HARNESS=1 \
    FM_BACKEND_TEST_ROOT="$ROOT" FM_BACKEND_TEST_OWNER_PID="$$" \
    FM_BACKEND_TEST_OWNER_IDENTITY="$FM_TEST_OWNER_IDENTITY" FM_CONFIG_OVERRIDE="$lane_config" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_name' _ "$ROOT")
  [ "$out" = tmux ] || fail "repository test process must retain the legacy public selection behavior, got $out"
  pass "public backend selection accepts Herdr and refuses retained adapters outside the regression lane"
}

test_legacy_lane_requires_harness_identity() {
  local config="$TMP_ROOT/untrusted-lane-config" forged="$TMP_ROOT/forged-capability"
  mkdir -p "$config"
  printf 'tmux\n' > "$config/backend"
  run_capture untrusted-lane lib_probe "FM_CONFIG_OVERRIDE=$config" FM_BACKEND_LEGACY_TEST_LANE=1 -- 'exec 9>&-; fm_backend_name'
  assert_refusal "an untrusted legacy-lane marker" "$config/backend resolves 'tmux'"
  printf 'forged\n' > "$forged"
  run_capture forged-lane lib_probe "FM_CONFIG_OVERRIDE=$config" "FM_FORGED_CAPABILITY=$forged" FM_BACKEND_LEGACY_TEST_LANE=1 -- 'exec 9<"$FM_FORGED_CAPABILITY"; fm_backend_source tmux'
  assert_refusal "a forged retained-adapter capability" "resolves 'tmux'"
  pass "the retained-adapter lane requires the hermetic test harness identity"
}

test_name_refuses_absent_or_empty_config() {
  local config="$TMP_ROOT/absent-config"
  mkdir -p "$config"
  run_capture absent lib_probe "FM_CONFIG_OVERRIDE=$config" -- 'fm_backend_name'
  assert_refusal "no FM_BACKEND, no config/backend" "declares no backend identity" \
    "$config/backend" "FM_BACKEND=herdr" "bin/fm-setup-phynd.sh" "herdr status --json"
  : > "$config/backend"
  run_capture empty lib_probe "FM_CONFIG_OVERRIDE=$config" -- 'fm_backend_name'
  assert_refusal "empty config/backend" "present but empty"
  printf '\n   \n' > "$config/backend"
  run_capture blank lib_probe "FM_CONFIG_OVERRIDE=$config" -- 'fm_backend_name'
  assert_refusal "whitespace-only config/backend" "present but empty"
  pass "fm_backend_name refuses an undeclared home instead of defaulting (no tmux default)"
}

test_name_refuses_every_non_herdr_config_value() {
  local config="$TMP_ROOT/bad-config" v
  mkdir -p "$config"
  for v in $LEGACY_NAMES codex-app bogus; do
    printf '%s\n' "$v" > "$config/backend"
    run_capture "config-$v" lib_probe "FM_CONFIG_OVERRIDE=$config" -- 'fm_backend_name'
    assert_refusal "config/backend=$v" "resolves '$v'" "$config/backend"
  done
  pass "fm_backend_name refuses every retained, blocked, and unknown config/backend value"
}

test_name_refuses_every_non_herdr_fm_backend_value() {
  local config="$TMP_ROOT/env-config" v
  mkdir -p "$config"
  printf 'herdr\n' > "$config/backend"
  for v in $LEGACY_NAMES codex-app bogus; do
    run_capture "env-$v" lib_probe "FM_CONFIG_OVERRIDE=$config" "FM_BACKEND=$v" -- 'fm_backend_name'
    assert_refusal "FM_BACKEND=$v" "FM_BACKEND resolves '$v'"
  done
  pass "fm_backend_name refuses every non-herdr FM_BACKEND even when config/backend declares herdr (no fall-through)"
}

test_name_accepts_declared_herdr() {
  local config="$TMP_ROOT/herdr-config" out
  mkdir -p "$config"
  printf 'herdr\n' > "$config/backend"
  run_capture ok-config lib_probe "FM_CONFIG_OVERRIDE=$config" -- 'fm_backend_name'
  [ "$RC" -eq 0 ] && [ "$OUT" = herdr ] && [ -z "$ERR" ] || fail "config/backend=herdr should resolve silently: rc=$RC out=$OUT err=$ERR"
  printf '\n  \nherdr\n' > "$config/backend"
  out=$(lib_probe "FM_CONFIG_OVERRIDE=$config" -- 'fm_backend_name')
  [ "$out" = herdr ] || fail "first non-empty line herdr should resolve, got $out"
  rm -rf "$config"; mkdir -p "$config"
  run_capture ok-env lib_probe "FM_CONFIG_OVERRIDE=$config" FM_BACKEND=herdr -- 'fm_backend_name'
  [ "$RC" -eq 0 ] && [ "$OUT" = herdr ] && [ -z "$ERR" ] || fail "FM_BACKEND=herdr should resolve silently: rc=$RC out=$OUT err=$ERR"
  pass "fm_backend_name accepts a declared herdr from config/backend or FM_BACKEND"
}

test_runtime_markers_never_select() {
  local config="$TMP_ROOT/marker-config" out
  mkdir -p "$config"
  # Nested markers with herdr declared: herdr, silently, no innermost-first tmux.
  printf 'herdr\n' > "$config/backend"
  run_capture nested-declared lib_probe "FM_CONFIG_OVERRIDE=$config" TMUX=fake,1,0 TMUX_PANE=%1 HERDR_ENV=1 HERDR_PANE_ID=w1:p1 CMUX_WORKSPACE_ID=ws1 -- 'fm_backend_name'
  [ "$RC" -eq 0 ] && [ "$OUT" = herdr ] && [ -z "$ERR" ] \
    || fail "nested tmux/herdr/cmux markers with declared herdr must resolve herdr silently: rc=$RC out=$OUT err=$ERR"
  # Same markers, nothing declared: refused, and the diagnostic names the ignored markers.
  rm -f "$config/backend"
  run_capture nested-undeclared lib_probe "FM_CONFIG_OVERRIDE=$config" TMUX=fake,1,0 HERDR_ENV=1 CMUX_WORKSPACE_ID=ws1 -- 'fm_backend_name'
  assert_refusal "nested markers, undeclared" "never used for selection: TMUX, CMUX_WORKSPACE_ID, HERDR_ENV=1"
  # HERDR_ENV=1 alone is not auto-detection either.
  run_capture herdr-env-alone lib_probe "FM_CONFIG_OVERRIDE=$config" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 -- 'fm_backend_name'
  assert_refusal "HERDR_ENV=1 alone" "never used for selection: HERDR_ENV=1"
  # TMUX alone never yields tmux.
  run_capture tmux-alone lib_probe "FM_CONFIG_OVERRIDE=$config" TMUX=fake,1,0 -- 'fm_backend_name'
  assert_refusal "TMUX alone" "never used for selection: TMUX"
  # fm_backend_detect is inert: no output, non-zero, regardless of markers.
  run_capture detect lib_probe TMUX=fake,1,0 HERDR_ENV=1 CMUX_WORKSPACE_ID=ws1 -- 'fm_backend_detect; rc=$?; printf "[%s|%s]" "$FM_BACKEND_DETECTED" "$FM_BACKEND_DETECT_SIGNAL"; exit $rc'
  [ "$RC" -ne 0 ] || fail "fm_backend_detect must not detect anything outside the regression lane"
  [ "$OUT" = "[|]" ] || fail "fm_backend_detect must print nothing and set no detect globals, got $OUT"
  pass "runtime markers (TMUX, HERDR_ENV, cmux), nested or alone, never select a backend and detection is inert"
}

# --- dispatch boundaries ----------------------------------------------------

make_recording_fakebin() {  # <dir> <log> -> echoes fakebin dir; fake tmux/zellij/orca/cmux record every call
  local fb="$1/fakebin" log=$2 name
  mkdir -p "$fb"
  for name in tmux zellij orca cmux; do
    cat > "$fb/$name" <<SH
#!/usr/bin/env bash
{ printf '%s' "$name"; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "$log"
exit 0
SH
    chmod +x "$fb/$name"
  done
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

test_dispatchers_refuse_retained_adapters_without_running_them() {
  local log="$TMP_ROOT/dispatch.log" fb v
  : > "$log"
  fb=$(make_recording_fakebin "$TMP_ROOT/dispatch" "$log")
  for v in $LEGACY_NAMES; do
    run_capture "validate-$v" lib_probe -- "fm_backend_validate $v '--backend'"
    assert_refusal "fm_backend_validate $v" "--backend resolves '$v'" "Select herdr instead" "retained on disk only for the repository's regression lane"
    run_capture "validate-spawn-$v" lib_probe -- "fm_backend_validate_spawn $v"
    assert_refusal "fm_backend_validate_spawn $v" "resolves '$v'"
    run_capture "source-$v" lib_probe -- "fm_backend_source $v"
    assert_refusal "fm_backend_source $v" "resolves '$v'"
    run_capture "exists-$v" lib_probe "PATH=$fb:$PATH" -- "fm_backend_target_exists $v 'firstmate:0'"
    assert_refusal "fm_backend_target_exists $v" "resolves '$v'"
    run_capture "capture-$v" lib_probe "PATH=$fb:$PATH" -- "fm_backend_capture $v 'firstmate:0' 5"
    assert_refusal "fm_backend_capture $v" "resolves '$v'"
    run_capture "kill-$v" lib_probe "PATH=$fb:$PATH" -- "fm_backend_kill $v 'firstmate:0'"
    assert_refusal "fm_backend_kill $v" "resolves '$v'"
    run_capture "agent-$v" lib_probe "PATH=$fb:$PATH" -- "fm_backend_agent_state $v 'firstmate:0'"
    assert_refusal "fm_backend_agent_state $v" "resolves '$v'"
  done
  run_capture validate-bogus lib_probe -- 'fm_backend_validate bogus'
  [ "$RC" -ne 0 ] && [ -z "$OUT" ] || fail "unknown backend must refuse with empty stdout"
  assert_refusal "unknown backend" "selected runtime backend resolves 'bogus'" "Declare Herdr explicitly"
  [ ! -s "$log" ] || fail "no retained adapter CLI may run through a dispatcher; recorded:"$'\n'"$(cat "$log")"
  pass "every dispatcher refuses tmux/zellij/orca/cmux by name and never executes their CLIs"
}

test_selector_resolution_has_no_tmux_fallback() {
  local state="$TMP_ROOT/selector-state" log="$TMP_ROOT/selector.log" fb
  mkdir -p "$state"; : > "$log"
  fb=$(make_recording_fakebin "$TMP_ROOT/selector" "$log")
  run_capture bare lib_probe "PATH=$fb:$PATH" -- "fm_backend_resolve_selector somewindow '$state'"
  [ "$RC" -ne 0 ] && [ -z "$OUT" ] || fail "a bare window name must not resolve: rc=$RC out=$OUT"
  assert_contains "$ERR" "bare window names are not resolvable because Herdr is the sole supported runtime backend" "bare selector diagnostic"
  [ ! -s "$log" ] || fail "bare selector resolution must not search a tmux inventory"
  run_capture explicit lib_probe -- "fm_backend_herdr_version_check() { return 0; }; fm_backend_of_selector 'default:w9:p9' 'default:w9:p9' '$state'"
  [ "$RC" -eq 0 ] && [ "$OUT" = herdr ] || fail "an explicit unmatched target is a herdr endpoint, got rc=$RC out=$OUT"
  pass "selector resolution: bare names refuse without a tmux inventory search, explicit targets are herdr"
}

# --- fm-spawn ----------------------------------------------------------------

make_project() {  # <dir>
  fm_git_init_commit "$1"
  fm_git_add_origin "$1" "$1.origin.git"
}

spawn_case() {  # <tag> <config-dir> <state-dir> <fakebin> <log> <env...> -- <spawn args...>
  local tag=$1 config=$2 state=$3 fb=$4 log=$5; shift 5
  local -a vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  run_capture "$tag" policy_env "PATH=$fb:$PATH" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$state" \
    "FM_DATA_OVERRIDE=$TMP_ROOT/spawn-data" "FM_CONFIG_OVERRIDE=$config" \
    "FM_PROJECTS_OVERRIDE=$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 "FM_TMUX_LOG=$log" \
    ${vars[@]+"${vars[@]}"} -- "$ROOT/bin/fm-spawn.sh" "$@"
}

assert_spawn_left_nothing() {  # <label> <state-dir> <log>
  local label=$1 state=$2 log=$3
  [ -z "$(ls -A "$state" 2>/dev/null)" ] || fail "$label: spawn refusal must leave no task state, found: $(ls -A "$state")"
  [ ! -s "$log" ] || fail "$label: spawn refusal must never call a retained adapter CLI; recorded:"$'\n'"$(cat "$log")"
}

test_spawn_refuses_non_herdr_selection_before_side_effects() {
  local proj="$TMP_ROOT/spawn-project" state="$TMP_ROOT/spawn-state" config="$TMP_ROOT/spawn-config"
  local log="$TMP_ROOT/spawn.log" fb v id=spawnrefuse1
  make_project "$proj"
  mkdir -p "$state" "$config" "$TMP_ROOT/spawn-data/$id"
  printf 'brief\n' > "$TMP_ROOT/spawn-data/$id/brief.md"
  fb=$(make_recording_fakebin "$TMP_ROOT/spawn-fake" "$log")
  printf 'herdr\n' > "$config/backend"
  for v in $LEGACY_NAMES bogus; do
    : > "$log"
    spawn_case "spawn-flag-$v" "$config" "$state" "$fb" "$log" -- "$id" "$proj" "sh -c true" --mode no-mistakes --yolo off --backend "$v"
    [ "$RC" -ne 0 ] && [ -z "$OUT" ] || fail "--backend $v must refuse with empty stdout: rc=$RC out=$OUT"
    if [ "$v" = bogus ]; then
      assert_refusal "--backend bogus" "--backend resolves 'bogus'" "Declare Herdr explicitly"
    else
      assert_refusal "--backend $v" "--backend resolves '$v'" "Select herdr instead"
    fi
    assert_spawn_left_nothing "--backend $v" "$state" "$log"
  done
  : > "$log"
  spawn_case spawn-secondmate-flag-tmux "$config" "$state" "$fb" "$log" -- "$id" --secondmate --backend tmux
  assert_refusal "remote secondmate --backend=tmux" "--backend resolves 'tmux'" "Select herdr instead"
  assert_spawn_left_nothing "remote secondmate --backend=tmux" "$state" "$log"
  for v in $LEGACY_NAMES; do
    : > "$log"
    spawn_case "spawn-env-$v" "$config" "$state" "$fb" "$log" "FM_BACKEND=$v" -- "$id" "$proj" "sh -c true" --mode no-mistakes --yolo off
    assert_refusal "FM_BACKEND=$v" "FM_BACKEND resolves '$v'"
    assert_spawn_left_nothing "FM_BACKEND=$v" "$state" "$log"
  done
  printf 'tmux\n' > "$config/backend"
  : > "$log"
  spawn_case spawn-config-tmux "$config" "$state" "$fb" "$log" -- "$id" "$proj" "sh -c true" --mode no-mistakes --yolo off
  assert_refusal "config/backend=tmux" "$config/backend resolves 'tmux'"
  assert_spawn_left_nothing "config/backend=tmux" "$state" "$log"
  rm -f "$config/backend"
  : > "$log"
  spawn_case spawn-undeclared "$config" "$state" "$fb" "$log" TMUX=fake,1,0 HERDR_ENV=1 -- "$id" "$proj" "sh -c true" --mode no-mistakes --yolo off
  assert_refusal "undeclared home with TMUX and HERDR_ENV markers" "declares no backend identity" "never used for selection: TMUX, HERDR_ENV=1"
  assert_spawn_left_nothing "undeclared home" "$state" "$log"
  : > "$log"
  spawn_case spawn-secondmate-undeclared "$config" "$state" "$fb" "$log" -- "$id" --secondmate
  assert_refusal "undeclared remote secondmate" "declares no backend identity"
  assert_spawn_left_nothing "undeclared remote secondmate" "$state" "$log"
  pass "fm-spawn refuses --backend, FM_BACKEND, config/backend, and undeclared/auto-detect selection before any side effect"
}

make_herdr_stub() {  # <fakebin> <protocol> - a herdr CLI that only answers `status --json`
  cat > "$1/herdr" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then
  printf '{"client":{"version":"0.0.0-test","protocol":$2},"server":{"running":false}}\\n'
  exit 0
fi
if [ "\${1:-}" = pane ] && [ "\${2:-}" = get ]; then
  exit 0
fi
{ printf 'herdr'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${FM_HERDR_STUB_LOG:?}"
exit 1
SH
  chmod +x "$1/herdr"
}

test_spawn_refuses_missing_or_incapable_herdr_without_fallback() {
  local proj="$TMP_ROOT/herdr-gate-project" state="$TMP_ROOT/herdr-gate-state" config="$TMP_ROOT/herdr-gate-config"
  local log="$TMP_ROOT/herdr-gate.log" fb id=herdrgate1 stublog="$TMP_ROOT/herdr-stub.log"
  command -v jq >/dev/null 2>&1 || { pass "skip: jq not installed (the herdr adapter needs it to read the protocol)"; return 0; }
  make_project "$proj"
  mkdir -p "$state" "$config" "$TMP_ROOT/spawn-data/$id"
  printf 'brief\n' > "$TMP_ROOT/spawn-data/$id/brief.md"
  printf 'off\n' > "$config/herdr-presentation-spaces"
  printf 'herdr\n' > "$config/backend"
  fb=$(make_recording_fakebin "$TMP_ROOT/herdr-gate-fake" "$log")
  # Missing Herdr: a PATH that has the recording fakes and the system tools but
  # no herdr binary at all.
  : > "$log"
  run_capture missing-herdr policy_env "PATH=$fb:/usr/bin:/bin:/usr/sbin:/sbin" "FM_ROOT_OVERRIDE=$ROOT" \
    "FM_STATE_OVERRIDE=$state" "FM_DATA_OVERRIDE=$TMP_ROOT/spawn-data" "FM_CONFIG_OVERRIDE=$config" \
    "FM_PROJECTS_OVERRIDE=$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 -- \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c true" --mode no-mistakes --yolo off
  [ "$RC" -ne 0 ] || fail "spawn with herdr declared but not installed must refuse"
  assert_contains "$ERR" "the 'herdr' CLI is not installed" "missing-herdr refusal must name the herdr install requirement"
  assert_not_contains "$ERR" "NOTICE" "missing herdr must not print a fallback notice"
  assert_spawn_left_nothing "missing herdr" "$state" "$log"
  # Below the protocol floor: a herdr that answers status with protocol 13.
  make_herdr_stub "$fb" 13
  : > "$log"; : > "$stublog"
  spawn_case herdr-floor "$config" "$state" "$fb" "$log" "FM_HERDR_STUB_LOG=$stublog" -- "$id" "$proj" "sh -c true" --mode no-mistakes --yolo off
  [ "$RC" -ne 0 ] || fail "spawn on a below-floor herdr must refuse"
  assert_contains "$ERR" "herdr protocol 13" "floor refusal must name the observed protocol"
  assert_contains "$ERR" "older than the verified minimum" "floor refusal must name the floor"
  assert_spawn_left_nothing "below-floor herdr" "$state" "$log"
  [ ! -s "$stublog" ] || fail "a below-floor herdr must be refused after the status read, before any lifecycle call; recorded:"$'\n'"$(cat "$stublog")"
  run_capture target-floor lib_probe "PATH=$fb:$PATH" -- "fm_backend_target_exists herdr 'default:p1'"
  assert_refusal "target existence with below-floor Herdr" "target existence check resolves 'herdr'" "herdr protocol 13" "Upgrade or repair Herdr"
  run_capture capture-floor lib_probe "PATH=$fb:$PATH" -- "fm_backend_capture herdr 'default:p1' 5"
  assert_refusal "direct capture with below-floor Herdr" "Herdr runtime operation resolves 'herdr'" "herdr protocol 13" "Upgrade or repair Herdr"
  [ ! -s "$stublog" ] || fail "a below-floor herdr must be refused by the shared operation boundary; recorded:"$'\n'"$(cat "$stublog")"
  pass "fm-spawn refuses a missing or below-floor Herdr as a terminal blocker and never touches tmux"
}

test_invalid_backend_state_fails_closed() {
  run_capture busy-invalid lib_probe -- 'fm_backend_busy_state bogus target'
  assert_refusal "invalid busy-state backend" "resolves 'bogus'" "Declare Herdr explicitly"
  run_capture composer-invalid lib_probe -- 'fm_backend_composer_state bogus target'
  assert_refusal "invalid composer-state backend" "resolves 'bogus'" "Declare Herdr explicitly"
  run_capture agent-invalid lib_probe -- 'fm_backend_agent_state bogus target'
  assert_refusal "invalid agent-state backend" "resolves 'bogus'" "Declare Herdr explicitly"
  pass "invalid backend state helpers refuse instead of returning neutral values"
}

test_refusal_diagnostic_sanitizes_control_characters() {
  local hostile=$'bad\nINJECTED\r\tVALUE'
  run_capture hostile lib_probe "FM_BACKEND=$hostile" -- 'fm_backend_name'
  assert_refusal "control-character backend identity" "FM_BACKEND resolves 'bad INJECTED  VALUE'"
  case "$ERR" in
    *$'\n'*$'\n'*) fail "control-character backend identity injected an extra diagnostic line: $ERR" ;;
  esac
  pass "refusal diagnostics remain single-line when backend inputs contain controls"
}

test_remote_identity_preflight_happens_before_remote_operations() {
  local state="$TMP_ROOT/remote-state" wt="$TMP_ROOT/remote-wt" id=remotelegacy1 meta
  mkdir -p "$state" "$wt" "$TMP_ROOT/remote-home" "$TMP_ROOT/remote-data" "$TMP_ROOT/remote-config"
  fm_write_meta "$state/$id.meta" "window=remote:$id" "endpoint_task_id=$id" "worktree=$wt" "project=$wt" \
    "harness=claude" "kind=secondmate" "home=$TMP_ROOT/remote-home" "remote_host=unreachable.invalid" "remote_backend=tmux"
  meta="$state/$id.meta"
  run_capture remote-helper lib_probe -- "fm_backend_validate_remote_meta '$meta' '$id'"
  assert_refusal "remote identity helper" "remote_backend=tmux" "Legacy task records"
  run_capture remote-peek policy_env "FM_ROOT_OVERRIDE=$ROOT" "FM_HOME=$TMP_ROOT/remote-home" "FM_STATE_OVERRIDE=$state" -- \
    "$ROOT/bin/fm-peek.sh" "$id" 5
  assert_refusal "fm-peek remote legacy record" "remote_backend=tmux" "Legacy task records"
  run_capture remote-send policy_env "FM_ROOT_OVERRIDE=$ROOT" "FM_HOME=$TMP_ROOT/remote-home" "FM_STATE_OVERRIDE=$state" \
    FM_SEND_SETTLE=0 -- "$ROOT/bin/fm-send.sh" "$id" hello
  assert_refusal "fm-send remote legacy record" "remote_backend=tmux" "Legacy task records"
  run_capture remote-state policy_env "FM_ROOT_OVERRIDE=$ROOT" "FM_HOME=$TMP_ROOT/remote-home" "FM_STATE_OVERRIDE=$state" -- \
    "$ROOT/bin/fm-crew-state.sh" "$id"
  [ "$RC" -eq 0 ] || fail "fm-crew-state remote legacy record should remain a read-only view: rc=$RC err=$ERR"
  assert_contains "$OUT" "source: legacy-backend" "fm-crew-state remote legacy record"
  pass "remote task identity is validated before capture, send, or state operations"
}

# --- secondmate inheritance -------------------------------------------------

test_inherited_secondmate_backend_is_judged_by_the_same_rule() {
  local primary="$TMP_ROOT/inherit-primary/config" sm="$TMP_ROOT/inherit-sm/config" out
  mkdir -p "$primary" "$sm"
  printf 'tmux\n' > "$primary/backend"
  out=$(policy_env -- bash -c '. "$1/bin/fm-config-inherit-lib.sh"; FM_INHERITABLE_CONFIG=backend propagate_inheritable_config "$2" "$3"' _ "$ROOT" "$primary" "$sm" 2>&1) \
    || fail "propagation of config/backend should copy the primary bytes: $out"
  [ "$(cat "$sm/backend")" = tmux ] || fail "inherited config/backend should be the primary's literal bytes"
  run_capture inherit-tmux lib_probe "FM_CONFIG_OVERRIDE=$sm" -- 'fm_backend_name'
  assert_refusal "inherited config/backend=tmux in a secondmate home" "$sm/backend resolves 'tmux'"
  printf 'herdr\n' > "$primary/backend"
  policy_env -- bash -c '. "$1/bin/fm-config-inherit-lib.sh"; FM_INHERITABLE_CONFIG=backend propagate_inheritable_config "$2" "$3"' _ "$ROOT" "$primary" "$sm" >/dev/null 2>&1 \
    || fail "propagation of herdr should succeed"
  out=$(lib_probe "FM_CONFIG_OVERRIDE=$sm" -- 'fm_backend_name')
  [ "$out" = herdr ] || fail "inherited herdr should resolve, got $out"
  rm -f "$primary/backend"
  policy_env -- bash -c '. "$1/bin/fm-config-inherit-lib.sh"; FM_INHERITABLE_CONFIG=backend propagate_inheritable_config "$2" "$3"' _ "$ROOT" "$primary" "$sm" >/dev/null 2>&1 \
    || fail "propagation of an absent primary file should succeed"
  [ ! -e "$sm/backend" ] || fail "an absent primary config/backend should remove the inherited copy"
  run_capture inherit-absent lib_probe "FM_CONFIG_OVERRIDE=$sm" -- 'fm_backend_name'
  assert_refusal "secondmate home after primary removed config/backend" "declares no backend identity"
  pass "an inherited secondmate config/backend is accepted only as herdr; tmux or absence refuses in that home too"
}

# --- supervisor discovery ---------------------------------------------------

test_supervisor_discovery_has_no_tmux_default() {
  local out
  run_capture sup-tmux-env lib_probe FM_SUPERVISOR_BACKEND=tmux -- 'discover_supervisor_backend'
  assert_refusal "FM_SUPERVISOR_BACKEND=tmux" "FM_SUPERVISOR_BACKEND resolves 'tmux'" "FM_SUPERVISOR_TARGET=<herdr-session>:<pane-id>"
  run_capture sup-tmux-pane-b lib_probe TMUX_PANE=%3 TMUX=fake,1,0 -- 'discover_supervisor_backend'
  assert_refusal "TMUX_PANE only (backend)" "declares no backend identity" "never used for selection: TMUX, TMUX_PANE"
  run_capture sup-tmux-pane-t lib_probe TMUX_PANE=%3 -- 'discover_supervisor_target'
  assert_refusal "TMUX_PANE only (target)" "declares no backend identity"
  run_capture sup-nothing lib_probe -- 'discover_supervisor_target'
  assert_refusal "nothing configured (target)" "FM_SUPERVISOR_TARGET unset"
  run_capture sup-default-backend lib_probe -- 'discover_supervisor_backend'
  assert_refusal "no supervisor backend identity" "declares no backend identity"
  out=$(lib_probe HERDR_ENV=1 HERDR_PANE_ID=w1:p2 TMUX_PANE=%3 -- 'discover_supervisor_backend')
  [ "$out" = herdr ] || fail "Herdr pane identity must resolve herdr even with TMUX_PANE present, got $out"
  out=$(lib_probe HERDR_ENV=1 HERDR_PANE_ID=w1:p2 TMUX_PANE=%3 -- 'discover_supervisor_target')
  [ "$out" = default:w1:p2 ] || fail "Herdr pane identity must compose <session>:<pane>, got $out"
  out=$(lib_probe HERDR_ENV=1 HERDR_PANE_ID=w1:p2 HERDR_SESSION=fm-lab-x -- 'discover_supervisor_target')
  [ "$out" = fm-lab-x:w1:p2 ] || fail "HERDR_SESSION must scope the composed target, got $out"
  out=$(lib_probe FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET=default:w4:p1 -- 'printf "%s|%s" "$(discover_supervisor_backend)" "$(discover_supervisor_target)"')
  [ "$out" = "herdr|default:w4:p1" ] || fail "explicit herdr override must be honored, got $out"
  pass "supervisor discovery: herdr override or Herdr pane identity only; TMUX_PANE never selects and there is no firstmate:0 default"
}

test_daemon_startup_refuses_non_herdr_supervisor() {
  local state="$TMP_ROOT/daemon-state"
  mkdir -p "$state"
  run_capture daemon-tmux policy_env "FM_STATE_OVERRIDE=$state" "FM_ROOT_OVERRIDE=$ROOT" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=firstmate:0 -- \
    "$ROOT/bin/fm-supervise-daemon.sh"
  [ "$RC" -ne 0 ] || fail "the away-mode daemon must refuse a tmux supervisor backend at startup"
  assert_refusal "daemon FM_SUPERVISOR_BACKEND=tmux" "FM_SUPERVISOR_BACKEND resolves 'tmux'" "FM_SUPERVISOR_TARGET=<herdr-session>:<pane-id>"
  pass "the away-mode daemon refuses a non-Herdr supervisor backend at startup"
}

test_afk_rejects_legacy_terminal_records() {
  local state="$TMP_ROOT/afk-legacy-state" home="$TMP_ROOT/afk-legacy-home" log="$TMP_ROOT/afk-legacy.log" fb
  mkdir -p "$state" "$home"
  fb=$(make_recording_fakebin "$TMP_ROOT/afk-legacy-fake" "$log")
  printf 'tmux\tlegacy-session\t\n' > "$state/.afk-daemon-terminal"
  run_capture afk-legacy policy_env "PATH=$fb:$PATH" "FM_ROOT_OVERRIDE=$ROOT" "FM_HOME=$home" "FM_STATE_OVERRIDE=$state" -- \
    "$ROOT/bin/fm-afk-launch.sh" reconcile
  assert_refusal "AFK reconcile of a retained terminal record" "AFK daemon terminal record resolves 'tmux'" "Legacy task records"
  [ -s "$log" ] && fail "AFK legacy-record refusal must not call tmux"
  [ -f "$state/.afk-daemon-terminal" ] || fail "AFK legacy-record refusal must preserve the exact record"
  pass "AFK recovery refuses retained terminal records before adapter commands"
}

test_daemon_has_no_active_tmux_inventory_fallback() {
  local state="$TMP_ROOT/daemon-window-state" log="$TMP_ROOT/daemon-window.log" fb
  mkdir -p "$state"
  fb=$(make_recording_fakebin "$TMP_ROOT/daemon-window-fake" "$log")
  run_capture daemon-window policy_env "PATH=$fb:$PATH" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$state" -- \
    bash -c '. "$1/bin/fm-supervise-daemon.sh"; window_for_task stale-key "$2"' _ "$ROOT" "$state"
  [ "$RC" -ne 0 ] && [ -z "$OUT" ] || fail "active daemon housekeeping must not invent a tmux target: rc=$RC out=$OUT err=$ERR"
  [ -s "$log" ] && fail "active daemon housekeeping must not query tmux inventory"
  pass "daemon housekeeping has no active tmux inventory fallback"
}

# --- legacy task metadata ---------------------------------------------------

write_legacy_meta() {  # <state> <id> <worktree> [backend]
  local state=$1 id=$2 wt=$3 backend=${4:-}
  if [ -n "$backend" ]; then
    fm_write_meta "$state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=$backend"
  else
    fm_write_meta "$state/$id.meta" "window=firstmate:fm-$id" "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  fi
}

test_legacy_metadata_is_refused_read_only() {
  local state="$TMP_ROOT/legacy-state" wt="$TMP_ROOT/legacy-wt" id log="$TMP_ROOT/legacy.log" fb before after v
  mkdir -p "$state" "$wt" "$TMP_ROOT/legacy-home" "$TMP_ROOT/legacy-data" "$TMP_ROOT/legacy-config"
  fb=$(make_recording_fakebin "$TMP_ROOT/legacy-fake" "$log")
  # 1. No backend= line (a pre-invariant tmux-default record).
  id=legacyabsent
  write_legacy_meta "$state" "$id" "$wt"
  before=$(cat "$state/$id.meta")
  run_capture of-meta-absent lib_probe -- "fm_backend_of_meta '$state/$id.meta'"
  assert_refusal "fm_backend_of_meta (no backend=)" "(no backend= line) declares no backend identity" "read-only here" 'docs/configuration.md "Legacy task records"'
  run_capture resolve-absent lib_probe -- "fm_backend_resolve_selector '$id' '$state'"
  assert_refusal "fm_backend_resolve_selector (no backend=)" "(no backend= line) declares no backend identity" 'docs/configuration.md "Legacy task records"'
  run_capture endpoint-absent lib_probe -- "fm_backend_validate_task_endpoint '$state/$id.meta' '$id'"
  assert_refusal "fm_backend_validate_task_endpoint (no backend=)" "Task state is preserved"
  # 2. A retained backend recorded explicitly.
  for v in $LEGACY_NAMES; do
    write_legacy_meta "$state" "legacy$v" "$wt" "$v"
    run_capture "of-meta-$v" lib_probe -- "fm_backend_of_meta '$state/legacy$v.meta'"
    [ "$RC" -ne 0 ] || fail "fm_backend_of_meta backend=$v must refuse"
    [ -z "$OUT" ] || fail "fm_backend_of_meta refusal must not emit an accepted backend, got $OUT"
    assert_contains "$ERR" "(backend=$v) resolves '$v'" "fm_backend_of_meta backend=$v diagnostic"
    run_capture "endpoint-$v" lib_probe -- "fm_backend_validate_task_endpoint '$state/legacy$v.meta' 'legacy$v'"
    assert_refusal "fm_backend_validate_task_endpoint backend=$v" "resolves '$v'" "Task state is preserved"
  done
  run_capture resolve-tmux lib_probe -- "fm_backend_resolve_selector 'legacytmux' '$state'"
  assert_refusal "fm_backend_resolve_selector backend=tmux" "backend=tmux" 'docs/configuration.md "Legacy task records"'
  fm_write_meta "$state/legacyduplicate.meta" "window=firstmate:fm-legacyduplicate" "worktree=$wt" "project=$wt" "backend=tmux" "backend=herdr"
  run_capture duplicate-backend lib_probe -- "fm_backend_of_meta '$state/legacyduplicate.meta'"
  assert_refusal "fm_backend_of_meta duplicate backend identity" "ambiguous duplicate backend identity" 'docs/configuration.md "Legacy task records"'
  # 3. The operating scripts refuse the legacy record and leave it untouched.
  : > "$log"
  run_capture crew-state policy_env "PATH=$fb:$PATH" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$state" "FM_HOME=$TMP_ROOT/legacy-home" -- \
    "$ROOT/bin/fm-crew-state.sh" "$id"
  [ "$RC" -eq 0 ] || fail "fm-crew-state.sh must report a legacy record, not crash: rc=$RC err=$ERR"
  assert_contains "$OUT" "state: unknown" "crew-state must not claim a state for a legacy record"
  assert_contains "$OUT" "source: legacy-backend" "crew-state must attribute the verdict to the legacy record"
  assert_contains "$OUT" "backend=absent is not herdr" "crew-state must explain the legacy record"
  run_capture peek policy_env "PATH=$fb:$PATH" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$state" "FM_HOME=$TMP_ROOT/legacy-home" -- \
    "$ROOT/bin/fm-peek.sh" "$id" 5
  assert_refusal "fm-peek.sh on a legacy record" "(no backend= line)"
  run_capture send policy_env "PATH=$fb:$PATH" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$state" "FM_HOME=$TMP_ROOT/legacy-home" FM_SEND_SETTLE=0 -- \
    "$ROOT/bin/fm-send.sh" "$id" "hello"
  assert_refusal "fm-send.sh on a legacy record" "(no backend= line)"
  [ ! -e "$state/$id.inbox" ] || fail "fm-send.sh must not create a steering inbox for a refused legacy record"
  run_capture control policy_env "PATH=$fb:$PATH" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$state" "FM_HOME=$TMP_ROOT/legacy-home" -- \
    "$ROOT/bin/fm-control.sh" "$id" interrupt
  assert_refusal "fm-control.sh on a legacy record" "Task state is preserved"
  run_capture teardown policy_env "PATH=$fb:$PATH" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$state" "FM_HOME=$TMP_ROOT/legacy-home" \
    "FM_DATA_OVERRIDE=$TMP_ROOT/legacy-data" "FM_CONFIG_OVERRIDE=$TMP_ROOT/legacy-config" FM_TEARDOWN_GUARD_DONE=1 -- \
    "$ROOT/bin/fm-teardown.sh" "$id"
  assert_refusal "fm-teardown.sh on a legacy record" "Task state is preserved"
  after=$(cat "$state/$id.meta")
  [ "$before" = "$after" ] || fail "a refused legacy record must be left byte-identical"
  [ ! -s "$log" ] || fail "no operating script may call a retained adapter CLI for a legacy record; recorded:"$'\n'"$(cat "$log")"
  pass "legacy task metadata (absent or retained backend) is refused read-only by the helpers and by crew-state/peek/send/control/teardown"
}

test_herdr_record_and_endpoint_pass_every_boundary() {
  local state="$TMP_ROOT/herdr-state" wt="$TMP_ROOT/herdr-wt" id=herdrok1 out
  mkdir -p "$state" "$wt"
  fm_write_meta "$state/$id.meta" "window=default:w2:p3" "endpoint_task_id=$id" "worktree=$wt" "project=$wt" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=herdr" "herdr_session=default" \
    "herdr_workspace_id=w2" "herdr_tab_id=w2:t1" "herdr_pane_id=w2:p3"
  run_capture herdr-of-meta lib_probe -- "fm_backend_of_meta '$state/$id.meta'"
  [ "$RC" -eq 0 ] && [ "$OUT" = herdr ] && [ -z "$ERR" ] || fail "herdr record must resolve silently: rc=$RC out=$OUT err=$ERR"
  run_capture herdr-endpoint lib_probe -- "fm_backend_validate_task_endpoint '$state/$id.meta' '$id' && printf '%s|%s' \"\$FM_BACKEND_VALIDATED_BACKEND\" \"\$FM_BACKEND_VALIDATED_TARGET\""
  [ "$RC" -eq 0 ] && [ "$OUT" = "herdr|default:w2:p3" ] || fail "herdr endpoint validation failed: rc=$RC out=$OUT err=$ERR"
  out=$(lib_probe -- "fm_backend_herdr_version_check() { return 0; }; fm_backend_resolve_selector '$id' '$state'")
  [ "$out" = default:w2:p3 ] || fail "task-id selector must resolve the herdr window, got $out"
  out=$(lib_probe -- "fm_backend_herdr_version_check() { return 0; }; fm_backend_of_selector '$id' 'default:w2:p3' '$state'")
  [ "$out" = herdr ] || fail "task-id selector backend must be herdr, got $out"
  out=$(lib_probe -- 'fm_backend_herdr_version_check() { return 0; }; fm_backend_validate herdr && fm_backend_validate_spawn herdr && fm_backend_source herdr && printf ok')
  [ "$out" = ok ] || fail "herdr must pass validate, validate_spawn, and source: $out"
  out=$(lib_probe -- 'fm_backend_required_tools herdr')
  [ "$out" = "herdr jq treehouse" ] || fail "herdr required tools unchanged, got $out"
  pass "a Herdr record and a declared Herdr backend pass every selection, validation, and dispatch boundary"
}

test_bootstrap_reports_the_policy_diagnostic() {
  local home="$TMP_ROOT/bootstrap-home"
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf 'tmux\n' > "$home/config/backend"
  run_capture bootstrap policy_env "FM_HOME=$home" "FM_ROOT_OVERRIDE=$ROOT" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK_PHASE=skip -- \
    "$ROOT/bin/fm-bootstrap.sh"
  assert_contains "$OUT" "BACKEND_INVALID: none - REFUSED: $home/config/backend resolves 'tmux'" "bootstrap must surface the policy refusal as BACKEND_INVALID"
  assert_contains "$OUT" "Herdr is the sole supported Firstmate runtime backend" "bootstrap diagnostic must name Herdr"
  assert_not_contains "$OUT" "MISSING: tmux" "bootstrap must not demand tmux dependencies for a refused backend"
  pass "bootstrap surfaces a refused runtime backend as BACKEND_INVALID carrying the Herdr remediation"
}

test_known_sets_are_herdr_only
test_legacy_lane_requires_harness_identity
test_name_refuses_absent_or_empty_config
test_name_refuses_every_non_herdr_config_value
test_name_refuses_every_non_herdr_fm_backend_value
test_name_accepts_declared_herdr
test_runtime_markers_never_select
test_dispatchers_refuse_retained_adapters_without_running_them
test_selector_resolution_has_no_tmux_fallback
test_spawn_refuses_non_herdr_selection_before_side_effects
test_spawn_refuses_missing_or_incapable_herdr_without_fallback
test_invalid_backend_state_fails_closed
test_refusal_diagnostic_sanitizes_control_characters
test_remote_identity_preflight_happens_before_remote_operations
test_inherited_secondmate_backend_is_judged_by_the_same_rule
test_supervisor_discovery_has_no_tmux_default
test_daemon_startup_refuses_non_herdr_supervisor
test_afk_rejects_legacy_terminal_records
test_daemon_has_no_active_tmux_inventory_fallback
test_legacy_metadata_is_refused_read_only
test_herdr_record_and_endpoint_pass_every_boundary
test_bootstrap_reports_the_policy_diagnostic
