#!/usr/bin/env bash
# fm-lavish-intake.sh - deterministic evidence boundary for feature intake.
#
# Usage:
#   fm-lavish-intake.sh template <task-id> --output <artifact.html>
#   fm-lavish-intake.sh start <task-id> --artifact <artifact.html> [--reason <text>]
#   fm-lavish-intake.sh record <task-id> --artifact <artifact.html> --result <result>
#   fm-lavish-intake.sh exempt <task-id> --reason <text>
#   fm-lavish-intake.sh verify <task-id> [--evidence <receipt>]
#   fm-lavish-intake.sh check-brief <task-id> <brief.md>
#
# template  Write a focused input artifact with the required intake fields.
# start     Open the artifact through lavish-axi, hold the task through the
#           captain-hold owner, bind its answer source, and arm the existing
#           Lavish process-event adapter. It never polls in the foreground.
# record    Accept only feedback captured by the existing process-event runner,
#           feed its keyed release through captain-hold, write a receipt, and
#           acknowledge the exact captured result.
# exempt    Record an explicit not-applicable classification and its concrete
#           reason. It is never an implicit default.
# verify    Revalidate receipt, artifact, captured feedback, hashes, and the
#           process-event acknowledgement before dispatch.
# check-brief Resolve the brief's explicit intake contract. A brief without a
#           contract is legacy and remains compatible with in-flight work.
#
# This command owns evidence mechanics only. Semantic policy lives in
# .agents/skills/lavish-feature-intake/SKILL.md. Captain answers still flow
# through bin/fm-captain-hold.sh, and long polling still flows through
# bin/fm-procevent-lavish.sh and bin/fm-procevent.sh.
set -eu
IFS=$' \t\n'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

FIELDS="product_goal intended_users use_cases scope non_goals constraints visual_product_references key_choices acceptance_criteria open_questions"
RECEIPT_VERSION=1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-lavish-intake: %s\n' "$*" >&2
  exit 1
}

validate_task_id() {
  fm_task_id_path_safe "$1" || fail "task id must be path-safe: $1"
}

validate_one_line() {
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

real_file() {
  local path=$1 real
  case "$path" in *$'\n'*|*$'\r'*) return 1 ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$path" 2>/dev/null) || return 1
  [ -f "$real" ] && [ ! -L "$real" ] || return 1
  printf '%s\n' "$real"
}

real_dir() {
  local path=$1 real
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$path" 2>/dev/null) || return 1
  [ -d "$real" ] && [ ! -L "$real" ] || return 1
  printf '%s\n' "$real"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

receipt_path() { printf '%s/%s.lavish-intake\n' "$STATE" "$1"; }
session_path() { printf '%s/%s.lavish-intake-session\n' "$STATE" "$1"; }

meta_value() {
  local file=$1 key=$2
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$file"
}

require_unique_meta() {
  local file=$1 key=$2 count
  count=$(grep -c "^${key}=" "$file" 2>/dev/null || true)
  [ "$count" -eq 1 ] || fail "receipt must contain exactly one $key field"
  meta_value "$file" "$key"
}

artifact_fields_present() {
  local artifact=$1 field
  grep -Fq 'data-lavish-intake="v1"' "$artifact" \
    || fail "artifact is not a Lavish intake v1 surface"
  grep -Fq 'data-lavish-intake-submit="true"' "$artifact" \
    || fail "artifact has no explicit intake submit control"
  grep -Fq 'window.lavish.queuePrompt' "$artifact" \
    || fail "artifact has no captured Lavish feedback call"
  grep -Fq 'data-lavish-question=' "$artifact" \
    || fail "artifact has no keyed intake question"
  for field in $FIELDS; do
    grep -Fq "data-lavish-intake-field=\"$field\"" "$artifact" \
      || fail "artifact is missing required field: $field"
  done
}

result_is_captured_feedback() {
  local result=$1 artifact=$2 task=$3 sid seq adapter inbox parent answer_rows found=0 key answer label close field
  result=$(real_file "$result") || fail "captured result is not a regular file: $result"
  artifact=$(real_file "$artifact") || fail "artifact is not a regular file: $artifact"
  inbox=$(real_dir "$STATE/procevent-inbox") \
    || fail "captured-result inbox is missing or unsafe"
  parent=${result%/*}
  [ "$parent" = "$inbox" ] || fail "result must be inside the captured-result inbox"
  case "${result##*/}" in
    *.*.result) ;;
    *) fail "result name must be <source-id>.<sequence>.result" ;;
  esac
  sid=$(fm_procevent_result_source_id "$result")
  seq=$(fm_procevent_result_sequence "$result")
  fm_procevent_source_id_valid "$sid" || fail "result source id is invalid: $sid"
  case "$seq" in ''|*[!0-9]*) fail "result sequence is invalid: $seq" ;; esac
  adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null || true)
  [ "$adapter" = lavish ] || fail "result was not captured by the Lavish adapter"
  [ "$("$SCRIPT_DIR/fm-procevent-lavish.sh" classify "$result")" = feedback ] \
    || fail "captured result is not feedback"
  [ "$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$sid" 2>/dev/null || true)" = "$task" ] \
    || fail "Lavish source is not bound to task $task"
  answer_rows=$("$SCRIPT_DIR/fm-procevent-lavish.sh" answers "$result") \
    || fail "captured feedback could not be read"
  while IFS=$'\t' read -r key answer label close; do
    [ -n "${key:-}" ] || continue
    if [ "$key" = "$task" ]; then
      [ "$answer" = submitted ] || fail "intake answer must be submitted"
      [ "$close" = release ] || fail "intake answer must release held work"
      found=$((found + 1))
    fi
  done <<EOF
