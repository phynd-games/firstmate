#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-response-review)
trap fm_test_cleanup EXIT
assert_journal() {
  if ! grep -Eq -- "$1" "$2"; then
    fail "$3"$'\n'"journal: $(cat "$2")"$'\n'"native calls: $(cat "$FM_STATE_OVERRIDE/native-calls")"$'\n'"output: $(cat "$FM_STATE_OVERRIDE/output" 2>/dev/null)"
  fi
}

setup() {
  export FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT/$1"
  export FM_STATE_OVERRIDE="$FM_HOME/state"
  mkdir -p "$FM_STATE_OVERRIDE"
  . "$ROOT/bin/backends/herdr.sh"
  . "$ROOT/bin/fm-launch-record-lib.sh"
  launch=$(fm_launch_record intend --task response --owner tester --origin fresh) || fail 'intent failed'
  launch=${launch#*launch=}
  export FM_BACKEND_HERDR_CREATE_LAUNCH_ID=$launch FM_BACKEND_HERDR_CREATE_TASK_ID=response
  export FM_BACKEND_HERDR_CREATE_ISSUED_FILE="$FM_STATE_OVERRIDE/.response.create-issued"
  fm_launch_record journal --task response --launch "$launch" --init || fail 'journal init failed'
  WORKSPACE_RC=0 TAB_RC=0
  printf '%s\n' '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1","workspace_id":"w9"},"root_pane":{"pane_id":"w9:p1","workspace_id":"w9","tab_id":"w9:t1","terminal_id":"term-w9:p1"}}}' > "$FM_STATE_OVERRIDE/workspace-response"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w9:t2","workspace_id":"w9"}}}' > "$FM_STATE_OVERRIDE/tab-response"
  : > "$FM_STATE_OVERRIDE/native-calls"
  fm_backend_policy_refuse() { return 0; }
  fm_backend_herdr_version_check() { return 0; }
  fm_backend_herdr_server_ensure() { return 0; }
  fm_backend_herdr_session() { printf lab-response; }
  fm_backend_herdr_projection_focus_snapshot() { printf 'w0\tw0:t0'; }
  fm_backend_herdr_projection_focus_restore() { return 0; }
  fm_backend_herdr_cli() {
    printf '%s\n' "$*" >> "$FM_STATE_OVERRIDE/native-calls"
    case "$2 $3" in
      'workspace create') cat "$FM_STATE_OVERRIDE/workspace-response"; return "$WORKSPACE_RC" ;;
      'tab create') cat "$FM_STATE_OVERRIDE/tab-response"; return "$TAB_RC" ;;
      'workspace list') printf '{"result":{"type":"workspace_list","workspaces":[]}}\n' ;;
      'tab list')
        if [ -f "$FM_STATE_OVERRIDE/inventory-response" ]; then cat "$FM_STATE_OVERRIDE/inventory-response"; else printf '{"result":{"tabs":[]}}\n'; fi
        ;;
      *) return 1 ;;
    esac
  }
}

expect_refusal() {
  if "$@" > "$FM_STATE_OVERRIDE/output" 2>&1; then
    fail "incomplete or failed response allowed creation to succeed: $*"
  fi
}

for code in 0 1; do
  (
    setup "home-$code"
    WORKSPACE_RC=$code
    printf '%s\n' '{"error":{"code":"internal"},"result":{"workspace":{"workspace_id":"w9"}}}' > "$FM_STATE_OVERRIDE/workspace-response"
    expect_refusal fm_backend_herdr_workspace_ensure lab-response "$FM_HOME" other-home
    assert_journal '^partial kind=home-workspace workspace=w9$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'home workspace response axes were discarded'
    [ "$(grep -c 'workspace create' "$FM_STATE_OVERRIDE/native-calls")" = 1 ] || fail 'home create request missing'
    ! grep -q 'tab create' "$FM_STATE_OVERRIDE/native-calls" || fail 'partial home workspace allowed another allocation'
  ) || exit 1
  (
    setup "flat-$code"
    TAB_RC=$code
    expect_refusal fm_backend_herdr_create_task lab-response:w9 fm-response "$FM_HOME" ''
    assert_journal '^partial kind=task-tab workspace=w9 tab=w9:t2$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'flat tab response axes were discarded or missing axes invented'
  ) || exit 1
  (
    setup "projected-workspace-$code"
    WORKSPACE_RC=$code
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w9"},"root_pane":{"pane_id":"w9:p1","terminal_id":"term-w9:p1"}}}' > "$FM_STATE_OVERRIDE/workspace-response"
    expect_refusal fm_backend_herdr_projection_create_task "$FM_HOME" projection fm-response
    assert_journal '^partial kind=task-workspace workspace=w9 pane=w9:p1 terminal=term-w9:p1$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'projected workspace response axes were discarded'
    ! grep -q 'tab create' "$FM_STATE_OVERRIDE/native-calls" || fail 'partial projected workspace allowed another allocation'
  ) || exit 1
  (
    setup "projected-tab-$code"
    TAB_RC=$code
    expect_refusal fm_backend_herdr_projection_create_task "$FM_HOME" projection fm-response
    assert_journal '^created-workspace kind=task workspace=w9 tab=w9:t1 pane=w9:p1 terminal=term-w9:p1$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'complete projected workspace receipt changed'
    assert_journal '^partial kind=task-tab workspace=w9 tab=w9:t2$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'projected task tab response axes were discarded'
    [ "$(grep -c '^created-workspace ' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE")" = 1 ] || fail 'workspace response was recorded twice'
  ) || exit 1
  (
    setup "reclaim-$code"
    TAB_RC=$code
    fm_backend_herdr_projection_journal_snapshot() {
      FM_BACKEND_HERDR_JOURNAL_VERSION=2
      FM_BACKEND_HERDR_JOURNAL_HOME=$FM_HOME
      FM_BACKEND_HERDR_JOURNAL_SESSION=lab-response
      FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=w9
      FM_BACKEND_HERDR_JOURNAL_TAB_ID=w9:t1
      FM_BACKEND_HERDR_JOURNAL_PANE_ID=w9:p1
      FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL=firstmate
      FM_BACKEND_HERDR_JOURNAL_TASK_LABEL=fm-response
      FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=fixture
      FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID=w0
      FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL=projection
    }
    fm_backend_herdr_projection_live_binding_matches() { return 0; }
    fm_backend_herdr_pane_agent_state() { printf no-agent; }
    expect_refusal fm_backend_herdr_projection_reclaim_task lab-response unused response "$FM_HOME" w9 w9:t1 w9:p1 firstmate fm-response "$FM_HOME"
    assert_journal '^partial kind=task-tab workspace=w9 tab=w9:t2$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'reclaim response axes were discarded'
  ) || exit 1
