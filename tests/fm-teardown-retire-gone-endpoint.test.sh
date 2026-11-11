#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh --retire-gone-endpoint.
#
# The opt-in mode retires a Herdr task whose recorded terminal is provably gone
# while Herdr itself is healthy - the shape a server restart leaves behind, where
# the recorded workspace, tab and pane ids survive but host a replacement
# terminal. The default identity checks stay untouched; this file pins both the
# new success shapes and every refusal that must keep holding.
#
# Matrix (every refusal must preserve the durable task records):
#   (a) pane id now hosts a replacement terminal         -> RETIRE, no pane close
#   (b) pane answers structured pane_not_found           -> RETIRE, no pane close
#   (c) plain teardown, same replaced-terminal fixture   -> REFUSE (default unchanged)
#   (d) pane still carries the recorded terminal         -> REFUSE
#   (e) recorded terminal lives on another pane          -> REFUSE
#   (f) same pane id under a different workspace         -> REFUSE
#   (g) malformed pane get answer                        -> REFUSE
#   (h) malformed pane list answer                       -> REFUSE
#   (i) pane list entry without a terminal id            -> REFUSE
#   (j) unlanded work without --force                    -> REFUSE
#   (k) unlanded work with --force                       -> RETIRE
#   (l) secondmate record                                -> REFUSE
#   (m) non-Herdr record                                 -> REFUSE
#   (n) recorded terminal reappears before record removal -> REFUSE, records kept
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-retire-gone-endpoint)

# Build a sandbox with a project clone, a task worktree, a Herdr-recorded meta
# (including the recorded terminal id), a seeded backlog, and a fake herdr whose
# answers are chosen per run through FM_FAKE_PANE_MODE and FM_FAKE_LIST_MODE;
# FM_FAKE_LIST_MODE_LATER replaces the list answer after the first pane list.
make_case() {  # <name> [mode] [kind]
  local name=$1 mode=${2:-no-mistakes} kind=${3:-ship} case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  printf '%s\n' herdr > "$case_dir/config/backend"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
pane_mode=\${FM_FAKE_PANE_MODE:-replaced}
list_mode=\${FM_FAKE_LIST_MODE:-clean}
if [ -n "\${FM_FAKE_LIST_MODE_LATER:-}" ] \\
  && [ "\$(grep -c '^pane list' "\$FM_FAKE_HERDR_LOG")" -gt 1 ]; then
  list_mode=\$FM_FAKE_LIST_MODE_LATER
fi
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    case "\$list_mode" in
      clean) printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ","terminal_id":"term-new"},{"pane_id":"wH:p1","tab_id":"wH:t1","terminal_id":"term-other"}]}}' ;;
      has-recorded) printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ","terminal_id":"term-new"},{"pane_id":"wH:p1","tab_id":"wH:t1","terminal_id":"term-old"}]}}' ;;
      no-terminal) printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ","terminal_id":"term-new"},{"pane_id":"wH:p1","tab_id":"wH:t1"}]}}' ;;
      garbage) printf '%s\n' 'not-json' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true,"status":"running","compatible":true,"protocol":14}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    ;;
  "pane close")
    printf 'closed\n' >> "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    case "\$pane_mode" in
      replaced) printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG","terminal_id":"term-new"}}}' ;;
      same) printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG","terminal_id":"term-old"}}}' ;;
      other-workspace) printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wH","terminal_id":"term-new"}}}' ;;
      gone) printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2; exit 1 ;;
      garbage) printf '%s\n' 'not-json' ;;
    esac
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/treehouse" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes" "$fakebin/herdr"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  : > "$case_dir/herdr.log"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=default:wG:pQ" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=retire-gone-test-task-x1" \
    "backend=herdr" \
    "herdr_session=default" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:tQ" \
    "herdr_pane_id=wG:pQ" \
    "herdr_terminal_id=term-old"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"

  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "retire fixture task" --kind "$kind" \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null

  printf '%s\n' "$case_dir"
}

# run_teardown <case-dir> [fm-teardown args...]; the fake herdr is steered by
# FM_FAKE_PANE_MODE / FM_FAKE_LIST_MODE exported by the caller.
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_HERDR_LOG="$case_dir/herdr.log" \
  FM_FAKE_HERDR_CLOSED="$case_dir/closed.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
}

