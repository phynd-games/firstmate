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
if [ "${1:-}" = end ]; then
  printf '%s\n' "$*" >> "${FM_LAVISH_CALLS:?FM_LAVISH_CALLS unset}"
  [ "${FM_LAVISH_FAIL_END:-0}" = 1 ] && exit 1
  exit 0
fi
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
    FM_LAVISH_CALLS="$home/lavish.calls" \
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
  local home=$1 task=$2 status=${3:-feedback} shape=${4:-valid} block=prompts
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
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Feature intake submitted\\n\\nContext data:\\n{\\n  \\"question\\": \\"$task\\",\\n  \\"answer\\": \\"submitted\\",\\n  \\"close\\": \\"release\\",\\n  \\"submitted\\": true,\\n  \\"intake\\": { \\"product_goal\\": \\"goal\\" }\\n}","form",choice,"Feature intake submitted"
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Other answer\\n\\nContext data:\\n{\\n  \\"question\\": \\"other-task\\",\\n  \\"answer\\": \\"submitted\\",\\n  \\"close\\": \\"release\\",\\n  \\"submitted\\": true\\n}","form",choice,"Other answer"
EOF
    return
  fi
  [ "$shape" = feedback-block ] && block=feedback
  cat > "$home/lavish-poll.txt" <<EOF
session:
  file: $home/intake.html
  status: feedback
  session_ended: true
${block}[1]{uid,prompt,selector,tag,text}:
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
    f'<form id="feature-intake" data-lavish-question="{task}">',
]
for field in fields:
    if field != missing:
        parts.append(f'<textarea name="{field}" data-lavish-intake-field="{field}" required></textarea>')
parts.extend([
    '<button type="submit" data-lavish-intake-submit="true"></button>',
    '<script>window.lavish.queuePrompt("fixture");</script>',
    '</form></body></html>',
])
Path(output).write_text("\n".join(parts) + "\n")
PY
}

