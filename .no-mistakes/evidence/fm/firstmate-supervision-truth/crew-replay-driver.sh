#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# semantic busy-state contract) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (f) no run + semantic busy                                    -> pane
#   (g) no run + semantic idle falls to the status-log verb       -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
#       This is the direct regression pair for the 2026-07-02 herdr incident,
#       proving the watcher's own absorb-only-when-provably-working predicate
#       benefits from the fix in both directions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS
}


replay_captured_input() {
  reset_fakes
  local d outcome scalar expected out
  d=$(new_case terminal-severity-summaries)
  make_repo_on_branch "$d/wt" fm/severity-summary
  make_fakebin "$d" >/dev/null
  # Exercise the native endpoint preflight against an isolated CLI fixture.
  cat > "$d/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'status --json')
    printf '%s\n' '{"client":{"version":"0.8.2","protocol":16},"server":{"running":true,"status":"running","compatible":true,"protocol":16}}' ;;
  'session list')
    printf '%s\n' '{"sessions":[{"name":"severity-test","running":true}]}' ;;
  'pane get')
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_id":"term1"}}}' ;;
  'pane read') [ "${FM_REPLAY_PANE_UNREAD:-0}" != 1 ] || exit 1; printf 'synthetic busy pane\n' ;;
  *) exit 1 ;;
esac
SH
  fm_write_meta "$d/state/severity.meta" "window=severity-test:w1:p1" \
    "worktree=$d/wt" "project=$d/wt" "kind=ship" "backend=herdr" \
    "harness=claude" "endpoint_task_id=severity" "herdr_session=severity-test" \
    "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" "herdr_terminal_id=term1"

  local gen version result export_file expected fixture_head scenario
  fixture_head=$FM_FAKE_RUN_HEAD
  printf 'synthetic task=severity branch=fm/severity-summary head=%s\n' "$fixture_head"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" severity)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" severity busy --gen "$gen" --source claude-hook --event user-prompt-submit
  printf 'working: synthetic old progress\n' > "$d/state/severity.status"
  for scenario in captured-foreign synthetic-bound-passed synthetic-bound-failed malformed unknown-no-record unread-pane; do
    FM_FAKE_AXI_STATUS=$(cat "$REPLAY_EVIDENCE/frozen-findings-inputs/historical-capture.toon")
    case "$scenario" in
      synthetic-bound-*)
        FM_FAKE_AXI_STATUS="run:
  id: \"01M1SKRKCG5BVV9H1CYRR3HW4S\"
  branch: fm/severity-summary
  status: completed
  head: \"$fixture_head\"
  pr: \"\"
  findings: 4 info
outcome: ${scenario#synthetic-bound-}" ;;
      malformed) FM_FAKE_AXI_STATUS=${FM_FAKE_AXI_STATUS/4 info/1 unknown} ;;
      unknown-no-record)
        FM_FAKE_AXI_STATUS=''
        # Explicit unknown semantic state must not reuse the old progress log.
        "$ROOT/bin/fm-busy-event.sh" arm "$d/state" severity --state unknown >/dev/null ;;
      unread-pane)
        FM_FAKE_AXI_STATUS=''
        export FM_REPLAY_PANE_UNREAD=1 ;;
    esac
    printf '%s\n' "$FM_FAKE_AXI_STATUS" > "$REPLAY_EVIDENCE/crew-replay-${scenario}.toon"
    for version in base head; do
      CREW_STATE="$REPLAY_SCRATCH/$version/bin/fm-crew-state.sh"
      export_file="$d/export-$scenario-$version"
      out=$(FM_CREW_STATE_EVIDENCE_FILE="$export_file" run_crew_state "$d" severity)
      printf '%s %s: %s\n' "$scenario" "$version" "$out"
      expected='state: unknown'
      if [ "$version" = head ]; then
        case "$scenario" in
          captured-foreign) expected='state: working' ;;
          synthetic-bound-passed) expected='state: done' ;;
          synthetic-bound-failed) expected='state: failed' ;;
        esac
      fi
      assert_contains "$out" "$expected" "$scenario $version state"
      case "$scenario:$version" in
        captured-foreign:head)
          assert_contains "$out" 'source: pane' 'foreign capture cannot own the task'
          [ ! -s "$export_file" ] || fail 'foreign evidence was exported as task evidence' ;;
        synthetic-bound-*:head)
          assert_contains "$out" 'source: run-step' 'constructed matching branch/head binds the run'
          cmp "$export_file" "$REPLAY_EVIDENCE/crew-replay-${scenario}.toon" || fail 'attributed evidence export changed the frozen run'
          cp "$export_file" "$REPLAY_EVIDENCE/crew-export-${scenario}.toon" ;;
        *) assert_not_contains "$out" 'source: status-log' 'old progress cannot override unknown evidence' ;;
      esac
    done
  done
  pass 'identical captured and constructed inputs preserve crew/run attribution and unknown negatives'
}
replay_captured_input
