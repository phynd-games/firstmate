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
    "$INTAKE" "$@"
}

run_brief() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$BRIEF" "$@"
}

add_task() {
  local home=$1 id=$2
  (cd "$home" && tasks-axi add "$id" "Feature $id" --kind ship --repo firstmate \
    --body 'feature task' >/dev/null)
}

result_for() {
  local home=$1 sid=$2 status=${3:-feedback}
  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/$sid.1.result" <<EOF
session:
  file: /intake.html
  status: $status
  session_ended: true
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Feature intake submitted\n\nContext data:\n{\n  \"question\": \"feature-a1\",\n  \"answer\": \"submitted\",\n  \"close\": \"release\",\n  \"submitted\": true,\n  \"intake\": { \"product_goal\": \"goal\", \"intended_users\": \"users\", \"use_cases\": \"uses\", \"scope\": \"scope\", \"non_goals\": \"none\", \"constraints\": \"none\", \"visual_product_references\": \"reference\", \"key_choices\": \"choice\", \"acceptance_criteria\": \"criteria\", \"open_questions\": \"none\" }\n}","form",choice,"Feature intake submitted"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"
}

# Every required category appears in a real interactive intake template, and a
# static page lacking the Lavish capture call is refused before a session opens.
test_required_categories_and_static_refusal() {
  local home artifact static out rc field
  home=$(make_home categories)
  add_task "$home" feature-a1
  artifact=$home/intake.html
  run_intake "$home" template feature-a1 --output "$artifact" >/dev/null
  for field in product_goal intended_users use_cases scope non_goals constraints \
    visual_product_references key_choices acceptance_criteria open_questions; do
    grep -Fq "data-lavish-intake-field=\"$field\"" "$artifact" \
      || fail "template omitted required field $field"
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
  assert_grep 'Lavish intake contract: required' "$brief" \
    "ambiguous brief did not carry an explicit required contract"
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
  assert_grep 'Lavish intake contract: not-applicable' "$brief" \
    "brief omitted explicit exemption contract"
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
  result_for "$home" "$sid" ended
  set +e
  out=$(run_intake "$home" record feature-a1 --artifact "$artifact" \
    --result "$home/state/procevent-inbox/$sid.1.result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "closed session without feedback was accepted"
  assert_contains "$out" "is not feedback" "closed-session refusal was unclear"
  pass "Lavish intake: absent and feedback-free sessions do not satisfy gate"
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
  result_for "$home" "$sid"
  result=$home/state/procevent-inbox/$sid.1.result
  out=$(run_intake "$home" record feature-a1 --artifact "$artifact" --result "$result")
  assert_contains "$out" "recorded:" "captured feedback did not produce evidence"
  receipt=$home/state/feature-a1.lavish-intake
  run_intake "$home" verify feature-a1 --evidence "$receipt" >/dev/null
  assert_present "$home/state/procevent-inbox/$sid.1.handled" \
    "captured feedback was not acknowledged"
  (cd "$home" && tasks-axi show feature-a1 --full) | grep -Fq 'state: queued' \
    || fail "captured intake did not release held implementation task"

  run_brief "$home" feature-a1 firstmate --mode no-mistakes --intake "$receipt" >/dev/null
  brief=$home/data/feature-a1/brief.md
  assert_grep 'Lavish intake contract: submitted' "$brief" \
    "exact follow-up brief omitted submitted contract"
  assert_grep 'Lavish intake evidence: ' "$brief" \
    "exact follow-up brief omitted evidence path"
  pass "Lavish intake: captured feedback releases work and supports exact follow-up"
}

# Firstmate itself receives the same mandatory gate, without changing any
# dashboard product surface.
test_firstmate_self_work_gets_same_gate() {
  local home brief
  home=$(make_home firstmate-self)
  run_brief "$home" firstmate-feature-a1 firstmate --mode no-mistakes >/dev/null
  brief=$home/data/firstmate-feature-a1/brief.md
  assert_grep 'Lavish intake contract: required' "$brief" \
    "Firstmate work omitted mandatory intake gate"
  assert_grep 'lavish-feature-intake' "$brief" \
    "Firstmate instructions omitted policy owner"
  pass "Lavish intake: Firstmate work uses same gate without dashboard changes"
}

test_required_categories_and_static_refusal
test_ambiguous_classification_refuses_dispatch
test_explicit_exemptions_require_reason
test_absent_and_closed_without_feedback_refused
test_successful_captured_feedback_and_followup
test_firstmate_self_work_gets_same_gate
printf '# all fm-lavish-feature-intake tests passed\n'
