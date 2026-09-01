#!/usr/bin/env bash
# Behavioral coverage for the mandatory Lavish feature-intake boundary.
#
# The suite uses the public intake commands, the real captain-hold command, and
# the real process-event capture format with a stand-in Lavish executable.
# It never treats a static page, chat text, opened session, or agent summary as
# submitted evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-lavish-intake.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-feature-intake)

make_home() {
  local home=$TMP_ROOT/$1 fakebin
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/fakebin"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$home/fakebin
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = poll ]; then
  [ -n "${FM_LAVISH_FIXTURE:-}" ] && cat "$FM_LAVISH_FIXTURE"
  exit 0
fi
[ "${FM_LAVISH_FAIL_OPEN:-0}" = 1 ] && exit 1
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

run_intake() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    FM_LAVISH_FIXTURE="$home/lavish-poll.txt" \
    "$INTAKE" "$@"
}

run_brief() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$BRIEF" "$@"
}

run_process_event() {
  local home=$1 sid=$2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/claims" FM_LAVISH_FIXTURE="$home/lavish-poll.txt" \
    "$ROOT/bin/fm-procevent.sh" start "$sid"
}

add_task() {
  local home=$1 id=$2
  (cd "$home" && tasks-axi add "$id" "Feature $id" --kind ship --repo firstmate \
    --body 'feature task' >/dev/null)
}

fixture_for() {
  local home=$1 task=$2 status=${3:-feedback} shape=${4:-valid}
  if [ "$status" != feedback ]; then
    cat > "$home/lavish-poll.txt" <<EOF
session:
  file: $home/intake.html
  status: $status
  session_ended: true
EOF
    return
  fi
  if [ "$shape" = malformed ]; then
    cat > "$home/lavish-poll.txt" <<EOF
session:
  file: $home/intake.html
  status: feedback
  session_ended: true
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Feature intake submitted\\n\\nContext data:\\n{\\n  \\"question\\": \\"$task\\",\\n  \\"answer\\": \\"submitted\\",\\n  \\"close\\": \\"release\\",\\n  \\"submitted\\": true,\\n  \\"intake\\": { \\"product_goal\\": \\"goal\\" }\\n}","form",choice,"Feature intake submitted"
EOF
    return
  fi
  if [ "$shape" = extra ]; then
    cat > "$home/lavish-poll.txt" <<EOF
session:
  file: $home/intake.html
  status: feedback
  session_ended: true
prompts[2]{uid,prompt,selector,tag,text}:
  "1","Feature intake submitted\\n\\nContext data:\\n{\\n  \\"question\\": \\"$task\\",\\n  \\"answer\\": \\"submitted\\",\\n  \\"close\\": \\"release\\",\\n  \\"submitted\\": true,\\n  \\"intake\\": { \\"product_goal\\": \\"goal\\" }\\n}","form",choice,"Feature intake submitted"
  "2","Other answer\\n\\nContext data:\\n{\\n  \\"question\\": \\"other-task\\",\\n  \\"answer\\": \\"submitted\\",\\n  \\"close\\": \\"release\\",\\n  \\"submitted\\": true\\n}","form",choice,"Other answer"
EOF
    return
  fi
  cat > "$home/lavish-poll.txt" <<EOF
session:
  file: $home/intake.html
  status: feedback
  session_ended: true
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Feature intake submitted\\n\\nContext data:\\n{\\n  \\"question\\": \\"$task\\",\\n  \\"answer\\": \\"submitted\\",\\n  \\"close\\": \\"release\\",\\n  \\"submitted\\": true,\\n  \\"intake\\": { \\"product_goal\\": \\"goal\\", \\"intended_users\\": \\"users\\", \\"use_cases\\": \\"uses\\", \\"scope\\": \\"scope\\", \\"non_goals\\": \\"none\\", \\"constraints\\": \\"none\\", \\"visual_product_references\\": \\"reference\\", \\"key_choices\\": \\"choice\\", \\"acceptance_criteria\\": \\"criteria\\", \\"open_questions\\": \\"none\\" }\\n}","form",choice,"Feature intake submitted"
EOF
}

