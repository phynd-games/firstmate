#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fm-launch-spawn.test.sh" fixture-library

new_case reclaim-retire fx25
spawn 'sh -c true'
expect_code 0 "$SPAWN_RC" "initial metadata fixture failed: $SPAWN_OUT"
old=$(record launch.id)
workspace=$(record launch.identity.workspace_id)
oldtab=$(record launch.identity.tab_id)
oldpane=$(record launch.identity.pane_id)
in_case python3 "$OWNER" --state "$CASE_DIR/home/state" reconcile --task "$CASE_ID" --launch "$old" --verdict manual --evidence 'fixture predecessor disposed' >/dev/null
out=$(in_case bash -s -- "$CASE_ID" "$workspace" "$oldtab" "$oldpane" <<'INNER'
. "$FM_ROOT_OVERRIDE/bin/backends/herdr.sh"
. "$FM_ROOT_OVERRIDE/bin/fm-launch-record-lib.sh"
id=$1; workspace=$2; tab=$3; pane=$4
launch=$(fm_launch_record intend --task "$id" --owner tester --origin fresh)
launch=${launch#*launch=}; launch=${launch%% *}
fm_launch_record journal --task "$id" --launch "$launch" --init || exit 1
FM_BACKEND_HERDR_CREATE_LAUNCH_ID=$launch
FM_BACKEND_HERDR_CREATE_TASK_ID=$id
FM_BACKEND_HERDR_CREATE_ISSUED_FILE="$FM_STATE_OVERRIDE/.$id.create-issued"
fm_backend_herdr_projection_journal_snapshot() {
  FM_BACKEND_HERDR_JOURNAL_VERSION=2
  FM_BACKEND_HERDR_JOURNAL_HOME=$FM_HOME
  FM_BACKEND_HERDR_JOURNAL_SESSION=default
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=$workspace
  FM_BACKEND_HERDR_JOURNAL_TAB_ID=$tab
  FM_BACKEND_HERDR_JOURNAL_PANE_ID=$pane
  FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL=firstmate
  FM_BACKEND_HERDR_JOURNAL_TASK_LABEL=fm-$id
  FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=fixture
  FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID=w0
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL=child
}
fm_backend_herdr_projection_live_binding_matches() { return 0; }
fm_backend_herdr_pane_agent_state() { printf no-agent; }
fm_backend_herdr_projection_focus_snapshot() { printf 'w0\tw0:t0'; }
fm_backend_herdr_projection_focus_restore() { return 1; }
fm_backend_herdr_projection_reclaim_task default unused "$id" "$FM_HOME" "$workspace" "$tab" "$pane" firstmate "fm-$id" "$FM_FAKE_WORKTREE" && exit 1
line=$(sed -n 's/^created //p' "$FM_BACKEND_HERDR_CREATE_ISSUED_FILE" | tail -1)
[ -n "$line" ] || exit 1
args=(--identity backend=herdr --identity session=default)
for pair in $line; do
  key=${pair%%=*}; value=${pair#*=}
  case "$key" in workspace|tab|pane|terminal) args+=(--identity "${key}_id=$value");; esac
done
fm_launch_record created --task "$id" --launch "$launch" --identity-source native-response "${args[@]}" >/dev/null || exit 1
fm_launch_record fail --task "$id" --launch "$launch" --effect retained --reason 'focus restoration failed' >/dev/null
INNER
) || fail "failed-reclaim fixture failed: $out"
replacement=$(record launch.identity.pane_id)
[ "$replacement" != "$oldpane" ] || fail 'reclaim did not create a replacement'
printf '%s' "$oldpane" > "$CASE_DIR/fake/retire-old-pane"
mv "$CASE_DIR/fakebin/herdr" "$CASE_DIR/fakebin/herdr-original"
cat > "$CASE_DIR/fakebin/herdr" <<'WRAPPER'
#!/usr/bin/env bash
out=$("$(dirname "$0")/herdr-original" "$@")
rc=$?
marker="$(dirname "$FM_FAKE_HERDR_STATE")/retire-old-pane"
if [ "$rc" -eq 0 ] && [ -f "$marker" ] && [[ "$*" == *"pane get $(cat "$marker")"* ]]; then
  jq --arg pane "$(cat "$marker")" '.tabs |= map(select(.pane_id != $pane))' "$FM_FAKE_HERDR_STATE" > "$FM_FAKE_HERDR_STATE.next"
  mv "$FM_FAKE_HERDR_STATE.next" "$FM_FAKE_HERDR_STATE"
  rm "$marker"
fi
printf '%s\n' "$out"
exit "$rc"
WRAPPER
chmod +x "$CASE_DIR/fakebin/herdr"
before=$(cksum < "$CASE_DIR/home/state/$CASE_ID.launch")
out=$(in_case "$ROOT/bin/fm-teardown.sh" "$CASE_ID" --force 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'teardown retired the surviving reclaim effect'
assert_contains "$out" 'retains native effect' 'teardown must name unresolved launch effects'
[ "$(cksum < "$CASE_DIR/home/state/$CASE_ID.launch")" = "$before" ] || fail 'teardown changed the replacement obligation'
[ -f "$CASE_DIR/home/state/$CASE_ID.meta" ] || fail 'teardown removed metadata before settlement'
[ "$(fake_tabs)" -eq 1 ] || fail 'teardown touched the retained replacement'
pass 'R25: metadata endpoint absence cannot retire a surviving reclaim replacement'

new_case surviving-seed fx26
out=$(in_case bash -s -- "$CASE_ID" <<'INNER'
. "$FM_ROOT_OVERRIDE/bin/backends/herdr.sh"
. "$FM_ROOT_OVERRIDE/bin/fm-launch-record-lib.sh"
id=$1
launch=$(fm_launch_record intend --task "$id" --owner tester --origin fresh)
launch=${launch#*launch=}; launch=${launch%% *}
fm_launch_record journal --task "$id" --launch "$launch" --init || exit 1
FM_BACKEND_HERDR_CREATE_LAUNCH_ID=$launch
FM_BACKEND_HERDR_CREATE_TASK_ID=$id
FM_BACKEND_HERDR_CREATE_ISSUED_FILE="$FM_STATE_OVERRIDE/.$id.create-issued"
fm_backend_herdr_projection_focus_snapshot() { printf 'w0\tw0:t0'; }
fm_backend_herdr_projection_focus_restore() { return 0; }
fm_backend_herdr_workspace_prune_seeded_default_tab() { return 1; }
fm_backend_herdr_projection_create_task "$FM_FAKE_WORKTREE" projection "fm-$id" && exit 1
fm_launch_record created --task "$id" --launch "$launch" --identity-source native-response \
  --identity backend=herdr --identity session=default \
  --identity "workspace_id=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
  --identity "tab_id=$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
  --identity "pane_id=$FM_BACKEND_HERDR_PROJECTION_PANE_ID" \
  --identity "terminal_id=$FM_BACKEND_HERDR_PROJECTION_TERMINAL_ID" >/dev/null || exit 1
fm_launch_record fail --task "$id" --launch "$launch" --effect retained --reason 'seed cleanup refused' >/dev/null
INNER
) || fail "projected seed fixture failed: $out"
pane=$(record launch.identity.pane_id)
jq --arg pane "$pane" '.tabs |= map(select(.pane_id != $pane))' "$CASE_DIR/fake/state.json" > "$CASE_DIR/fake/next.json"
mv "$CASE_DIR/fake/next.json" "$CASE_DIR/fake/state.json"
before=$(cksum < "$CASE_DIR/home/state/$CASE_ID.launch")
: > "$CASE_DIR/fake/log"
spawn 'sh -c true'
expect_code 1 "$SPAWN_RC" "a surviving seed must block retry: $SPAWN_OUT"
assert_contains "$SPAWN_OUT" 'retains native effect' 'retry must account for the seed'
[ "$(cksum < "$CASE_DIR/home/state/$CASE_ID.launch")" = "$before" ] || fail 'retry erased the seed obligation'
fake_log | grep -q 'create' && fail 'retry created a duplicate while seed survived'
[ "$(fake_tabs)" -eq 1 ] || fail 'seed must survive refused retry'
jq '.tabs=[]' "$CASE_DIR/fake/state.json" > "$CASE_DIR/fake/next.json"
mv "$CASE_DIR/fake/next.json" "$CASE_DIR/fake/state.json"
spawn 'sh -c true'
expect_code 0 "$SPAWN_RC" "all exact effects gone must permit retry: $SPAWN_OUT"
pass 'R26: every journaled native effect must be gone before retry settlement'

new_case changed-evidence fx29
in_case bash -s -- "$CASE_ID" <<'INNER' || fail 'stale settlement evidence was accepted'
. "$FM_ROOT_OVERRIDE/bin/fm-launch-record-lib.sh"
id=$1
launch=$(fm_launch_record intend --task "$id" --owner tester --origin fresh)
launch=${launch#*launch=}; launch=${launch%% *}
fm_launch_record journal --task "$id" --launch "$launch" --init || exit 1
evidence=$(fm_launch_record effects --task "$id" --launch "$launch") || exit 1
evidence=${evidence#digest=}
fm_launch_record journal --task "$id" --launch "$launch" --line 'issued task-tab' || exit 1
fm_launch_record retire --task "$id" --launch "$launch" --effects-digest "$evidence" --reason teardown --remove && exit 1
[ "$(fm_launch_record get --task "$id" launch.phase)" = intended ]
INNER
assert_other_home_untouched effects-review
pass 'settlement refuses evidence invalidated by subsequent issuance'

for mode in home terminal; do
  new_case "partial-$mode" "fx-$mode"
  if [ "$mode" = home ]; then
    printf '%s\n' '{"error":{"code":"internal"},"result":{"workspace":{"workspace_id":"w-native"}}}' > "$CASE_DIR/fail/workspace-create"
    field=workspace_id
    value=w-native
    container=home-workspace
  else
    printf '%s\n' '{"error":{"code":"internal"},"result":{"terminal":{"terminal_id":"term-native"}}}' > "$CASE_DIR/fail/tab-create"
    field=terminal_id
    value=term-native
    container=task-tab
  fi
  spawn 'sh -c true'
  [ "$SPAWN_RC" -ne 0 ] || fail 'partial native response unexpectedly completed spawn'
  [ "$(record launch.phase)" = uncertain ] || fail "partial $mode response lost its obligation"
  [ "$(record "launch.identity.$field")" = "$value" ] || fail "partial $mode response lost its returned axis"
  [ "$(record launch.fields.container)" = "$container" ] || fail "partial $mode response mislabeled its container"
  [ -z "$(record launch.identity.pane_id)" ] || fail 'partial response invented a pane'
  before=$(record launch.id)
  : > "$CASE_DIR/fake/log"
  spawn 'sh -c true'
  [ "$SPAWN_RC" -ne 0 ] || fail 'partial response allowed blind retry'
  [ "$(record launch.id)" = "$before" ] || fail 'partial response was settled without inspection'
  fake_log | grep -q 'create' && fail 'partial response retry issued another create'
done
pass 'R8: spawn projects only returned partial axes and retains the obligation'