backlog_row_state() {
  tasks-axi show task-x1 --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

assert_retired() {  # <label> <case-dir>
  local label=$1 case_dir=$2
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "$label: the task metadata survived the retire"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "$label: the task status record survived the retire"
  [ ! -e "$case_dir/state/task-x1.turn-ended" ] || fail "$label: the turn-end record survived the retire"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "$label: the backlog item was not closed (state: $(backlog_row_state "$case_dir"))"
  [ ! -e "$case_dir/closed.log" ] || fail "$label: a pane close was issued for a terminal that is not the task's"
  if grep -q '^pane close' "$case_dir/herdr.log"; then
    fail "$label: herdr received a pane close"
  fi
  grep -q "teardown task-x1 complete" "$case_dir/stdout" \
    || fail "$label: completion was not reported: $(cat "$case_dir/stdout")"
}

assert_refused_and_preserved() {  # <label> <case-dir> <stderr-pattern>
  local label=$1 case_dir=$2 pattern=$3
  grep -q "^REFUSED: \|^error: " "$case_dir/stderr" \
    || fail "$label: the refusal was not explained: $(cat "$case_dir/stderr")"
  grep -Eq "$pattern" "$case_dir/stderr" \
    || fail "$label: the refusal did not name the cause ($pattern): $(cat "$case_dir/stderr")"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: the refusal erased the task metadata"
  [ -e "$case_dir/state/task-x1.status" ] || fail "$label: the refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] || fail "$label: the refusal erased the turn-end record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "$label: the refusal changed the backlog item (state: $(backlog_row_state "$case_dir"))"
  [ -d "$case_dir/wt" ] || fail "$label: the refusal removed the isolated copy"
  [ ! -e "$case_dir/closed.log" ] || fail "$label: the refusal still closed a pane"
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    fail "$label: the refusal still reported cleanup complete"
  fi
}

test_replaced_terminal_is_retired_without_closing_any_pane() {
  local case_dir
  case_dir=$(make_case replaced)
  FM_FAKE_PANE_MODE=replaced FM_FAKE_LIST_MODE=clean \
    run_teardown "$case_dir" --retire-gone-endpoint \
    || fail "replaced: the retire failed: $(cat "$case_dir/stderr")"
  assert_retired replaced "$case_dir"
  pass "a pane id that now hosts a replacement terminal retires without closing it"
}

test_pane_not_found_is_retired() {
  local case_dir
  case_dir=$(make_case gone)
  FM_FAKE_PANE_MODE=gone FM_FAKE_LIST_MODE=clean \
    run_teardown "$case_dir" --retire-gone-endpoint \
    || fail "gone: the retire failed: $(cat "$case_dir/stderr")"
  assert_retired gone "$case_dir"
  pass "a structurally missing pane retires when no pane carries the recorded terminal"
}

test_plain_teardown_still_refuses_a_replaced_terminal() {
  local case_dir rc=0
  case_dir=$(make_case default-refuses)
  FM_FAKE_PANE_MODE=replaced FM_FAKE_LIST_MODE=clean \
    run_teardown "$case_dir" --force || rc=$?
  [ "$rc" -ne 0 ] || fail "default-refuses: plain teardown accepted a replaced terminal"
  assert_refused_and_preserved default-refuses "$case_dir" "identity"
  pass "plain teardown without the flag still refuses a replaced terminal"
}

test_refusal_matrix_preserves_records() {
  local label pane_mode list_mode pattern case_dir rc
  # label|pane mode|list mode|stderr pattern
  while IFS='|' read -r label pane_mode list_mode pattern; do
    case_dir=$(make_case "refuse-$label")
    rc=0
    FM_FAKE_PANE_MODE=$pane_mode FM_FAKE_LIST_MODE=$list_mode \
      run_teardown "$case_dir" --retire-gone-endpoint || rc=$?
    [ "$rc" -ne 0 ] || fail "refuse-$label: the retire succeeded"
    assert_refused_and_preserved "refuse-$label" "$case_dir" "$pattern"
  done <<'EOF'
still-present|same|clean|still has its recorded Herdr terminal
elsewhere|replaced|has-recorded|still has its recorded Herdr terminal
other-workspace|other-workspace|clean|pane identity check failed
garbage-get|garbage|clean|pane identity check failed
garbage-list|replaced|garbage|could not be proven gone
list-no-terminal|replaced|no-terminal|could not be proven gone
EOF
  pass "every unproven or contradicting terminal shape refuses and preserves the records"
}

test_unlanded_work_refuses_without_force_and_retires_with_it() {
  local case_dir rc=0
  case_dir=$(make_case unlanded local-only)
  git -C "$case_dir/wt" commit -q --allow-empty -m "unpushed work"
  FM_FAKE_PANE_MODE=replaced FM_FAKE_LIST_MODE=clean \
    run_teardown "$case_dir" --retire-gone-endpoint || rc=$?
  [ "$rc" -ne 0 ] || fail "unlanded: the retire discarded unlanded work without --force"
  assert_refused_and_preserved unlanded "$case_dir" "unlanded|not landed|REFUSED"

  FM_FAKE_PANE_MODE=replaced FM_FAKE_LIST_MODE=clean \
    run_teardown "$case_dir" --force --retire-gone-endpoint \
    || fail "unlanded: --force --retire-gone-endpoint failed: $(cat "$case_dir/stderr")"
  assert_retired unlanded-forced "$case_dir"
  pass "unlanded work refuses without --force and retires with it"
}

test_secondmate_record_refuses() {
  local case_dir rc=0
  case_dir=$(make_case secondmate no-mistakes secondmate)
  FM_FAKE_PANE_MODE=replaced FM_FAKE_LIST_MODE=clean \
    run_teardown "$case_dir" --retire-gone-endpoint || rc=$?
  [ "$rc" -ne 0 ] || fail "secondmate: the retire accepted a secondmate"
  grep -q "does not apply to secondmate" "$case_dir/stderr" \
    || fail "secondmate: the refusal did not explain itself: $(cat "$case_dir/stderr")"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "secondmate: the refusal erased the metadata"
  pass "a secondmate record refuses the retire"
}

test_non_herdr_record_refuses() {
  local case_dir rc=0
  case_dir=$(make_case non-herdr)
  sed -i.bak 's/^backend=.*/backend=tmux/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  FM_FAKE_PANE_MODE=replaced FM_FAKE_LIST_MODE=clean \
    run_teardown "$case_dir" --retire-gone-endpoint || rc=$?
  [ "$rc" -ne 0 ] || fail "non-herdr: the retire accepted a non-Herdr record"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "non-herdr: the refusal erased the metadata"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] || fail "non-herdr: the refusal closed the backlog item"
  pass "a non-Herdr record refuses the retire"
}