$answer_rows
EOF
  [ "$found" -eq 1 ] || fail "captured feedback has no single submitted answer for task $task"
  grep -Eq 'intake[^[:alnum:]_].*submitted|submitted.*intake' "$result" \
    || fail "captured feedback lacks the intake submission payload"
  grep -Eq 'submitted[[:space:]]*[^[:alnum:]]*[[:space:]]*true|submitted[^[:alnum:]]*true' "$result" \
    || fail "captured feedback lacks submitted=true"
  for field in $FIELDS; do
    grep -Fq "$field" "$result" \
      || fail "captured feedback lacks required field: $field"
  done
  printf '%s\t%s\n' "$sid" "$seq"
}

write_receipt() {
  local task=$1 classification=$2 artifact=$3 result=$4 reason=$5 dest tmp sid seq artifact_hash result_hash
  dest=$(receipt_path "$task")
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.lavish-intake.XXXXXX") || fail "cannot stage intake receipt"
  sid=
  seq=
  if [ -n "$result" ]; then
    sid=$(fm_procevent_result_source_id "$result")
    seq=$(fm_procevent_result_sequence "$result")
  fi
  artifact_hash=$(sha256_file "$artifact")
  result_hash=
  [ -z "$result" ] || result_hash=$(sha256_file "$result")
  {
    printf 'version=%s\n' "$RECEIPT_VERSION"
    printf 'task_id=%s\n' "$task"
    printf 'classification=%s\n' "$classification"
    printf 'artifact=%s\n' "$artifact"
    printf 'artifact_sha256=%s\n' "$artifact_hash"
    if [ -n "$result" ]; then
      printf 'source_id=%s\n' "$sid"
      printf 'sequence=%s\n' "$seq"
      printf 'result=%s\n' "$result"
      printf 'result_sha256=%s\n' "$result_hash"
      printf 'feedback=captured\n'
    else
      printf 'reason=%s\n' "$reason"
      printf 'feedback=not-applicable\n'
    fi
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$dest"
  printf 'evidence: %s\n' "$dest"
}

cmd_template() {
  local task=${1-} output='' field label
  shift || true
  validate_task_id "$task"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output) [ "$#" -ge 2 ] || fail "--output requires a path"; output=$2; shift 2 ;;
      --output=*) output=${1#*=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown template argument: $1" ;;
    esac
  done
  [ -n "$output" ] || fail "template requires --output <artifact.html>"
  [ ! -e "$output" ] && [ ! -L "$output" ] || fail "artifact already exists: $output"
  case "$output" in
    */*) [ -d "${output%/*}" ] || mkdir -p "${output%/*}" || fail "cannot create artifact parent: ${output%/*}" ;;
    *) : ;;
  esac
  cat > "$output" <<EOF
<!doctype html>
<html lang="en" data-theme="light" data-lavish-intake="v1">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Feature intake - $task</title>
  <style>
    :root { color-scheme: light; font: 16px/1.5 system-ui,sans-serif; background:#f5f7fb; color:#172033; }
    body { max-width: 900px; margin: 0 auto; padding: 32px 20px 64px; }
    main { background:#fff; border:1px solid #dbe2ee; border-radius:16px; padding:28px; box-shadow:0 8px 28px #17203312; }
    label { display:block; font-weight:650; margin-top:18px; }
    textarea { display:block; width:100%; min-height:72px; margin-top:6px; padding:10px; border:1px solid #aebbd0; border-radius:8px; font:inherit; box-sizing:border-box; }
    button { margin-top:24px; padding:11px 16px; border:0; border-radius:8px; background:#3157d5; color:#fff; font:inherit; font-weight:700; cursor:pointer; }
    #intake-status { margin-top:14px; min-height:1.5em; }
    .hint { color:#56647b; }
  </style>
</head>
<body>
<main>
  <h1>Feature intake</h1>
  <p class="hint">Fill every field. Queue one submitted answer, then use Lavish Send to Agent.</p>
  <form id="feature-intake" data-lavish-question="$task">
EOF
  for field in $FIELDS; do
    label=$(printf '%s' "$field" | tr '_' ' ')
    printf '    <label>%s<textarea name="%s" data-lavish-intake-field="%s" required></textarea></label>\n' \
      "$label" "$field" "$field" >> "$output"
  done
  cat >> "$output" <<EOF
    <button type="submit" data-lavish-intake-submit="true">Queue submitted intake</button>
    <p id="intake-status" role="status" aria-live="polite"></p>
  </form>
</main>
<script>
(() => {
  const task = "$task";
  const fields = "$FIELDS".split(" ");
  const form = document.querySelector("#feature-intake");
  const status = document.querySelector("#intake-status");
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const intake = Object.fromEntries(fields.map((field) => [field, form.elements[field].value.trim()]));
    if (fields.some((field) => !intake[field])) {
      status.textContent = "Complete every field before queueing.";
      return;
    }
    window.lavish.queuePrompt("Feature intake submitted", {
      tag: "choice",
      text: "Feature intake submitted",
      element: form,
      data: { question: task, answer: "submitted", close: "release", submitted: true, intake }
    });
    status.textContent = "Queued. Send this answer to the agent in Lavish.";
  });
})();
</script>
</body>
</html>
EOF
  chmod 0600 "$output"
  printf 'template: %s\n' "$output"
}

cmd_start() {
  local task=${1-} artifact='' reason='' sid mapping tmp
  shift || true
  validate_task_id "$task"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --artifact) [ "$#" -ge 2 ] || fail "--artifact requires a path"; artifact=$2; shift 2 ;;
      --artifact=*) artifact=${1#*=}; shift ;;
      --reason) [ "$#" -ge 2 ] || fail "--reason requires text"; reason=$2; shift 2 ;;
      --reason=*) reason=${1#*=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown start argument: $1" ;;
    esac
  done
  [ -n "$artifact" ] || fail "start requires --artifact <artifact.html>"
  [ -n "$reason" ] || reason="Captain review of required feature intake before implementation"
  validate_one_line reason "$reason"
  [ ! -e "$(receipt_path "$task")" ] && [ ! -L "$(receipt_path "$task")" ] \
    || fail "intake evidence already exists for task $task"
  [ ! -e "$(session_path "$task")" ] && [ ! -L "$(session_path "$task")" ] \
    || fail "intake session already exists for task $task"
  artifact=$(real_file "$artifact") || fail "artifact is not a regular file: $artifact"
  artifact_fields_present "$artifact"
  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "$task" --reason "$reason" >/dev/null \
    || fail "could not hold task for Lavish intake"
  lavish-axi "$artifact" || fail "could not establish the Lavish intake session"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$artifact") \
    || fail "could not derive the Lavish source id"
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" "$task" >/dev/null \
    || fail "could not bind Lavish source to task $task"
  mapping=$(session_path "$task")
  tmp=$(mktemp "$STATE/.lavish-intake-session.XXXXXX") || fail "cannot stage intake session"
  {
    printf 'task_id=%s\n' "$task"
    printf 'artifact=%s\n' "$artifact"
    printf 'source_id=%s\n' "$sid"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$mapping"
  "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$artifact" >/dev/null \
    || fail "could not arm captured Lavish feedback"
  printf 'armed: %s\n' "$sid"
  printf 'next: submit this intake in Lavish; firstmate handles the captured feedback before dispatch\n'
}

cmd_record() {
  local task=${1-} artifact='' result='' answer_rows result_identity sid seq receipt out
  shift || true
  validate_task_id "$task"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --artifact) [ "$#" -ge 2 ] || fail "--artifact requires a path"; artifact=$2; shift 2 ;;
      --artifact=*) artifact=${1#*=}; shift ;;
      --result) [ "$#" -ge 2 ] || fail "--result requires a path"; result=$2; shift 2 ;;
      --result=*) result=${1#*=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown record argument: $1" ;;
    esac
  done
  [ -n "$artifact" ] || fail "record requires --artifact <artifact.html>"
  [ -n "$result" ] || fail "record requires --result <captured-result>"
  artifact=$(real_file "$artifact") || fail "artifact is not a regular file: $artifact"
  artifact_fields_present "$artifact"
  [ -f "$(session_path "$task")" ] && [ ! -L "$(session_path "$task")" ] \
    || fail "no Lavish intake session is recorded for task $task"
  [ "$(meta_value "$(session_path "$task")" artifact)" = "$artifact" ] \
    || fail "artifact does not match recorded intake session"
  result_identity=$(result_is_captured_feedback "$result" "$artifact" "$task")
  sid=${result_identity%%$'\t'*}
  seq=${result_identity#*$'\t'}
  answer_rows=$("$SCRIPT_DIR/fm-procevent-lavish.sh" answers "$result")
  out=$(printf '%s\n' "$answer_rows" \
    | "$SCRIPT_DIR/fm-captain-hold.sh" answers "$task" \
        --source "captured Lavish intake $sid sequence $seq" 2>&1) \
    || fail "captured intake could not release held task: $out"
  printf '%s\n' "$out" | grep -Eq 'closed:|answered:' \
    || fail "captured intake did not close through captain-hold: $out"
  receipt=$(receipt_path "$task")
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || fail "intake evidence already exists: $receipt"
  write_receipt "$task" significant "$artifact" "$(real_file "$result")" ""
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null \
    || fail "could not acknowledge captured Lavish result"
  printf 'recorded: %s\n' "$receipt"
}

cmd_exempt() {
  local task=${1-} reason='' artifact
  shift || true
  validate_task_id "$task"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || fail "--reason requires text"; reason=$2; shift 2 ;;
      --reason=*) reason=${1#*=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown exempt argument: $1" ;;
    esac
  done
  validate_one_line reason "$reason"
  artifact="$STATE/$task.lavish-intake-classification"
  [ ! -e "$artifact" ] && [ ! -L "$artifact" ] \
    || fail "not-applicable classification marker already exists for task $task"
  [ ! -e "$(receipt_path "$task")" ] && [ ! -L "$(receipt_path "$task")" ] \
    || fail "intake evidence already exists for task $task"
  mkdir -p "$STATE"
  printf 'not-applicable classification for %s\nreason=%s\n' "$task" "$reason" > "$artifact"
  chmod 0600 "$artifact"
  write_receipt "$task" not-applicable "$artifact" "" "$reason"
}

verify_receipt() {
  local task=$1 receipt=$2 classification artifact result sid seq expected_artifact expected_result key value reason
  validate_task_id "$task"
  receipt=$(real_file "$receipt") || fail "intake evidence is not a regular file: $receipt"
  [ "$(dirname "$receipt")" = "$(real_dir "$STATE")" ] \
    || fail "intake evidence must live in this home's state directory"
  classification=$(require_unique_meta "$receipt" classification)
  [ "$classification" = significant ] || {
    [ "$classification" = not-applicable ] || fail "unknown intake classification: $classification"
  }
  [ "$(require_unique_meta "$receipt" version)" = "$RECEIPT_VERSION" ] \
    || fail "unsupported intake evidence version"
  [ "$(require_unique_meta "$receipt" task_id)" = "$task" ] \
    || fail "intake evidence names a different task"
  artifact=$(require_unique_meta "$receipt" artifact)
  artifact=$(real_file "$artifact") || fail "intake artifact is missing or unsafe: $artifact"
  expected_artifact=$(require_unique_meta "$receipt" artifact_sha256)
  [ "$expected_artifact" = "$(sha256_file "$artifact")" ] \
    || fail "intake artifact hash does not match evidence"
  if [ "$classification" = not-applicable ]; then
    reason=$(require_unique_meta "$receipt" reason)
    [ "$(grep -c '^reason=' "$artifact" 2>/dev/null || true)" -eq 1 ] \
      || fail "not-applicable classification marker has no unique reason"
    [ "$(meta_value "$artifact" reason)" = "$reason" ] \
      || fail "not-applicable reason does not match classification marker"
    [ "$(require_unique_meta "$receipt" feedback)" = not-applicable ] \
      || fail "not-applicable evidence has wrong feedback marker"
    printf 'status=not-applicable\nreason=%s\n' "$reason"
    return 0
  fi
  artifact_fields_present "$artifact"
  result=$(require_unique_meta "$receipt" result)
  result=$(real_file "$result") || fail "captured intake result is missing or unsafe: $result"
  expected_result=$(require_unique_meta "$receipt" result_sha256)
  [ "$expected_result" = "$(sha256_file "$result")" ] \
    || fail "captured intake result hash does not match evidence"
  sid=$(require_unique_meta "$receipt" source_id)
  seq=$(require_unique_meta "$receipt" sequence)
  [ "$(fm_procevent_result_source_id "$result")" = "$sid" ] || fail "result source identity changed"
  [ "$(fm_procevent_result_sequence "$result")" = "$seq" ] || fail "result sequence changed"
  [ -f "$STATE/procevent-inbox/$sid.$seq.handled" ] \
    || fail "captured intake result is not durably acknowledged"
  result_is_captured_feedback "$result" "$artifact" "$task" >/dev/null
  [ "$(require_unique_meta "$receipt" feedback)" = captured ] \
    || fail "significant evidence has wrong feedback marker"
  printf 'status=submitted\nevidence=%s\n' "$receipt"
}

cmd_verify() {
  local task=${1-} receipt=
  shift || true
  validate_task_id "$task"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence) [ "$#" -ge 2 ] || fail "--evidence requires a path"; receipt=$2; shift 2 ;;
      --evidence=*) receipt=${1#*=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown verify argument: $1" ;;
    esac
  done
  [ -n "$receipt" ] || receipt=$(receipt_path "$task")
  verify_receipt "$task" "$receipt"
}

cmd_check_brief() {
  local task=${1-} brief=${2-} contract evidence reason
  [ "$#" -eq 2 ] || fail "check-brief requires <task-id> <brief.md>"
  validate_task_id "$task"
  brief=$(real_file "$brief") || fail "brief is not a regular file: $brief"
  contract=$(awk -F': ' '/^Lavish intake contract: / { print $2; exit }' "$brief")
  if [ -z "$contract" ]; then
    printf 'status=legacy\n'
    return 0
  fi
  case "$contract" in
    submitted)
      evidence=$(awk -F': ' '/^Lavish intake evidence: / { print $2; exit }' "$brief")
      [ -n "$evidence" ] || fail "submitted brief has no intake evidence"
      verify_receipt "$task" "$evidence"
      ;;
    not-applicable)
      reason=$(awk -F': ' '/^Lavish intake reason: / { print $2; exit }' "$brief")
      [ -n "$reason" ] || fail "not-applicable brief has no concrete reason"
      verify_receipt "$task" "$(receipt_path "$task")"
      ;;
    required)
      fail "Lavish feature intake is required before implementation"
      ;;
    *) fail "unknown Lavish intake contract: $contract" ;;
  esac
}

case "${1-}" in
  template) shift; cmd_template "$@" ;;
  start) shift; cmd_start "$@" ;;
  record) shift; cmd_record "$@" ;;
  exempt) shift; cmd_exempt "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  check-brief) shift; cmd_check_brief "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