# Every required category appears in a real interactive intake template, and a
# static page lacking the Lavish capture call is refused before a session opens.
test_required_categories_and_static_refusal() {
  local home artifact static candidate inert out rc field
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
  candidate=$home/dead-markers.html
  python3 - "$candidate" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
fields = "product_goal intended_users use_cases scope non_goals constraints visual_product_references key_choices acceptance_criteria open_questions".split()
parts = [
    '<html data-lavish-intake="v1"><body>',
    '<!-- data-lavish-intake-submit="true" window.lavish.queuePrompt -->',
    '<form id="feature-intake" data-lavish-question="feature-a1">',
]
for field in fields:
    parts.append(f'<textarea name="{field}" data-lavish-intake-field="{field}" required></textarea>')
parts.extend([
    '<button type="submit" data-lavish-intake-submit="true">Submit</button>',
    '<script>const unused = "form.addEventListener submit event.preventDefault window.lavish.queuePrompt data: {";</script>',
    '</form></body></html>',
])
output.write_text("\n".join(parts) + "\n")
PY
  set +e
  out=$(run_intake "$home" start feature-a1 --artifact "$candidate" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dead intake markers were accepted"
  assert_contains "$out" "executable intake" \
    "dead intake markers did not fail semantic validation"
  candidate=$home/script-string-form.html
  python3 - "$artifact" "$candidate" <<'PY'
from pathlib import Path
import json
import sys

source, output = sys.argv[1:]
html = Path(source).read_text()
start = html.index('<form id="feature-intake"')
end = html.index('</form>', start) + len('</form>')
form = html[start:end]
fake = '<script>const unused = ' + json.dumps(form) + ';</script>'
Path(output).write_text(html[:start] + fake + html[end:])
PY
  set +e
  out=$(run_intake "$home" start feature-a1 --artifact "$candidate" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "form markup inside a script string was accepted"
  assert_contains "$out" "no keyed intake question" \
    "script-string form markup was treated as an active DOM form"
  for inert in template noscript; do
    candidate=$home/inert-$inert-form.html
    python3 - "$artifact" "$candidate" "$inert" <<'PY'
from pathlib import Path
import sys

source, output, mode = sys.argv[1:]
html = Path(source).read_text()
start = html.index('<form id="feature-intake"')
end = html.index('</form>', start) + len('</form>')
html = html[:start] + f'<{mode}>' + html[start:end] + f'</{mode}>' + html[end:]
Path(output).write_text(html)
PY
    set +e
    out=$(run_intake "$home" start feature-a1 --artifact "$candidate" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "inert $inert intake form was accepted"
    assert_contains "$out" "no keyed intake question" \
      "inert $inert form refusal was unclear"
  done
  for inert in text-plain template; do
    candidate=$home/inert-$inert.html
    python3 - "$artifact" "$candidate" "$inert" <<'PY'
from pathlib import Path
import sys

source, output, mode = sys.argv[1:]
html = Path(source).read_text()
if mode == "text-plain":
    html = html.replace("<script>", '<script type="text/plain">', 1)
else:
    start = html.index("<script>")
    end = html.index("</script>", start) + len("</script>")
    html = html[:start] + "<template>" + html[start:end] + "</template>" + html[end:]
Path(output).write_text(html)
PY
    set +e
    out=$(run_intake "$home" start feature-a1 --artifact "$candidate" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "inert $inert intake script was executed"
    assert_contains "$out" "no executable intake script" \
      "inert $inert script refusal was unclear"
  done
  pass "Lavish intake: required categories and static artifacts are enforced"
}

test_artifact_must_read_submitted_fields() {
  local home artifact out rc
  home=$(make_home hardcoded-fields)
  add_task "$home" hardcoded-a1
  artifact=$home/intake.html
  run_intake "$home" template hardcoded-a1 --output "$artifact" >/dev/null
  python3 - "$artifact" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('form.elements[field].value.trim()', '"hardcoded intake value"')
path.write_text(text)
PY
  set +e
  out=$(run_intake "$home" start hardcoded-a1 --artifact "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "artifact with hardcoded intake values was accepted"
  assert_contains "$out" "does not reflect submitted field values" \
    "hardcoded intake values did not fail semantic validation"
  pass "Lavish intake: submission handlers must read each field"
}

test_template_submit_is_single_use() {
  local home artifact
  home=$(make_home submit-once)
  artifact=$home/intake.html
  run_intake "$home" template submit-once-a1 --output "$artifact" >/dev/null
  node - "$artifact" <<'NODE'
const fs = require("fs");
const vm = require("vm");
const html = fs.readFileSync(process.argv[2], "utf8");
const script = html.match(/<script>\n([\s\S]*?)\n<\/script>/)[1];
const fields = "product_goal intended_users use_cases scope non_goals constraints visual_product_references key_choices acceptance_criteria open_questions".split(" ");
let handler;
let calls = 0;
const button = { disabled: false };
const form = {
  elements: Object.fromEntries(fields.map((field) => [field, { value: "filled" }])),
  querySelector: () => button,
  addEventListener: (event, callback) => { if (event === "submit") handler = callback; },
};
const status = {};
vm.runInNewContext(script, {
  document: { querySelector: (selector) => selector === "#feature-intake" ? form : status },
  window: { lavish: { queuePrompt: () => { calls += 1; } } },
});
  handler({ preventDefault() {} });
  if (!button.disabled) throw new Error("submit control stayed enabled");
  handler({ preventDefault() {} });
  if (calls !== 1) throw new Error(`queued ${calls} submissions`);
NODE
  pass "Lavish intake: submit control queues only one answer"
}

test_start_rejects_closed_task() {
  local home artifact out rc
  home=$(make_home closed-task)
  add_task "$home" closed-a1
  (cd "$home" && tasks-axi done closed-a1 >/dev/null)
  artifact=$home/intake.html
  run_intake "$home" template closed-a1 --output "$artifact" >/dev/null
  set +e
  out=$(run_intake "$home" start closed-a1 --artifact "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "closed task opened an intake session"
  assert_contains "$out" "already closed" "closed-task refusal was unclear"
  assert_absent "$home/lavish.calls" "closed task opened an external Lavish session"
  pass "Lavish intake: closed tasks cannot start external setup"
}

test_artifact_task_mismatch_refused() {
  local home artifact out rc
  home=$(make_home artifact-mismatch)
  add_task "$home" artifact-a1
  artifact=$home/other.html
  run_intake "$home" template artifact-b2 --output "$artifact" >/dev/null
  set +e
  out=$(run_intake "$home" start artifact-a1 --artifact "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "artifact for another task started an intake"
  assert_contains "$out" "no keyed intake question" "artifact mismatch refusal was unclear"
  assert_absent "$home/lavish.calls" "artifact mismatch opened an external Lavish session"
  pass "Lavish intake: artifacts are bound to their exact task"
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
  local home out rc brief entry id reason
  local -a invalid_reasons
  home=$(make_home exemptions)
  set +e
  out=$(run_intake "$home" exempt exemption-a1 --reason '' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "empty exemption reason was accepted"
  assert_contains "$out" "must not be empty" "empty exemption refusal lacked reason"
  set +e
  out=$(run_intake "$home" exempt exemption-skip --reason 'skip' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "generic exemption bypass was accepted"
  assert_contains "$out" "must use" "generic exemption refusal was unclear"
  invalid_reasons=(
    'exemption-invalid-bug-fix|bug-fix: task=exemption-invalid-bug-fix; target=tests/fm-lavish-feature-intake.test.sh; action=fix'
    'exemption-invalid-vague-bug-fix|bug-fix: task=exemption-invalid-vague-bug-fix; target=tests/fm-lavish-feature-intake.test.sh; action=fix the broken code in this project'
    'exemption-invalid-configuration|configuration: task=exemption-invalid-configuration; target=tests/fm-lavish-feature-intake.test.sh; action=no'
    'exemption-invalid-documentation|documentation: task=exemption-invalid-documentation; target=tests/fm-lavish-feature-intake.test.sh; action=update thing here now'
    'exemption-invalid-placeholders|configuration: task=exemption-invalid-placeholders; target=foo bar; action=update now safely'
    'exemption-invalid-generic-target|configuration: task=exemption-invalid-generic-target; target=backend behavior; action=update source'
    'exemption-invalid-generic-action|documentation: task=exemption-invalid-generic-action; target=docs/api README section; action=update the docs'
    'exemption-invalid-vague-action|configuration: task=exemption-invalid-vague-action; target=src/parser/handler.ts behavior; action=adjust implementation details'
    'exemption-invalid-task|configuration: task=other-task; target=tests/fm-lavish-feature-intake.test.sh scope; action=exercise task binding behavior'
  )
  for entry in "${invalid_reasons[@]}"; do
    id=${entry%%|*}
    reason=${entry#*|}
    set +e
    out=$(run_intake "$home" exempt "$id" --reason "$reason" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "generic exemption scope was accepted: $reason"
  done
  run_intake "$home" exempt exemption-a1 --reason 'documentation: task=exemption-a1; target=tests/fm-lavish-feature-intake.test.sh exemption coverage; action=update coverage instructions' >/dev/null
  assert_contains "$(run_intake "$home" verify exemption-a1)" "not-applicable" \
    "valid exemption did not verify"
  run_brief "$home" exemption-a1 firstmate --mode no-mistakes \
    --not-applicable 'documentation: task=exemption-a1; target=tests/fm-lavish-feature-intake.test.sh exemption coverage; action=update coverage instructions' >/dev/null
  assert_present "$home/data/exemption-a1/brief.md" \
    "same-reason exemption retry did not converge on a brief"

  run_brief "$home" exemption-b2 firstmate --mode no-mistakes \
    --not-applicable 'dependency: task=exemption-b2; target=.tasks.toml test dependency; action=pin dependency version without behavior change' >/dev/null
  brief=$home/data/exemption-b2/brief.md
  [ "$(run_intake "$home" check-brief exemption-b2 "$brief" | sed -n 's/^status=//p')" = not-applicable ] \
    || fail "valid exemption brief did not preserve its classification"
  python3 - "$brief" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "Lavish intake reason: dependency: task=exemption-b2; target=.tasks.toml test dependency; action=pin dependency version without behavior change",
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

test_brief_exemption_stages_before_receipt() {
  local home out rc reason
  home=$(make_home staged-exemption)
  reason='configuration: task=staged-a1; target=tests/fm-lavish-feature-intake.test.sh brief staging fixture; action=exercise retry behavior without product change'
  printf 'not a directory\n' > "$home/data/staged-a1"
  set +e
  out=$(run_brief "$home" staged-a1 firstmate --mode no-mistakes \
    --not-applicable "$reason" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "brief staging failure unexpectedly succeeded"
  assert_absent "$home/state/staged-a1.lavish-intake" \
    "brief staging failure published exemption evidence"
  rm -f "$home/data/staged-a1"
  run_brief "$home" staged-a1 firstmate --mode no-mistakes \
    --not-applicable "$reason" >/dev/null
  assert_present "$home/data/staged-a1/brief.md" \
    "brief retry did not publish the staged brief"
  assert_contains "$(run_intake "$home" verify staged-a1)" "not-applicable" \
    "brief retry did not publish resumable exemption evidence"
  pass "Lavish intake: exemption publication follows resumable brief staging"
}

test_exemption_rejects_active_intake() {
  local home artifact out rc
  home=$(make_home active-exemption)
  add_task "$home" active-a1
  artifact=$home/intake.html
  run_intake "$home" template active-a1 --output "$artifact" >/dev/null
  run_intake "$home" start active-a1 --artifact "$artifact" >/dev/null
  set +e
  out=$(run_intake "$home" exempt active-a1 \
    --reason 'documentation: task=active-a1; target=bin/fm-lavish-intake.sh active intake setup; action=update setup instructions' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "active intake accepted a not-applicable exemption"
  assert_contains "$out" "intake is active" "active-intake exemption refusal was unclear"
  assert_present "$home/state/active-a1.lavish-intake-session" \
    "active-intake exemption removed the in-progress session"
  assert_absent "$home/state/active-a1.lavish-intake" \
    "active-intake exemption published bypass evidence"
  pass "Lavish intake: active sessions cannot be replaced by exemptions"
}

test_exemption_ignores_foreign_valid_marker() {
  local home out rc
  home=$(make_home foreign-marker)
  mkdir -p "$home/state/procevent"
  printf 'version=1\ntask_id=foreign-a1\nsource_id=lavish-foreignmarker\nowner_token=ownerforeign\n' \
    > "$home/state/procevent/lavish-foreignmarker.intake"
  run_intake "$home" exempt local-a1 \
    --reason 'configuration: task=local-a1; target=tests/fm-lavish-feature-intake.test.sh foreign marker; action=exercise exemption ownership behavior' \
    >/dev/null
  assert_present "$home/state/local-a1.lavish-intake" \
    "a valid foreign intake marker blocked an unrelated exemption"
  printf 'version=1\ntask_id=\nsource_id=lavish-malformed\n' \
    > "$home/state/procevent/lavish-malformed.intake"
  set +e
  out=$(run_intake "$home" exempt malformed-a1 \
    --reason 'configuration: task=malformed-a1; target=tests/fm-lavish-feature-intake.test.sh malformed marker; action=exercise marker validation behavior' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a malformed foreign intake marker was ignored"
  assert_contains "$out" "active" "malformed intake marker refusal was unclear"
  pass "Lavish intake: foreign markers are ignored and malformed markers fail closed"
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
  fixture_for "$home" feature-a1 missing
  run_process_event "$home" "$sid" >/dev/null
  result="$home/state/procevent-inbox/$sid.1.result"
  assert_present "$home/state/procevent/$sid.source" \
    "missing-session intake source was retired before valid feedback"
  assert_absent "$home/state/procevent-inbox/$sid.1.handled" \
    "missing-session intake was silently acknowledged"
  set +e
  out=$(run_intake "$home" record feature-a1 --artifact "$artifact" --result "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing-session feedback result was accepted"
  assert_contains "$out" "is not feedback" "missing-session refusal was unclear"
  fixture_for "$home" feature-a1 ended
  run_process_event "$home" "$sid" >/dev/null
  assert_present "$home/state/procevent/$sid.source" \
    "empty ended intake source was retired before valid feedback"
  assert_absent "$home/state/procevent-inbox/$sid.1.handled" \
    "empty ended intake was silently acknowledged"
  set +e
  out=$(run_intake "$home" record feature-a1 --artifact "$artifact" \
    --result "$home/state/procevent-inbox/$sid.2.result" 2>&1)
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
  assert_present "$home/state/procevent/$sid.source" "malformed terminal feedback retired the intake source"
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
  rm -f "$home/state/procevent/$sid.intake"
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" answers "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing intake session fell back to legacy answer routing"
  assert_contains "$out" "source marker is missing" "missing-marker refusal was unclear"
  (cd "$home" && tasks-axi show missing-session-a1 --full) | grep -Fq 'hold_kind: captain' \
    || fail "missing intake session released the held task"
  pass "Lavish intake: missing sessions fail closed"
}

test_intake_flag_rejects_exemption() {
  local home receipt out rc
  home=$(make_home intake-classification)
  add_task "$home" classification-a1
  run_intake "$home" exempt classification-a1 --reason 'documentation: task=classification-a1; target=tests/fm-lavish-feature-intake.test.sh classification test; action=update test coverage' >/dev/null
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

test_verified_exemption_revalidates_reason() {
  local home receipt marker artifact_hash out rc
  home=$(make_home verified-exemption)
  add_task "$home" verified-exemption-a1
  run_intake "$home" exempt verified-exemption-a1 \
    --reason 'documentation: task=verified-exemption-a1; target=tests/fm-lavish-feature-intake.test.sh verification case; action=update exemption evidence coverage' \
    >/dev/null
  receipt=$home/state/verified-exemption-a1.lavish-intake
  marker=$home/state/verified-exemption-a1.lavish-intake-classification
  sed -i '' 's/^reason=.*/reason=skip/' "$receipt" "$marker"
  artifact_hash=$(shasum -a 256 "$marker" | awk '{print $1}')
  sed -i '' "s/^artifact_sha256=.*/artifact_sha256=$artifact_hash/" "$receipt"
  set +e
  out=$(run_intake "$home" verify verified-exemption-a1 --evidence "$receipt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forged exemption reason passed durable verification"
  assert_contains "$out" "exemption reason must use" "forged exemption refusal was unclear"
  pass "Lavish intake: durable exemption verification revalidates concrete reasons"
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

test_start_end_failure_preserves_ownership_state() {
  local home artifact artifact_real sid out rc
  home=$(make_home end-rollback)
  add_task "$home" end-rollback-a1
  artifact=$home/intake.html
  artifact_real=$(CDPATH='' cd -- "$(dirname "$artifact")" && pwd -P)/$(basename "$artifact")
  run_intake "$home" template end-rollback-a1 --output "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  set +e
  out=$(FM_LAVISH_FAIL_OPEN=1 FM_LAVISH_FAIL_END=1 \
    run_intake "$home" start end-rollback-a1 --artifact "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failed Lavish cleanup unexpectedly succeeded"
  assert_contains "$out" "preserving intake ownership state" \
    "failed Lavish cleanup did not report retryable ownership state"
  (cd "$home" && tasks-axi show end-rollback-a1 --full) | grep -Fq 'hold_kind: captain' \
    || fail "failed Lavish cleanup released the captain hold"
  assert_present "$home/state/end-rollback-a1.lavish-intake-session" \
    "failed Lavish cleanup discarded the session ownership marker"
  assert_present "$home/state/end-rollback-a1.lavish-intake-hold" \
    "failed Lavish cleanup discarded the hold ownership marker"
  assert_present "$home/state/decision-bindings/$sid.origin" \
    "failed Lavish cleanup discarded the source binding"
  assert_contains "$(cat "$home/lavish.calls")" "end $artifact_real" \
    "failed Lavish cleanup did not attempt to end the session"
  pass "Lavish intake: failed session cleanup preserves retryable ownership"
}

test_arm_failure_rolls_back_only_new_state() {
  local home artifact artifact_real out rc sid
  home=$(make_home arm-rollback)
  add_task "$home" arm-rollback-a1
  artifact=$home/intake.html
  artifact_real=$(CDPATH='' cd -- "$(dirname "$artifact")" && pwd -P)/$(basename "$artifact")
  run_intake "$home" template arm-rollback-a1 --output "$artifact" >/dev/null
  printf 'not-a-directory\n' > "$home/claims"
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
  assert_contains "$(cat "$home/lavish.calls")" "end $artifact_real" "failed arm left the Lavish session open"
  pass "Lavish intake: failed process-event arm rolls back partial setup"
}

test_ordinary_rearm_refuses_stale_intake_ownership() {
  local home artifact out rc sid
  home=$(make_home stale-rearm)
  add_task "$home" stale-rearm-a1
  artifact=$home/intake.html
  run_intake "$home" template stale-rearm-a1 --output "$artifact" >/dev/null
  run_intake "$home" start stale-rearm-a1 --artifact "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" retire "$artifact" \
    --expect-intake-task stale-rearm-a1 >/dev/null
  set +e
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ordinary re-arm ignored stale intake ownership"
  assert_contains "$out" "intake ownership remains" \
    "stale intake re-arm refusal was unclear"
  assert_absent "$home/state/procevent/$sid.source" \
    "stale intake re-arm registered an ordinary source"
  set +e
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    "$ROOT/bin/fm-procevent.sh" register lavish "$sid" -- \
    "$ROOT/bin/fm-procevent-lavish.sh" poll "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "canonical ordinary registration ignored stale intake ownership"
  assert_contains "$out" "ordinary-register" \
    "canonical registration refusal was unclear"
  assert_absent "$home/state/procevent/$sid.source" \
    "canonical registration bypassed stale intake ownership"
  pass "Lavish intake: stale typed ownership blocks ordinary re-arm"
}

test_artifact_replacement_refused() {
  local home artifact sid result out rc
  home=$(make_home artifact-replacement)
  add_task "$home" artifact-replacement-a1
  artifact=$home/intake.html
  run_intake "$home" template artifact-replacement-a1 --output "$artifact" >/dev/null
  run_intake "$home" start artifact-replacement-a1 --artifact "$artifact" >/dev/null
  printf '\nreplacement bytes\n' >> "$artifact"
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" artifact-replacement-a1
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  set +e
  out=$(run_intake "$home" record artifact-replacement-a1 --artifact "$artifact" --result "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "replaced intake artifact was accepted"
  assert_contains "$out" "artifact changed" "artifact replacement refusal was unclear"
  assert_absent "$home/state/artifact-replacement-a1.lavish-intake" \
    "replaced intake artifact produced evidence"
  (cd "$home" && tasks-axi show artifact-replacement-a1 --full) | grep -Fq 'hold_kind: captain' \
    || fail "replaced intake artifact released the task"
  pass "Lavish intake: recording rejects an artifact changed after start"
}

test_start_rejects_cross_task_stale_artifact_ownership() {
  local home artifact sid result out rc
  home=$(make_home stale-artifact-owner)
  add_task "$home" stale-owner-a1
  add_task "$home" stale-owner-b1
  artifact=$home/intake.html
  run_intake "$home" template stale-owner-a1 --output "$artifact" >/dev/null
  run_intake "$home" start stale-owner-a1 --artifact "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" stale-owner-a1
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  run_intake "$home" record stale-owner-a1 --artifact "$artifact" --result "$result" >/dev/null
  rm -f "$artifact"
  run_intake "$home" template stale-owner-b1 --output "$artifact" >/dev/null
  set +e
  out=$(run_intake "$home" start stale-owner-b1 --artifact "$artifact" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cross-task stale artifact ownership was reused"
  assert_contains "$out" "already owned by task stale-owner-a1" \
    "stale artifact ownership refusal was unclear"
  assert_present "$home/state/stale-owner-a1.lavish-intake-session" \
    "stale artifact refusal removed the original intake session"
  (cd "$home" && tasks-axi show stale-owner-b1 --full) | grep -Fq 'hold_kind: captain' \
    && fail "stale artifact refusal held the replacement task"
  pass "Lavish intake: cross-task stale artifact ownership is preserved"
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
  fixture_for "$home" feature-a1 feedback feedback-block
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

test_record_resumes_after_release_failure() {
  local home artifact sid result out rc pending hold_reason
  home=$(make_home record-retry)
  add_task "$home" retry-a1
  artifact=$home/intake.html
  run_intake "$home" template retry-a1 --output "$artifact" >/dev/null
  run_intake "$home" start retry-a1 --artifact "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" retry-a1
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  ln -s /dev/null "$home/state/procevent-inbox/$sid.1.handled"
  set +e
  out=$(run_intake "$home" record retry-a1 --artifact "$artifact" --result "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "handled acknowledgement failure unexpectedly succeeded"
  pending=$home/state/retry-a1.lavish-intake-pending
  assert_contains "$(cat "$pending")" "phase=released" \
    "release failure did not persist the resumable completion phase"
  assert_contains "$(cat "$home/state/retry-a1.lavish-intake-owner")" "phase=released" \
    "release failure did not persist exact owner resolution"
  (cd "$home" && tasks-axi show retry-a1 --full) | grep -Fq 'state: queued' \
    || fail "release failure did not leave the task queued"
  if (cd "$home" && tasks-axi show retry-a1 --full) | grep -Fq 'hold_kind: captain'; then
    fail "release recovery unexpectedly retained a captain hold"
  fi
  hold_reason=$(sed -n 's/^hold_reason=//p' \
    "$home/state/retry-a1.lavish-intake-owner" | head -1)
  (cd "$home" && tasks-axi hold retry-a1 --kind captain --reason "$hold_reason" >/dev/null) \
    || fail "could not create the ambiguous newer captain hold"
  (cd "$home" && tasks-axi done retry-a1 >/dev/null) \
    || fail "could not close task while testing release recovery"
  rm -f "$home/state/procevent-inbox/$sid.1.handled"
  set +e
  out=$(run_intake "$home" record retry-a1 --artifact "$artifact" --result "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ambiguous done-state recovery unexpectedly succeeded"
  assert_contains "$out" "matching captain release evidence" \
    "ambiguous done-state refusal was unclear"
  assert_contains "$(cat "$pending")" "phase=released" \
    "ambiguous done-state recovery changed pending evidence"
  assert_absent "$home/state/retry-a1.lavish-intake" \
    "ambiguous done-state recovery produced intake evidence"
  assert_present "$home/state/retry-a1.lavish-intake-owner" \
    "ambiguous done-state recovery discarded pending ownership evidence"
  pass "Lavish intake: ambiguous done-state recovery stays pending"
}

test_pending_release_requires_durable_resolution() {
  local home artifact sid result pending out rc
  home=$(make_home pending-release-proof)
  add_task "$home" pending-proof-a1
  artifact=$home/intake.html
  run_intake "$home" template pending-proof-a1 --output "$artifact" >/dev/null
  run_intake "$home" start pending-proof-a1 --artifact "$artifact" >/dev/null
  sid=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$artifact")
  fixture_for "$home" pending-proof-a1
  run_process_event "$home" "$sid" >/dev/null
  result=$home/state/procevent-inbox/$sid.1.result
  pending=$home/state/pending-proof-a1.lavish-intake-pending
  ln -s /dev/null "$home/state/procevent-inbox/$sid.1.handled"
  set +e
  run_intake "$home" record pending-proof-a1 --artifact "$artifact" --result "$result" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "setup release failure unexpectedly succeeded"
  sed -i '' 's/^phase=released$/phase=held/' "$pending" \
    "$home/state/pending-proof-a1.lavish-intake-owner"
  (cd "$home" && tasks-axi unhold pending-proof-a1 >/dev/null)
  set +e
  out=$(run_intake "$home" record pending-proof-a1 --artifact "$artifact" --result "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unrelated unhold satisfied pending intake release"
  assert_contains "$out" "matching captain release evidence" \
    "pending release proof refusal was unclear"
  assert_contains "$(cat "$pending")" "phase=held" \
    "unrelated unhold advanced pending intake completion"
  assert_absent "$home/state/pending-proof-a1.lavish-intake" \
    "unrelated unhold produced intake evidence"
  (cd "$home" && tasks-axi hold pending-proof-a1 --kind captain \
    --reason "$(sed -n 's/^hold_reason=//p' "$home/state/pending-proof-a1.lavish-intake-owner" | head -1)" >/dev/null)
  (cd "$home" && tasks-axi done pending-proof-a1 >/dev/null)
  set +e
  out=$(run_intake "$home" record pending-proof-a1 --artifact "$artifact" --result "$result" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a newer captain hold satisfied pending intake release"
  assert_contains "$out" "matching captain release evidence" \
    "newer captain hold refusal was unclear"
  assert_absent "$home/state/pending-proof-a1.lavish-intake" \
    "newer captain hold produced intake evidence"
  pass "Lavish intake: pending completion requires durable captain resolution"
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
test_artifact_must_read_submitted_fields
test_template_submit_is_single_use
test_start_rejects_closed_task
test_artifact_task_mismatch_refused
test_ambiguous_classification_refuses_dispatch
test_explicit_exemptions_require_reason
test_brief_exemption_stages_before_receipt
test_exemption_rejects_active_intake
test_exemption_ignores_foreign_valid_marker
test_absent_and_closed_without_feedback_refused
test_malformed_captured_feedback_refused
test_missing_intake_session_fails_closed
test_intake_flag_rejects_exemption
test_verified_exemption_revalidates_reason
test_contractless_compatibility_requires_existing_endpoint
test_start_failure_rolls_back_only_new_state
test_start_end_failure_preserves_ownership_state
test_arm_failure_rolls_back_only_new_state
test_ordinary_rearm_refuses_stale_intake_ownership
test_artifact_replacement_refused
test_start_rejects_cross_task_stale_artifact_ownership
test_start_rejects_unrelated_captain_hold
test_extra_keyed_feedback_refused
test_successful_captured_feedback_and_followup
test_record_resumes_after_release_failure
test_pending_release_requires_durable_resolution
test_firstmate_self_work_gets_same_gate
printf '# all fm-lavish-feature-intake tests passed\n'