make_incomplete_artifact() {
  local output=$1 missing=$2 task=$3
  python3 - "$output" "$missing" "$task" <<'PY'
from pathlib import Path
import sys

output, missing, task = sys.argv[1:]
fields = "product_goal intended_users use_cases scope non_goals constraints visual_product_references key_choices acceptance_criteria open_questions".split()
parts = [
    '<!doctype html>',
    '<html data-lavish-intake="v1"><body>',
    f'<form data-lavish-question="{task}">',
]
for field in fields:
    if field != missing:
        parts.append(f'<textarea data-lavish-intake-field="{field}"></textarea>')
parts.extend([
    '<button data-lavish-intake-submit="true"></button>',
    '<script>window.lavish.queuePrompt("fixture");</script>',
    '</form></body></html>',
])
Path(output).write_text("\n".join(parts) + "\n")
PY
}

# Every required category appears in a real interactive intake template, and a
# static page lacking the Lavish capture call is refused before a session opens.
test_required_categories_and_static_refusal() {
  local home artifact static candidate out rc field
  home=$(make_home categories)
  add_task "$home" feature-a1
  artifact=$home/intake.html
  run_intake "$home" template feature-a1 --output "$artifact" >/dev/null
  for field in product_goal intended_users use_cases scope non_goals constraints \
    visual_product_references key_choices acceptance_criteria open_questions; do
    candidate=$home/missing-$field.html
    make_incomplete_artifact "$candidate" "$field" feature-a1
    set +e
    out=$(run_intake "$home" start feature-a1 --artifact "$candidate" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "artifact missing $field was accepted"
    assert_contains "$out" "missing required field: $field" "missing $field refusal was unclear"
  done
  static=$home/static.html
  printf '<html><body>static</body></html>\n' > "$static"
  set +e
  out=$(run_intake "$home" start feature-a1 --artifact "$static" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "static HTML started as intake"
  assert_contains "$out" "not a Lavish intake v1 surface" "static refusal did not identify missing intake surface"
  pass "Lavish intake: required categories and static artifacts are enforced"
}

# No flag is an ambiguous classification: the brief carries an explicit required
# gate, and the dispatch boundary refuses it before backend creation.
test_ambiguous_classification_refuses_dispatch() {
  local home brief out rc
  home=$(make_home ambiguous)
  run_brief "$home" ambiguous-a1 firstmate --mode no-mistakes >/dev/null
  brief=$home/data/ambiguous-a1/brief.md
  set +e
  out=$(run_intake "$home" check-brief ambiguous-a1 "$brief" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "required intake contract passed check-brief"
  assert_contains "$out" "required before implementation" "ambiguous classification refusal lacked reason"

  mkdir -p "$home/projects/proj"
  set +e
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" ambiguous-a1 "$home/projects/proj" claude --mode no-mistakes --yolo off 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dispatch accepted missing intake evidence"
  assert_contains "$out" "feature intake" "dispatch refusal did not name intake gate"
  assert_absent "$home/state/ambiguous-a1.meta" "refused dispatch wrote task metadata"
  pass "Lavish intake: ambiguous classification stops dispatch"
}

# Exemptions require a concrete reason and remain verifiable; blank reasons and
# malformed not-applicable brief contracts never pass.
test_explicit_exemptions_require_reason() {
  local home out rc brief
  home=$(make_home exemptions)
  set +e
  out=$(run_intake "$home" exempt exemption-a1 --reason '' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "empty exemption reason was accepted"
  assert_contains "$out" "must not be empty" "empty exemption refusal lacked reason"
  run_intake "$home" exempt exemption-a1 --reason 'documentation-only update' >/dev/null
  assert_contains "$(run_intake "$home" verify exemption-a1)" "not-applicable" \
    "valid exemption did not verify"
  run_brief "$home" exemption-a1 firstmate --mode no-mistakes \
    --not-applicable 'documentation-only update' >/dev/null 2>&1 && \
    fail "brief overwrote existing exemption evidence"

  run_brief "$home" exemption-b2 firstmate --mode no-mistakes \
    --not-applicable 'dependency pin update with no behavior change' >/dev/null
  brief=$home/data/exemption-b2/brief.md
  [ "$(run_intake "$home" check-brief exemption-b2 "$brief" | sed -n 's/^status=//p')" = not-applicable ] \
    || fail "valid exemption brief did not preserve its classification"
  python3 - "$brief" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "Lavish intake reason: dependency pin update with no behavior change",
    "Lavish intake reason: altered exemption reason",
)
path.write_text(text)
PY
  set +e
  out=$(run_intake "$home" check-brief exemption-b2 "$brief" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "edited exemption reason passed check-brief"
  assert_contains "$out" "does not match intake evidence" "exemption mismatch refusal was unclear"
  pass "Lavish intake: exemptions require and retain concrete reasons"
}

# A live session without submitted feedback, or a closed session carrying no
# feedback, cannot produce a receipt.
test_absent_and_closed_without_feedback_refused() {
  local home artifact sid out rc result
  home=$(make_home no-feedback)
  add_task "$home" feature-a1
  artifact=$home/intake.html
  run_intake "$home" template feature-a1 --output "$artifact" >/dev/null
  run_intake "$home" start feature-a1 --artifact "$artifact" >/dev/null
  set +e
  out=$(run_intake "$home" record feature-a1 --artifact "$artifact" \
    --result "$home/state/procevent-inbox/missing.1.result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "absent feedback result was accepted"
  assert_contains "$out" "captured result is not a regular file" "missing feedback refusal was unclear"
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" feature-a1 ended
  run_process_event "$home" "$sid" >/dev/null
  set +e
  out=$(run_intake "$home" record feature-a1 --artifact "$artifact" \
    --result "$home/state/procevent-inbox/$sid.1.result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "closed session without feedback was accepted"
  assert_contains "$out" "is not feedback" "closed-session refusal was unclear"
  pass "Lavish intake: absent and feedback-free sessions do not satisfy gate"
}

test_malformed_captured_feedback_refused() {
  local home artifact sid result out rc
  home=$(make_home malformed)
  add_task "$home" malformed-a1
  artifact=$home/intake.html
  run_intake "$home" template malformed-a1 --output "$artifact" >/dev/null
  run_intake "$home" start malformed-a1 --artifact "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" malformed-a1 feedback malformed
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  set +e
  out=$(run_intake "$home" record malformed-a1 --artifact "$artifact" --result "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "text containing intake words was accepted without structured data"
  assert_contains "$out" "complete submitted intake payload" "malformed intake refusal was unclear"
  assert_absent "$home/state/malformed-a1.lavish-intake" "malformed feedback produced intake evidence"
  pass "Lavish intake: malformed Context data cannot satisfy the evidence boundary"
}

test_missing_intake_session_fails_closed() {
  local home artifact sid result out rc
  home=$(make_home missing-session)
  add_task "$home" missing-session-a1
  artifact=$home/intake.html
  run_intake "$home" template missing-session-a1 --output "$artifact" >/dev/null
  run_intake "$home" start missing-session-a1 --artifact "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" missing-session-a1
  rm -f "$home/state/missing-session-a1.lavish-intake-session"
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" answers "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing intake session fell back to legacy answer routing"
  assert_contains "$out" "no active session" "missing-session refusal was unclear"
  (cd "$home" && tasks-axi show missing-session-a1 --full) | grep -Fq 'hold_kind: captain' \
    || fail "missing intake session released the held task"
  pass "Lavish intake: missing sessions fail closed"
}

test_intake_flag_rejects_exemption() {
  local home receipt out rc
  home=$(make_home intake-classification)
  add_task "$home" classification-a1
  run_intake "$home" exempt classification-a1 --reason 'documentation-only update' >/dev/null
  receipt=$home/state/classification-a1.lavish-intake
  set +e
  out=$(run_brief "$home" classification-a1 firstmate --mode no-mistakes --intake "$receipt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--intake accepted a not-applicable receipt"
  assert_contains "$out" "requires submitted Lavish evidence" "classification mismatch refusal was unclear"
  assert_absent "$home/data/classification-a1/brief.md" "invalid --intake classification wrote a brief"
  pass "Lavish intake: --intake accepts only submitted evidence"
}

test_contractless_compatibility_requires_existing_endpoint() {
  local home brief out rc
  home=$(make_home legacy)
  mkdir -p "$home/data/legacy-a1" "$home/projects/proj"
  printf 'legacy worker brief\n' > "$home/data/legacy-a1/brief.md"
  brief=$home/data/legacy-a1/brief.md
  set +e
  out=$(run_intake "$home" check-brief legacy-a1 "$brief" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "contractless new task passed the intake gate"
  assert_contains "$out" "no existing in-flight endpoint record" "legacy refusal was unclear"
  cat > "$home/state/legacy-a1.meta" <<EOF
endpoint_task_id=legacy-a1
kind=ship
worktree=$home/projects/proj
project=$home/projects/proj
harness=claude
EOF
  [ "$(run_intake "$home" check-brief legacy-a1 "$brief" | sed -n 's/^status=//p')" = legacy ] \
    || fail "existing in-flight endpoint did not preserve legacy compatibility"
  pass "Lavish intake: contractless compatibility is limited to existing endpoints"
}

test_start_failure_rolls_back_only_new_state() {
  local home artifact out rc
  home=$(make_home start-rollback)
  add_task "$home" rollback-a1
  artifact=$home/intake.html
  run_intake "$home" template rollback-a1 --output "$artifact" >/dev/null
  set +e
  out=$(FM_LAVISH_FAIL_OPEN=1 run_intake "$home" start rollback-a1 --artifact "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failed Lavish launch unexpectedly succeeded"
  [ "$(cd "$home" && tasks-axi show rollback-a1 --full | sed -n 's/^  state: //p')" = queued ] \
    || fail "failed Lavish launch left the task held"
  assert_absent "$home/state/rollback-a1.lavish-intake-session" "failed Lavish launch left a session marker"
  pass "Lavish intake: failed setup rolls back only state created by the attempt"
}

test_arm_failure_rolls_back_only_new_state() {
  local home artifact out rc sid
  home=$(make_home arm-rollback)
  add_task "$home" arm-rollback-a1
  artifact=$home/intake.html
  run_intake "$home" template arm-rollback-a1 --output "$artifact" >/dev/null
  printf 'not-a-directory\n' > "$home/state/procevent"
  set +e
  out=$(run_intake "$home" start arm-rollback-a1 --artifact "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failed process-event arm unexpectedly succeeded"
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  [ "$(cd "$home" && tasks-axi show arm-rollback-a1 --full | sed -n 's/^  state: //p')" = queued ] \
    || fail "failed process-event arm left the task held"
  assert_absent "$home/state/arm-rollback-a1.lavish-intake-session" "failed arm left a session marker"
  assert_absent "$home/state/decision-bindings/$sid.origin" "failed arm left a source binding"
  pass "Lavish intake: failed process-event arm rolls back partial setup"
}

# The full capture path uses the existing Lavish adapter and captain-hold keyed
# answer intake, then binds hashes and acknowledgement into durable evidence.
test_successful_captured_feedback_and_followup() {
  local home artifact sid result receipt out brief
  home=$(make_home success)
  add_task "$home" feature-a1
  artifact=$home/intake.html
  run_intake "$home" template feature-a1 --output "$artifact" >/dev/null
  run_intake "$home" start feature-a1 --artifact "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" feature-a1
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  out=$(run_intake "$home" record feature-a1 --artifact "$artifact" --result "$result")
  assert_contains "$out" "recorded:" "captured feedback did not produce evidence"
  receipt=$home/state/feature-a1.lavish-intake
  [ "$(run_intake "$home" verify feature-a1 --evidence "$receipt" | sed -n 's/^status=//p')" = submitted ] \
    || fail "captured intake did not verify as submitted"
  assert_present "$home/state/procevent-inbox/$sid.1.handled" \
    "captured feedback was not acknowledged"
  (cd "$home" && tasks-axi show feature-a1 --full) | grep -Fq 'state: queued' \
    || fail "captured intake did not release held implementation task"

  run_brief "$home" feature-a1 firstmate --mode no-mistakes --intake "$receipt" >/dev/null
  brief=$home/data/feature-a1/brief.md
  [ "$(run_intake "$home" check-brief feature-a1 "$brief" | sed -n 's/^status=//p')" = submitted ] \
    || fail "exact follow-up brief did not resolve as submitted"
  run_intake "$home" record feature-a1 --artifact "$artifact" --result "$result" >/dev/null \
    || fail "retrying recorded captured feedback was not idempotent"
  pass "Lavish intake: captured feedback releases work and supports exact follow-up"
}

test_start_rejects_unrelated_captain_hold() {
  local home artifact out rc hold_reason
  home=$(make_home unrelated-hold)
  add_task "$home" held-a1
  artifact=$home/intake.html
  run_intake "$home" template held-a1 --output "$artifact" >/dev/null
  (cd "$home" && tasks-axi hold held-a1 --kind captain --reason 'existing captain decision' >/dev/null)
  set +e
  out=$(run_intake "$home" start held-a1 --artifact "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "intake claimed an unrelated captain hold"
  assert_contains "$out" "unrelated captain hold" "unrelated hold refusal was unclear"
  hold_reason=$(cd "$home" && tasks-axi show held-a1 --full | sed -n 's/^  hold_reason: //p')
  [ "$hold_reason" = 'existing captain decision' ] || fail "unrelated captain hold was changed"
  assert_absent "$home/state/held-a1.lavish-intake-hold" "unrelated hold refusal left ownership marker"
  pass "Lavish intake: unrelated captain holds remain untouched"
}

test_extra_keyed_feedback_refused() {
  local home artifact sid result out rc
  home=$(make_home extra-key)
  add_task "$home" extra-a1
  artifact=$home/intake.html
  run_intake "$home" template extra-a1 --output "$artifact" >/dev/null
  run_intake "$home" start extra-a1 --artifact "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" extra-a1 feedback extra
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  set +e
  out=$(run_intake "$home" record extra-a1 --artifact "$artifact" --result "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "feedback with an extra keyed answer was accepted"
  assert_contains "$out" "another task" "extra keyed answer refusal was unclear"
  assert_absent "$home/state/extra-a1.lavish-intake" "extra keyed answer produced intake evidence"
  (cd "$home" && tasks-axi show extra-a1 --full) | grep -Fq 'hold_kind: captain' \
    || fail "extra keyed answer released the intake task"
  pass "Lavish intake: extra keyed answers cannot cross task boundaries"
}

# Firstmate itself receives the same mandatory gate, without changing any
# dashboard product surface.
test_firstmate_self_work_gets_same_gate() {
  local home brief rc
  home=$(make_home firstmate-self)
  run_brief "$home" firstmate-feature-a1 firstmate --mode no-mistakes >/dev/null
  brief=$home/data/firstmate-feature-a1/brief.md
  set +e
  run_intake "$home" check-brief firstmate-feature-a1 "$brief" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Firstmate work without captured intake passed the gate"
  pass "Lavish intake: Firstmate work uses same gate without dashboard changes"
}

test_required_categories_and_static_refusal
test_ambiguous_classification_refuses_dispatch
test_explicit_exemptions_require_reason
test_absent_and_closed_without_feedback_refused
test_malformed_captured_feedback_refused
test_missing_intake_session_fails_closed
test_intake_flag_rejects_exemption
test_contractless_compatibility_requires_existing_endpoint
test_start_failure_rolls_back_only_new_state
test_arm_failure_rolls_back_only_new_state
test_start_rejects_unrelated_captain_hold
test_extra_keyed_feedback_refused
test_successful_captured_feedback_and_followup
test_firstmate_self_work_gets_same_gate
printf '# all fm-lavish-feature-intake tests passed\n'