test_second_proof_refusal_keeps_durable_records() {
  local case_dir rc=0
  case_dir=$(make_case second-proof)
  FM_FAKE_PANE_MODE=replaced FM_FAKE_LIST_MODE=clean FM_FAKE_LIST_MODE_LATER=has-recorded \
    run_teardown "$case_dir" --retire-gone-endpoint || rc=$?
  [ "$rc" -ne 0 ] || fail "second-proof: the retire succeeded after the recorded terminal reappeared"
  [ "$(grep -c '^pane list' "$case_dir/herdr.log")" -ge 2 ] \
    || fail "second-proof: the proof was not repeated before record removal"
  grep -q "before record removal" "$case_dir/stderr" \
    || fail "second-proof: the refusal did not come from the second proof: $(cat "$case_dir/stderr")"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "second-proof: the refusal erased the task metadata"
  [ -e "$case_dir/state/task-x1.status" ] || fail "second-proof: the refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] || fail "second-proof: the refusal erased the turn-end record"
  [ ! -e "$case_dir/closed.log" ] || fail "second-proof: the refusal still closed a pane"
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    fail "second-proof: the refusal still reported cleanup complete"
  fi
  pass "a terminal that reappears before record removal refuses and keeps the durable records"
}

test_replaced_terminal_is_retired_without_closing_any_pane
test_pane_not_found_is_retired
test_plain_teardown_still_refuses_a_replaced_terminal
test_refusal_matrix_preserves_records
test_unlanded_work_refuses_without_force_and_retires_with_it
test_secondmate_record_refuses
test_non_herdr_record_refuses
test_second_proof_refusal_keeps_durable_records