done

(
  setup failed-complete-workspace
  WORKSPACE_RC=1
  expect_refusal fm_backend_herdr_workspace_ensure lab-response "$FM_HOME" other-home
  assert_journal '^created-workspace kind=home workspace=w9 tab=w9:t1 pane=w9:p1 terminal=term-w9:p1$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'failed command with complete workspace response lost native identities'
) || exit 1

(
  setup terminal-only
  WORKSPACE_RC=1
  printf '%s\n' '{"result":{"terminal":{"terminal_id":"term-orphan"}}}' > "$FM_STATE_OVERRIDE/workspace-response"
  expect_refusal fm_backend_herdr_workspace_ensure lab-response "$FM_HOME" other-home
  assert_journal '^partial kind=home-workspace terminal=term-orphan$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'terminal-only response identity was discarded or other axes invented'
) || exit 1

(
  setup terminal-conflict
  WORKSPACE_RC=1
  printf '%s\n' '{"result":{"workspace":{"workspace_id":"w9"},"root_pane":{"terminal_id":"term-a"},"terminal":{"terminal_id":"term-b"}}}' > "$FM_STATE_OVERRIDE/workspace-response"
  expect_refusal fm_backend_herdr_workspace_ensure lab-response "$FM_HOME" other-home
  assert_journal '^partial kind=home-workspace workspace=w9$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'conflicting returned terminal IDs must not confer a terminal identity'
) || exit 1

(
  setup malformed-conflict
  WORKSPACE_RC=1
  printf '%s\n' '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"workspace_id":"invalid workspace","tab_id":"w9:t1"}}}' > "$FM_STATE_OVERRIDE/workspace-response"
  expect_refusal fm_backend_herdr_workspace_ensure lab-response "$FM_HOME" other-home
  assert_journal '^partial kind=home-workspace tab=w9:t1$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'malformed conflicting workspace string must not select the other returned workspace'
) || exit 1

(
  setup label-only
  TAB_RC=1
  printf '%s\n' '{"error":{"code":"internal"}}' > "$FM_STATE_OVERRIDE/tab-response"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"foreign-tab","pane_id":"foreign-pane","label":"fm-response","workspace_id":"w9"}]}}' > "$FM_STATE_OVERRIDE/inventory-response"
  fm_backend_herdr_create_issue_note task-tab || fail 'issuance failed'
  fm_backend_herdr_create_answer_note task-tab "$(cat "$FM_STATE_OVERRIDE/tab-response")" lab-response fm-response w9 || fail 'error classification failed'
  assert_journal '^hint task-tab .*tab=foreign-tab pane=foreign-pane$' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" 'inventory match should remain a hint'
  ! grep -Eq '^(partial|created)' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" || fail 'inventory label falsely conferred identity'
) || exit 1

(
  setup persistence-failure
  TAB_RC=1
  printf '%s\n' '{"error":{"code":"internal"},"result":{"tab":{"tab_id":"w9:t2","workspace_id":"w9"}}}' > "$FM_STATE_OVERRIDE/tab-response"
  fm_backend_herdr_create_note() {
    case "$1" in partial*) return 1 ;; *) printf '%s\n' "$1" >> "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" ;; esac
  }
  expect_refusal fm_backend_herdr_create_task lab-response:w9 fm-response "$FM_HOME" ''
  [ "$(grep -c 'tab list' "$FM_STATE_OVERRIDE/native-calls")" = 1 ] || fail 'failed partial persistence continued to diagnostic inventory'
  [ "$(grep -c 'tab create' "$FM_STATE_OVERRIDE/native-calls")" = 1 ] || fail 'creation request missing'
) || exit 1

pass 'response identities persist before failure classification across every create path'
