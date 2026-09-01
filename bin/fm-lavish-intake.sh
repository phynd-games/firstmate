#!/usr/bin/env bash
# fm-lavish-intake.sh - deterministic evidence boundary for feature intake.
#
# Usage:
#   fm-lavish-intake.sh template <task-id> --output <artifact.html>
#   fm-lavish-intake.sh start <task-id> --artifact <artifact.html> [--reason <text>]
#   fm-lavish-intake.sh record <task-id> --artifact <artifact.html> --result <result>
#   fm-lavish-intake.sh exempt <task-id> --reason '<class>: task=<task-id>; target=<path-like subject>; action=<specific concrete change>'
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
# check-brief Resolve the brief's explicit intake contract. A contractless brief
#           is compatible only when an existing task endpoint proves it is in flight.
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
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

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
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$path" 2>/dev/null) || return 1
  [ -d "$real" ] && [ ! -L "$real" ] || return 1
  printf '%s\n' "$real"
}

brief_value() {
  local prefix=$1 file=$2
  awk -v prefix="$prefix" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' "$file"
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

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

lavish_session_state_path() {
  printf '%s/state.json\n' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}"
}

lavish_session_active() {
  local artifact=$1 canonical state_dir state_file session_key
  state_dir=${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}
  state_file=$(lavish_session_state_path)
  [ -d "$state_dir" ] || return 1
  [ ! -L "$state_dir" ] || return 2
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  canonical=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) || return 2
  [ -f "$canonical" ] && [ ! -L "$canonical" ] || return 2
  session_key=$(sha256_text "$canonical" | cut -c1-16)
  perl -MJSON::PP -e '
    my ($key) = @ARGV;
    local $/;
    my $state = eval { decode_json(<STDIN>) };
    exit 2 unless ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH";
    my $session = $state->{sessions}{$key};
    exit !(ref($session) eq "HASH" && ($session->{status} || "") =~ /^(?:open|feedback)$/);
  ' "$session_key" < "$state_file"
}

receipt_path() { printf '%s/%s.lavish-intake\n' "$STATE" "$1"; }
session_path() { printf '%s/%s.lavish-intake-session\n' "$STATE" "$1"; }
intake_hold_path() { printf '%s/%s.lavish-intake-hold\n' "$STATE" "$1"; }
pending_path() { printf '%s/%s.lavish-intake-pending\n' "$STATE" "$1"; }
intake_lock_path() { printf '%s/.captain-task-%s.lock\n' "$STATE" "$1"; }
intake_source_path() { printf '%s/procevent/%s.intake\n' "$STATE" "$1"; }
intake_source_lock_path() { printf '%s/.lavish-intake-source-%s.lock\n' "$STATE" "$1"; }

intake_state_active_for_task() {
  local task=$1 path source bound registration_task marker_task marker_source
  for path in "$(session_path "$task")" "$(intake_hold_path "$task")" "$STATE/$task.lavish-intake-owner"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    return 0
  done
  for path in "$STATE/procevent"/*.intake; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || return 0
    source=${path##*/}
    source=${source%.intake}
    [ "$(grep -c '^task_id=' "$path" 2>/dev/null || true)" -eq 1 ] || return 0
    [ "$(grep -c '^source_id=' "$path" 2>/dev/null || true)" -eq 1 ] || return 0
    marker_task=$(meta_value "$path" task_id)
    marker_source=$(meta_value "$path" source_id)
    fm_task_id_path_safe "$marker_task" || return 0
    fm_procevent_source_id_valid "$source" || return 0
    [ "$marker_source" = "$source" ] || return 0
    [ "$marker_task" = "$task" ] && return 0
  done
  for path in "$STATE/procevent"/*.source; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || return 0
    [ "$(meta_value "$path" intake)" = 1 ] || continue
    registration_task=$(meta_value "$path" task_id)
    [ "$registration_task" = "$task" ] && return 0
  done
  for path in "$STATE/decision-bindings"/*.origin; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    source=${path##*/}
    source=${source%.origin}
    bound=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$source" 2>/dev/null || true)
    if [ "$bound" = "$task" ] && "$SCRIPT_DIR/fm-captain-hold.sh" binding-intake "$source" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

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

reject_existing_intake_ownership() {
  local task=$1 sid=$2 artifact=$3 path owner_task owner_source owner_artifact marker_task marker_source bound
  for path in "$STATE"/*.lavish-intake-session; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] \
      || fail "Lavish intake session state is unsafe: $path"
    owner_source=$(meta_value "$path" source_id)
    [ "$owner_source" = "$sid" ] || continue
    owner_task=$(meta_value "$path" task_id)
    fm_task_id_path_safe "$owner_task" \
      || fail "Lavish intake session state has an unsafe task owner: $path"
    [ "$owner_task" = "$task" ] \
      || fail "Lavish intake source $sid is already owned by task $owner_task"
    owner_artifact=$(meta_value "$path" artifact)
    [ "$owner_artifact" = "$artifact" ] \
      || fail "Lavish intake source $sid has stale ownership for task $task"
    fail "Lavish intake source $sid already has active ownership for task $task"
  done
  path=$(intake_source_path "$sid")
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] \
      || fail "Lavish intake source marker is unsafe: $path"
    [ "$(grep -c '^task_id=' "$path" 2>/dev/null || true)" -eq 1 ] \
      && [ "$(grep -c '^source_id=' "$path" 2>/dev/null || true)" -eq 1 ] \
      || fail "Lavish intake source marker is malformed: $path"
    marker_task=$(meta_value "$path" task_id)
    marker_source=$(meta_value "$path" source_id)
    fm_task_id_path_safe "$marker_task" \
      || fail "Lavish intake source marker has an unsafe task owner"
    [ "$marker_source" = "$sid" ] \
      || fail "Lavish intake source marker has the wrong source identity"
    [ "$marker_task" = "$task" ] \
      || fail "Lavish intake source $sid is already owned by task $marker_task"
    fail "Lavish intake source $sid retains typed ownership for task $task"
  fi
  path="$STATE/decision-bindings/$sid.origin"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] \
      || fail "Lavish intake source binding is unsafe: $path"
    bound=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$sid" 2>/dev/null || true)
    [ -z "$bound" ] || fail "Lavish intake source $sid is already bound to task $bound"
  fi
}

artifact_fields_present() {
  local artifact=$1 task=$2 contract_error contract_json validation_nonce
  if ! contract_json=$(python3 - "$artifact" "$task" "$FIELDS" 2>&1 <<'PY'
from html.parser import HTMLParser
import json
import sys

path, task, field_text = sys.argv[1:]
fields = field_text.split()


class IntakeParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = []
        self.form = None
        self.inert = []
        self.script = None
        self.scripts = []
        self.root_count = 0
        self.root_valid = False
        self.error = None

    @staticmethod
    def attributes(raw):
        result = {}
        for name, value in raw:
            if name in result:
                raise ValueError("artifact contains duplicate attributes")
            result[name] = value
        return result

    def handle_starttag(self, tag, raw):
        tag = tag.lower()
        try:
            attrs = self.attributes(raw)
        except ValueError as error:
            self.error = str(error)
            return
        if tag == "html":
            self.root_count += 1
            self.root_valid = attrs.get("data-lavish-intake") == "v1"
        if tag in ("template", "noscript"):
            self.inert.append(tag)
            return
        if self.inert:
            return
        if tag == "script":
            self.script = {"attrs": attrs, "parts": []}
            return
        if tag == "form":
            if self.form is not None:
                self.error = "artifact contains nested intake forms"
                return
            self.form = {"attrs": attrs, "controls": [], "closed": False}
            self.forms.append(self.form)
            return
        if self.form is not None and tag in ("textarea", "button", "input"):
            self.form["controls"].append({"tag": tag, "attrs": attrs})

    def handle_startendtag(self, tag, raw):
        self.handle_starttag(tag, raw)

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "script" and self.script is not None:
            attrs = self.script["attrs"]
            script_type = (attrs.get("type") or "").strip().lower()
            if not script_type or script_type in {
                "module",
                "text/javascript",
                "application/javascript",
                "text/ecmascript",
                "application/ecmascript",
            }:
                self.scripts.append("".join(self.script["parts"]))
            self.script = None
            return
        if tag in ("template", "noscript"):
            if not self.inert or self.inert[-1] != tag:
                self.error = "artifact has mismatched inert elements"
            else:
                self.inert.pop()
            return
        if self.inert:
            return
        if tag == "form":
            if self.form is None:
                self.error = "artifact contains an unmatched form close"
            else:
                self.form["closed"] = True
                self.form = None

    def handle_data(self, data):
        if self.script is not None:
            self.script["parts"].append(data)


parser = IntakeParser()
try:
    with open(path, encoding="utf-8") as handle:
        parser.feed(handle.read())
    parser.close()
except (OSError, ValueError) as error:
    print(str(error), file=sys.stderr)
    raise SystemExit(1)

if parser.error:
    print(parser.error, file=sys.stderr)
    raise SystemExit(1)
if parser.root_count != 1 or not parser.root_valid:
    print("artifact is not a Lavish intake v1 surface", file=sys.stderr)
    raise SystemExit(1)
if parser.inert or parser.script is not None or parser.form is not None:
    print("artifact has an incomplete active DOM", file=sys.stderr)
    raise SystemExit(1)
identified = [form for form in parser.forms if form["attrs"].get("id") == "feature-intake"]
if len(identified) != 1 or identified[0]["attrs"].get("data-lavish-question") != task:
    print("artifact has no keyed intake question", file=sys.stderr)
    raise SystemExit(1)
form = identified[0]
for field in fields:
    matches = [
        control for control in form["controls"]
        if control["tag"] == "textarea"
        and control["attrs"].get("name") == field
        and control["attrs"].get("data-lavish-intake-field") == field
        and "required" in control["attrs"]
    ]
    if len(matches) != 1:
        print(f"artifact is missing required field: {field}", file=sys.stderr)
        raise SystemExit(1)
submits = [
    control for control in form["controls"]
    if control["tag"] in ("button", "input")
    and control["attrs"].get("data-lavish-intake-submit") == "true"
    and (control["attrs"].get("type") or "").lower() == "submit"
]
if len(submits) != 1:
    print("artifact has no explicit intake submit control", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps({"forms": parser.forms, "scripts": parser.scripts}, separators=(",", ":")))
PY
  ); then
    fail "$contract_json"
  fi
  validation_nonce=$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]') \
    || fail "could not create an intake validation nonce"
  [ -n "$validation_nonce" ] || fail "could not create an intake validation nonce"
  if ! contract_error=$(node - "$task" "$FIELDS" "$validation_nonce" "$contract_json" 2>&1 <<'NODE'
'use strict';
const vm = require('vm');

const [task, fieldText, validationNonce, domJson] = process.argv.slice(2);
const fields = fieldText.split(/\s+/);
const dom = JSON.parse(domJson);
const scripts = dom.scripts;
const attribute = (attrs, name) => Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null;
const hasAttribute = (attrs, name) => Object.prototype.hasOwnProperty.call(attrs, name);
const fail = (message) => {
  process.stderr.write(`${message}\n`);
  process.exit(1);
};

try {
  if (scripts.length === 0) fail('artifact has no executable intake script');
  const matchingForms = dom.forms.filter((form) => attribute(form.attrs, 'id') === 'feature-intake');
  if (matchingForms.length !== 1 || attribute(matchingForms[0].attrs, 'data-lavish-question') !== task) fail('artifact has no keyed intake question');
  const parsedForm = matchingForms[0];
  const elements = {};
  for (const field of fields) {
    const controls = parsedForm.controls.filter((control) => control.tag === 'textarea' && attribute(control.attrs, 'name') === field && attribute(control.attrs, 'data-lavish-intake-field') === field && hasAttribute(control.attrs, 'required'));
    if (controls.length !== 1) fail(`artifact is missing required field: ${field}`);
    elements[field] = { value: '' };
  }
  const submitControls = parsedForm.controls.filter((control) => (control.tag === 'button' || control.tag === 'input') && attribute(control.attrs, 'data-lavish-intake-submit') === 'true' && (attribute(control.attrs, 'type') || '').toLowerCase() === 'submit');
  if (submitControls.length !== 1) fail('artifact has no explicit intake submit control');
  const sentinels = Object.fromEntries(fields.map((field) => [field, `${validationNonce}-${field}`]));
  for (const field of fields) elements[field].value = sentinels[field];
  const submit = { disabled: false };
  const status = { textContent: '' };
  const listeners = {};
  const domForm = {
    elements,
    addEventListener(type, listener) {
      if (type === 'submit') listeners.submit = listener;
    },
    querySelector(selector) {
      return selector === '[data-lavish-intake-submit="true"]' ? submit : null;
    },
  };
  const document = {
    querySelector(selector) {
      if (selector === '#feature-intake') return domForm;
      if (selector === '#intake-status') return status;
      return null;
    },
  };
  const queued = [];
  const window = {
    lavish: {
      queuePrompt(title, choice) {
        queued.push({ title, choice });
      },
    },
  };
  const context = vm.createContext({ document, window }, {
    codeGeneration: { strings: false, wasm: false },
  });
  for (const script of scripts) {
    vm.runInContext(script, context, { timeout: 1000 });
  }
  if (typeof listeners.submit !== 'function') fail('artifact has no executable intake submit listener');
  let prevented = false;
  const event = { preventDefault() { prevented = true; } };
  listeners.submit(event);
  if (!prevented) fail('artifact submit listener does not prevent default submission');
  if (queued.length !== 1) fail('artifact submit listener did not queue exactly one answer');
  const data = queued[0].choice && queued[0].choice.data;
  if (!data || data.question !== task || data.answer !== 'submitted' || data.close !== 'release' || data.submitted !== true) {
    fail('artifact queued feedback does not match the intake contract');
  }
  if (!data.intake) {
    fail('artifact queued feedback is missing required intake fields');
  }
  if (fields.some((field) => data.intake[field] !== sentinels[field])) {
    fail('artifact queued feedback does not reflect submitted field values');
  }
  if (submit.disabled !== true) fail('artifact submit control remains enabled after queueing');
  listeners.submit(event);
  if (queued.length !== 1) fail('artifact submit listener queued duplicate feedback');
} catch (error) {
  fail(error && error.message ? error.message : 'artifact executable validation failed');
}
NODE
  ); then
    fail "$contract_error"
  fi
}

validate_exemption_reason() {
  local reason=$1 expected_task=${2-} detail normalized reason_task target action action_detail first_word target_words action_words meaningful_count action_meaningful_count
  validate_one_line "exemption reason" "$reason"
  case "$reason" in
    bug-fix:*|dependency:*|configuration:*|documentation:*|"behavior-preserving refactor":*) ;;
    *) fail "exemption reason must use bug-fix, dependency, configuration, documentation, or behavior-preserving refactor" ;;
  esac
  detail=${reason#*:}
  detail=$(printf '%s' "$detail" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
  if [[ "$detail" =~ ^task=([^;]+)\;[[:space:]]+target=([^;]+)\;[[:space:]]+action=([^;]+)$ ]]; then
    reason_task=${BASH_REMATCH[1]}
    target=${BASH_REMATCH[2]}
    action_detail=${BASH_REMATCH[3]}
  else
    fail "exemption reason must use task=<task-id>; target=<path-like subject>; action=<specific multiword change>"
  fi
  reason_task=$(printf '%s' "$reason_task" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
  validate_task_id "$reason_task"
  [ -n "$expected_task" ] && [ "$reason_task" = "$expected_task" ] \
    || fail "exemption reason task must match the requested task"
  target=$(printf '%s' "$target" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
  action_detail=$(printf '%s' "$action_detail" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
  [ -n "$target" ] && [ -n "$action_detail" ] \
    || fail "exemption reason must name a bounded target and action"
  [ "${#target}" -ge 8 ] && [ "${#action_detail}" -ge 8 ] \
    || fail "exemption reason must name a bounded scope with sufficient detail"
  target_words=$(printf '%s\n' "$target" | awk '{print NF}')
  action_words=$(printf '%s\n' "$action_detail" | awk '{print NF}')
  [ "$target_words" -ge 2 ] && [ "$action_words" -ge 3 ] \
    || fail "exemption reason must name a concrete target and action"
  action_meaningful_count=$(printf '%s\n' "$action_detail" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | awk '
    BEGIN {
      split("a an and are as at by for from in into is it no not of on or promptly safely skip the this to update with without behavior code details docs documentation fix implementation project source stuff", words)
      for (i in words) ignored[words[i]]=1
    }
    !ignored[$0] { count++ }
    END { print count + 0 }
  ')
  [ "$action_meaningful_count" -ge 2 ] \
    || fail "exemption reason must name a specific action with multiple meaningful terms"
  first_word=$(printf '%s\n' "$action_detail" | awk '{print $1}')
  action=$(printf '%s' "$first_word" | tr '[:upper:]' '[:lower:]')
  case "$action" in
    add|adjust|align|configure|correct|cover|disable|document|enable|exercise|fix|limit|migrate|pin|preserve|record|refactor|remove|replace|test|update|use|validate) ;;
    *) fail "exemption reason must start with a concrete action" ;;
  esac
  meaningful_count=$(printf '%s\n' "$target" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | awk '
    BEGIN {
      split("a an all any and area backend bar behavior broken change code every fix foo fixture here in item misc no none now of on problem project safely same something source stuff task that the thing this to update various whatever work", words)
      for (i in words) ignored[words[i]]=1
    }
    !ignored[$0] { count++ }
    END { print count + 0 }
  ')
  [ "$meaningful_count" -ge 3 ] \
    || fail "exemption reason must name a concrete target"
  [[ "$target" =~ (^|[[:space:]])[[:alnum:]_.-]+[./_-][[:alnum:]_.-]+($|[[:space:]]) ]] \
    || fail "exemption reason must name a path-like bounded target"
  normalized=$(printf '%s %s' "$target" "$action_detail" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ')
  printf '%s' "$normalized" | grep -Eiq '(^|[[:space:]])(foo|bar|code|project|stuff|now|safely|thing|something|whatever|misc|various|item|area)($|[[:space:]])' \
    && fail "exemption reason must name a concrete target"
  case "${normalized//[[:space:]]/}" in
    skip|none|na|n/a|not-applicable|notapplicable|todo|tbd|placeholder|nothing|something|whatever|misc|various) \
      fail "exemption reason must name a bounded scope, not a generic bypass" ;;
  esac
}

validate_intake_payload() {
  local payload=$1 task=$2
  printf '%s\n' "$payload" | perl -MJSON::PP -e '
    use strict; use warnings;
    my ($task) = @ARGV;
    local $/;
    my $data = eval { decode_json(<STDIN>) };
    die "invalid intake payload\n" unless ref($data) eq "HASH";
    die "intake payload has the wrong task\n"
      unless defined $data->{question} && !ref($data->{question}) && $data->{question} eq $task;
    die "intake payload is not submitted\n"
      unless ref($data->{submitted}) eq "JSON::PP::Boolean" && $data->{submitted};
    die "intake payload has the wrong answer\n"
      unless defined $data->{answer} && !ref($data->{answer}) && $data->{answer} eq "submitted";
    die "intake payload has the wrong release mode\n"
      unless defined $data->{close} && !ref($data->{close}) && $data->{close} eq "release";
    die "intake payload has no complete intake object\n" unless ref($data->{intake}) eq "HASH";
    for my $field (qw(product_goal intended_users use_cases scope non_goals constraints visual_product_references key_choices acceptance_criteria open_questions)) {
      my $value = $data->{intake}{$field};
      die "intake payload is missing $field\n"
        unless defined $value && !ref($value) && $value =~ /\S/;
    }
  ' "$task" || fail "captured feedback lacks a complete submitted intake payload"
}

result_is_captured_feedback() {
  local result=$1 artifact=$2 task=$3 retired=${4-} sid seq adapter inbox parent answer_rows found=0 key answer label close payload session_source sequence_floor marker
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
  [ -f "$(session_path "$task")" ] && [ ! -L "$(session_path "$task")" ] \
    || fail "no Lavish intake session is recorded for task $task"
  session_source=$(meta_value "$(session_path "$task")" source_id)
  [ -n "$session_source" ] && [ "$sid" = "$session_source" ] \
    || fail "captured result source does not match the active intake session"
  sequence_floor=$(meta_value "$(session_path "$task")" sequence_floor)
  if [ -n "$sequence_floor" ]; then
    case "$sequence_floor" in ''|*[!0-9]*) fail "intake session sequence floor is invalid" ;; esac
    [ "$seq" -gt "$sequence_floor" ] \
      || fail "captured result predates the active intake session"
  fi
  if [ "$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$sid" 2>/dev/null || true)" != "$task" ]; then
    [ "$retired" = allow-retired ] || fail "Lavish source is not bound to task $task"
    marker="$STATE/procevent/$sid.intake"
    [ -f "$marker" ] && [ ! -L "$marker" ] \
      && [ "$(meta_value "$marker" task_id)" = "$task" ] \
      && [ "$(meta_value "$marker" source_id)" = "$sid" ] \
      || fail "retired Lavish source is not durably owned by task $task"
    [ ! -e "$STATE/procevent/$sid.source" ] && [ ! -L "$STATE/procevent/$sid.source" ] \
      || fail "retired Lavish source is still registered"
  fi
  if [ "$retired" = allow-retired ]; then
    answer_rows=$("$SCRIPT_DIR/fm-procevent-lavish.sh" answers --intake --allow-retired "$result") \
      || fail "captured feedback could not be read"
  else
    answer_rows=$("$SCRIPT_DIR/fm-procevent-lavish.sh" answers --intake "$result") \
      || fail "captured feedback could not be read"
  fi
  while IFS=$'\t' read -r key answer label close; do
    [ -n "${key:-}" ] || continue
    [ "$key" = "$task" ] || fail "captured feedback contains an answer for another task"
    [ "$answer" = submitted ] || fail "intake answer must be submitted"
    [ "$close" = release ] || fail "intake answer must release held work"
    found=$((found + 1))
  done <<EOF
$answer_rows
EOF
  [ "$found" -eq 1 ] || fail "captured feedback has no single submitted answer for task $task"
  payload=$("$SCRIPT_DIR/fm-procevent-lavish.sh" intake "$result" "$task") \
    || fail "captured feedback lacks the intake submission payload"
  validate_intake_payload "$payload" "$task"
  printf '%s\t%s\n' "$sid" "$seq"
}

retire_record_source() {
  local task=$1 sid=$2 registration
  registration="$STATE/procevent/$sid.source"
  if [ -e "$registration" ] || [ -L "$registration" ]; then
    "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" --expect-intake-task "$task" >/dev/null \
      || fail "could not retire completed intake source $sid"
  fi
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

write_pending() {
  local task=$1 artifact=$2 result=$3 sid=$4 seq=$5 owner_token=$6 phase=${7:-held} dest tmp
  dest=$(pending_path "$task")
  tmp=$(mktemp "$STATE/.lavish-intake-pending.XXXXXX") || fail "cannot stage pending intake completion"
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$task"
    printf 'artifact=%s\n' "$artifact"
    printf 'result=%s\n' "$result"
    printf 'source_id=%s\n' "$sid"
    printf 'sequence=%s\n' "$seq"
    printf 'owner_token=%s\n' "$owner_token"
    printf 'phase=%s\n' "$phase"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$dest"
}

update_pending_phase() {
  local pending=$1 phase=$2
  write_pending \
    "$(meta_value "$pending" task_id)" \
    "$(meta_value "$pending" artifact)" \
    "$(meta_value "$pending" result)" \
    "$(meta_value "$pending" source_id)" \
    "$(meta_value "$pending" sequence)" \
    "$(meta_value "$pending" owner_token)" "$phase"
}

pending_matches() {
  local pending=$1 task=$2 artifact=$3 result=$4 sid=$5 seq=$6
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  [ "$(meta_value "$pending" version)" = 1 ] \
    && [ "$(meta_value "$pending" task_id)" = "$task" ] \
    && [ "$(meta_value "$pending" artifact)" = "$artifact" ] \
    && [ "$(meta_value "$pending" result)" = "$result" ] \
    && [ "$(meta_value "$pending" source_id)" = "$sid" ] \
    && [ "$(meta_value "$pending" sequence)" = "$seq" ] \
    && [ -n "$(meta_value "$pending" owner_token)" ] || return 1
  case "$(meta_value "$pending" phase)" in
    ''|held|released) ;;
    *) return 1 ;;
  esac
}

captured_sequence_floor() {
  local sid=$1 inbox candidate candidate_seq floor=0
  inbox="$STATE/procevent-inbox"
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || { printf '0\n'; return 0; }
  for candidate in "$inbox/$sid".*.result; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    candidate_seq=$(fm_procevent_result_sequence "$candidate")
    case "$candidate_seq" in ''|*[!0-9]*) continue ;; esac
    [ "$candidate_seq" -gt "$floor" ] && floor=$candidate_seq
  done
  printf '%s\n' "$floor"
}

legacy_task_is_in_flight() {
  local task=$1 meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  awk -F= -v task="$task" '
    $1 == "endpoint_task_id" { endpoint++; endpoint_value=$2 }
    $1 == "kind" { kind=$2 }
    $1 == "worktree" { worktree=$2 }
    $1 == "project" { project=$2 }
    $1 == "harness" { harness=$2 }
    END {
      exit !(endpoint == 1 && endpoint_value == task && (kind == "ship" || kind == "scout") && length(worktree) && length(project) && length(harness))
    }
  ' "$meta"
}

START_TASK=
START_ARTIFACT=
START_SID=
START_SESSION_TMP=
START_LOCK_PATH=
START_LOCK_HELD=0
START_HOLD_MARKER_CREATED=0
START_OWNER_TOKEN=
START_REQUEST_OWNER_TOKEN=
START_HOLD_REASON=
START_HOLD_CREATED=0
START_BINDING_CREATED=0
START_SESSION_CREATED=0
START_LAVISH_SESSION_OPENED=0
START_SOURCE_PREEXISTING=0
START_SOURCE_MARKER_CREATED=0
START_SOURCE_LOCK_PATH=
START_SOURCE_LOCK_HELD=0
START_OK=0
START_LAVISH_SESSION_CREATED=0

RECORD_LOCK_PATH=
RECORD_LOCK_HELD=0
record_cleanup() {
  if [ "$RECORD_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$RECORD_LOCK_PATH" || true
    RECORD_LOCK_HELD=0
  fi
}

EXEMPT_LOCK_PATH=
EXEMPT_LOCK_HELD=0
exempt_cleanup() {
  if [ "$EXEMPT_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$EXEMPT_LOCK_PATH" || true
    EXEMPT_LOCK_HELD=0
  fi
}

start_marker_matches() {
  local marker
  marker=$(intake_hold_path "$START_TASK")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(meta_value "$marker" task_id)" = "$START_TASK" ] \
    && [ "$(meta_value "$marker" owner_token)" = "$START_OWNER_TOKEN" ]
}

start_marker_attempt_matches() {
  local marker owner_token
  marker=$(intake_hold_path "$START_TASK")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(meta_value "$marker" task_id)" = "$START_TASK" ] \
    && [ "$(meta_value "$marker" hold_reason)" = "$START_HOLD_REASON" ] || return 1
  owner_token=$(meta_value "$marker" owner_token)
  [ "$owner_token" = "$START_OWNER_TOKEN" ] \
    || [ "$owner_token" = "$START_REQUEST_OWNER_TOKEN" ]
}

intake_hold_matches() {
  local task=$1 marker hold_reason owner_token
  marker=$(intake_hold_path "$task")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(meta_value "$marker" task_id)" = "$task" ] || return 1
  owner_token=$(meta_value "$marker" owner_token)
  hold_reason=$(meta_value "$marker" hold_reason)
  [ -n "$owner_token" ] && [ -n "$hold_reason" ] || return 1
  case "$owner_token" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  "$SCRIPT_DIR/fm-captain-hold.sh" intake-owner "$task" "$owner_token" "$hold_reason" >/dev/null 2>&1
}

start_task_has_owned_captain_hold() {
  "$SCRIPT_DIR/fm-captain-hold.sh" intake-owner "$START_TASK" \
    "$START_OWNER_TOKEN" "$START_HOLD_REASON" >/dev/null 2>&1
}

write_start_marker() {
  local marker tmp
  marker=$(intake_hold_path "$START_TASK")
  tmp=$(mktemp "$STATE/.lavish-intake-hold.XXXXXX") || fail "cannot stage intake ownership marker"
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$START_TASK"
    printf 'owner_token=%s\n' "$START_OWNER_TOKEN"
    printf 'hold_reason=%s\n' "$START_HOLD_REASON"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$marker"
  START_HOLD_MARKER_CREATED=1
}

source_marker_matches() {
  local marker
  [ -n "$START_SID" ] || return 1
  marker=$(intake_source_path "$START_SID")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(meta_value "$marker" task_id)" = "$START_TASK" ] \
    && [ "$(meta_value "$marker" source_id)" = "$START_SID" ] \
    && [ "$(meta_value "$marker" owner_token)" = "$START_OWNER_TOKEN" ]
}

write_source_marker() {
  local marker tmp
  marker=$(intake_source_path "$START_SID")
  mkdir -p "${marker%/*}" || fail "cannot create intake source state"
  tmp=$(mktemp "$STATE/.lavish-intake-source.XXXXXX") || fail "cannot stage intake source marker"
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$START_TASK"
    printf 'source_id=%s\n' "$START_SID"
    printf 'owner_token=%s\n' "$START_OWNER_TOKEN"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$marker"
  START_SOURCE_MARKER_CREATED=1
}

start_cleanup() {
  local status=$?
  if [ "$START_OK" -eq 1 ]; then
    if [ "$START_SOURCE_LOCK_HELD" -eq 1 ]; then
      fm_lock_release "$START_SOURCE_LOCK_PATH" || true
      START_SOURCE_LOCK_HELD=0
    fi
    if [ "$START_LOCK_HELD" -eq 1 ]; then
      fm_lock_release "$START_LOCK_PATH" || true
      START_LOCK_HELD=0
    fi
    return "$status"
  fi
  [ -z "$START_SESSION_TMP" ] || rm -f -- "$START_SESSION_TMP"
  if [ "$START_LAVISH_SESSION_CREATED" -eq 1 ]; then
    if ! lavish-axi end "$START_ARTIFACT" >/dev/null 2>&1; then
      printf 'fm-lavish-intake: could not end the Lavish intake session; preserving intake ownership state for retry\n' >&2
      if [ "$START_LOCK_HELD" -eq 1 ]; then
        fm_lock_release "$START_LOCK_PATH" || true
        START_LOCK_HELD=0
      fi
      if [ "$START_SOURCE_LOCK_HELD" -eq 1 ]; then
        fm_lock_release "$START_SOURCE_LOCK_PATH" || true
        START_SOURCE_LOCK_HELD=0
      fi
      return "$status"
    fi
  fi
  if [ "$START_SESSION_CREATED" -eq 1 ]; then
    rm -f -- "$(session_path "$START_TASK")"
  fi
  if [ "$START_SOURCE_MARKER_CREATED" -eq 1 ] && source_marker_matches; then
    rm -f -- "$(intake_source_path "$START_SID")"
  fi
  if [ -n "$START_SID" ] && [ "$START_BINDING_CREATED" -eq 1 ]; then
    "$SCRIPT_DIR/fm-captain-hold.sh" unbind "$START_SID" >/dev/null 2>&1 || true
  fi
  if [ -n "$START_SID" ] && [ "$START_SOURCE_PREEXISTING" -eq 0 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$START_ARTIFACT" >/dev/null 2>&1 || true
  fi
  if [ "$START_HOLD_CREATED" -eq 1 ] && start_task_has_owned_captain_hold; then
    if [ "$START_LOCK_HELD" -eq 1 ]; then
      fm_lock_release "$START_LOCK_PATH" || true
      START_LOCK_HELD=0
    fi
    "$SCRIPT_DIR/fm-captain-hold.sh" release "$START_TASK" \
      --intake-owner "$START_OWNER_TOKEN" >/dev/null 2>&1 || true
  fi
  if [ "$START_HOLD_MARKER_CREATED" -eq 1 ] && start_marker_attempt_matches \
    && ! start_task_has_owned_captain_hold; then
    rm -f -- "$(intake_hold_path "$START_TASK")"
  fi
  if [ "$START_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$START_LOCK_PATH" || true
    START_LOCK_HELD=0
  fi
  if [ "$START_SOURCE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$START_SOURCE_LOCK_PATH" || true
    START_SOURCE_LOCK_HELD=0
  fi
  return "$status"
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
  const submit = form.querySelector('[data-lavish-intake-submit="true"]');
  let submitted = false;
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    if (submitted) return;
    const intake = Object.fromEntries(fields.map((field) => [field, form.elements[field].value.trim()]));
    if (fields.some((field) => !intake[field])) {
      status.textContent = "Complete every field before queueing.";
      return;
    }
    submitted = true;
    submit.disabled = true;
    try {
      window.lavish.queuePrompt("Feature intake submitted", {
        tag: "choice",
        text: "Feature intake submitted",
        element: form,
        data: { question: task, answer: "submitted", close: "release", submitted: true, intake }
      });
      status.textContent = "Queued. Send this answer to the agent in Lavish.";
    } catch (error) {
      submitted = false;
      submit.disabled = false;
      status.textContent = "Could not queue the intake. Try again.";
    }
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
  local task=${1-} artifact='' reason='' sid mapping tmp task_show state hold_kind sequence_floor artifact_hash hold_output canonical_owner
  local existing_binding source_path
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
  START_TASK=$task
  START_OWNER_TOKEN="${BASHPID:-$$}.$RANDOM"
  START_REQUEST_OWNER_TOKEN=$START_OWNER_TOKEN
  START_HOLD_REASON="$reason"
  START_ARTIFACT=
  START_SID=
  START_SESSION_TMP=
  START_LOCK_PATH=$(intake_lock_path "$task")
  START_LOCK_HELD=0
  START_HOLD_MARKER_CREATED=0
  START_HOLD_CREATED=0
  START_BINDING_CREATED=0
  START_SESSION_CREATED=0
  START_LAVISH_SESSION_CREATED=0
  START_SOURCE_PREEXISTING=0
  START_SOURCE_MARKER_CREATED=0
  START_OK=0
  mkdir -p "$STATE" || fail "cannot create intake state directory"
  trap start_cleanup EXIT
  fm_lock_acquire_wait "$START_LOCK_PATH" || fail "could not lock intake task $task"
  START_LOCK_HELD=1
  [ ! -e "$(receipt_path "$task")" ] && [ ! -L "$(receipt_path "$task")" ] \
    || fail "intake evidence already exists for task $task"
  [ ! -e "$(session_path "$task")" ] && [ ! -L "$(session_path "$task")" ] \
    || fail "intake session already exists for task $task"
  [ ! -e "$(intake_hold_path "$task")" ] && [ ! -L "$(intake_hold_path "$task")" ] \
    || fail "intake ownership already exists for task $task"
  artifact=$(real_file "$artifact") || fail "artifact is not a regular file: $artifact"
  START_ARTIFACT=$artifact
  artifact_fields_present "$artifact" "$task"
  artifact_hash=$(sha256_file "$artifact")
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$artifact") \
    || fail "could not derive the Lavish source id"
  START_SID=$sid
  START_SOURCE_LOCK_PATH=$(intake_source_lock_path "$sid")
  fm_lock_acquire_wait "$START_SOURCE_LOCK_PATH" || fail "could not lock Lavish source setup: $sid"
  START_SOURCE_LOCK_HELD=1
  reject_existing_intake_ownership "$task" "$sid" "$artifact"
  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  task_show=$(cd "$FM_HOME" && tasks-axi show "$task" --full 2>/dev/null || true)
  [ -n "$task_show" ] || fail "task $task is not present in the active backlog"
  state=$(printf '%s\n' "$task_show" | sed -n 's/^  state: //p' | head -1)
  hold_kind=$(printf '%s\n' "$task_show" | sed -n 's/^  hold_kind: //p' | head -1)
  case "$hold_kind" in
    ''|null|\"null\"|-|\"-\") hold_kind= ;;
  esac
  [ "$state" != done ] || fail "task $task is already closed"
  if [ "$state" != done ] && [ "$hold_kind" = captain ]; then
    fail "task $task already carries an unrelated captain hold"
  elif [ "$state" != done ] && [ -n "$hold_kind" ] && [ "$hold_kind" != - ]; then
    fail "task $task already carries a non-captain hold"
  else
    write_start_marker
    fm_lock_release "$START_LOCK_PATH"
    START_LOCK_HELD=0
    if ! hold_output=$("$SCRIPT_DIR/fm-captain-hold.sh" hold "$task" --reason "$START_HOLD_REASON" \
      --intake-owner "$START_OWNER_TOKEN"); then
      fail "could not hold task for Lavish intake"
    fi
    canonical_owner=$(printf '%s\n' "$hold_output" | sed -n 's/^intake-owner=//p' | head -1)
    case "$canonical_owner" in
      ''|*[!A-Za-z0-9._-]*) fail "could not establish authoritative intake ownership" ;;
    esac
    START_OWNER_TOKEN=$canonical_owner
    START_HOLD_CREATED=1
    START_HOLD_REASON="${START_HOLD_REASON} [intake-owner=$START_OWNER_TOKEN]"
    write_start_marker
    fm_lock_acquire_wait "$START_LOCK_PATH" || fail "could not relock intake task $task"
    START_LOCK_HELD=1
    intake_hold_matches "$task" \
      || fail "could not prove intake captain-hold ownership"
  fi
  source_path="$STATE/procevent/$sid.source"
  if [ -e "$source_path" ] || [ -L "$source_path" ]; then
    START_SOURCE_PREEXISTING=1
    fail "Lavish source is already registered: $sid"
  fi
  existing_binding=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$sid" 2>/dev/null || true)
  [ -z "$existing_binding" ] \
    || fail "Lavish source is already bound to task $existing_binding"
  if lavish_session_active "$artifact"; then
    START_LAVISH_SESSION_CREATED=0
  else
    case "$?" in
      1) START_LAVISH_SESSION_CREATED=1 ;;
      *) fail "cannot safely determine whether the Lavish session already exists" ;;
    esac
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" "$task" --intake >/dev/null \
    || fail "could not bind Lavish source to task $task"
  START_BINDING_CREATED=1
  sequence_floor=$(captured_sequence_floor "$sid")
  mapping=$(session_path "$task")
  tmp=$(mktemp "$STATE/.lavish-intake-session.XXXXXX") || fail "cannot stage intake session"
  START_SESSION_TMP=$tmp
  {
    printf 'task_id=%s\n' "$task"
    printf 'artifact=%s\n' "$artifact"
    printf 'artifact_sha256=%s\n' "$artifact_hash"
    printf 'source_id=%s\n' "$sid"
    printf 'sequence_floor=%s\n' "$sequence_floor"
    printf 'lavish_session_created=%s\n' "$START_LAVISH_SESSION_CREATED"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$mapping"
  START_SESSION_TMP=
  START_SESSION_CREATED=1
  write_source_marker
  if lavish-axi "$artifact"; then
    :
  else
    fail "could not establish the Lavish intake session"
  fi
  "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$artifact" --intake >/dev/null \
    || fail "could not arm captured Lavish feedback"
  START_OK=1
  printf 'armed: %s\n' "$sid"
  printf 'next: submit this intake in Lavish; firstmate handles the captured feedback before dispatch\n'
}

cmd_record() {
  local task=${1-} artifact='' result='' answer_rows answer_row result_identity sid seq receipt pending out owner_token pending_phase session_artifact_hash
  local owner_route=0 show state hold_kind answer_key answer_rest answer label mode
  shift || true
  validate_task_id "$task"
  RECORD_LOCK_PATH=$(intake_lock_path "$task")
  fm_lock_acquire_wait "$RECORD_LOCK_PATH" || fail "could not lock intake task $task"
  RECORD_LOCK_HELD=1
  trap record_cleanup EXIT
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
  artifact_fields_present "$artifact" "$task"
  result=$(real_file "$result") || fail "captured result is not a regular file: $result"
  receipt=$(receipt_path "$task")
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || fail "intake evidence is unsafe: $receipt"
    [ "$(require_unique_meta "$receipt" artifact)" = "$artifact" ] \
      || fail "intake evidence belongs to a different artifact"
    [ "$(require_unique_meta "$receipt" result)" = "$result" ] \
      || fail "intake evidence belongs to a different captured result"
    verify_receipt "$task" "$receipt" allow-unhandled >/dev/null \
      || fail "existing intake evidence is not retryable"
    retire_record_source "$task" "$(require_unique_meta "$receipt" source_id)"
    "$SCRIPT_DIR/fm-captain-hold.sh" intake-owner-retire "$task" \
      || fail "could not clear completed intake ownership"
    printf 'recorded: %s\n' "$receipt"
    return 0
  fi
  [ -f "$(session_path "$task")" ] && [ ! -L "$(session_path "$task")" ] \
    || fail "no Lavish intake session is recorded for task $task"
  [ "$(meta_value "$(session_path "$task")" artifact)" = "$artifact" ] \
    || fail "artifact does not match recorded intake session"
  session_artifact_hash=$(meta_value "$(session_path "$task")" artifact_sha256)
  [ -n "$session_artifact_hash" ] \
    || fail "intake session has no artifact hash"
  [ "$session_artifact_hash" = "$(sha256_file "$artifact")" ] \
    || fail "artifact changed after the intake session started"
  result_identity=$(result_is_captured_feedback "$result" "$artifact" "$task")
  sid=${result_identity%%$'\t'*}
  seq=${result_identity#*$'\t'}
  answer_rows=$("$SCRIPT_DIR/fm-procevent-lavish.sh" answers --intake "$result") \
    || fail "captured intake answer could not be parsed"
  case "$answer_rows" in *$'\n'*) fail "captured intake contains multiple answers" ;; esac
  answer_row=$answer_rows
  answer_key=${answer_row%%$'\t'*}
  answer_rest=${answer_row#*$'\t'}
  answer=${answer_rest%%$'\t'*}
  answer_rest=${answer_rest#*$'\t'}
  label=${answer_rest%%$'\t'*}
  mode=${answer_rest#*$'\t'}
  [ "$answer_key" = "$task" ] && [ -n "$answer" ] && [ "$mode" = release ] \
    || fail "captured intake answer is not an exact release"
  pending=$(pending_path "$task")
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    pending_matches "$pending" "$task" "$artifact" "$result" "$sid" "$seq" \
      || fail "pending intake completion belongs to a different captured result"
    pending_phase=$(meta_value "$pending" phase)
    [ -n "$pending_phase" ] || pending_phase=held
  else
    intake_hold_matches "$task" \
      || fail "intake captain-hold ownership is no longer proven"
    owner_token=$(meta_value "$(intake_hold_path "$task")" owner_token)
    write_pending "$task" "$artifact" "$result" "$sid" "$seq" "$owner_token" held
    pending_phase=held
  fi
  show=$(cd "$FM_HOME" && tasks-axi show "$task" --full 2>/dev/null || true)
  [ -n "$show" ] || fail "pending intake completion task $task is absent"
  state=$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)
  hold_kind=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | head -1)
  case "$hold_kind" in
    ''|null|\"null\"|-|\"-\") hold_kind= ;;
  esac
  case "$pending_phase" in
    held)
      if [ "$state" != done ] && [ "$hold_kind" = captain ]; then
        intake_hold_matches "$task" \
          || fail "intake captain-hold ownership is no longer proven"
        owner_token=$(meta_value "$pending" owner_token)
        owner_route=1
      elif [ "$state" != done ] && [ -n "$hold_kind" ]; then
        fail "pending intake completion task $task carries another active hold"
      else
        owner_token=$(meta_value "$pending" owner_token)
        "$SCRIPT_DIR/fm-captain-hold.sh" intake-resolution "$task" "$owner_token" \
          "the captured result $sid sequence $seq" "$answer" "$label" >/dev/null \
          || fail "pending intake completion lacks matching captain release evidence"
        update_pending_phase "$pending" released
        pending_phase=released
      fi
      ;;
    released)
      [ "$state" = done ] || [ -z "$hold_kind" ] \
        || fail "pending intake completion task $task carries another active hold"
      owner_token=$(meta_value "$pending" owner_token)
      "$SCRIPT_DIR/fm-captain-hold.sh" intake-resolution "$task" "$owner_token" \
        "the captured result $sid sequence $seq" "$answer" "$label" >/dev/null \
        || fail "pending intake completion lacks matching captain release evidence"
      ;;
    *) fail "pending intake completion has an unknown phase" ;;
  esac
  if [ "$owner_route" -eq 1 ]; then
    fm_lock_release "$RECORD_LOCK_PATH"
    RECORD_LOCK_HELD=0
    out=$(printf '%s\n' "$answer_rows" \
      | "$SCRIPT_DIR/fm-captain-hold.sh" answers "$task" --exact \
          --intake-owner "$owner_token" \
          --source "the captured result $sid sequence $seq" 2>&1) \
      || fail "captured intake could not release held task: $out"
    fm_lock_acquire_wait "$RECORD_LOCK_PATH" || fail "could not relock intake task $task"
    RECORD_LOCK_HELD=1
    printf '%s\n' "$out" | grep -Eq 'closed:|answered:' \
      || fail "captured intake did not close through captain-hold: $out"
    update_pending_phase "$pending" released
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null \
    || fail "could not acknowledge captured Lavish result"
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    write_receipt "$task" significant "$artifact" "$result" ""
  else
    verify_receipt "$task" "$receipt" >/dev/null \
      || fail "captured intake evidence could not be completed"
  fi
  retire_record_source "$task" "$sid"
  "$SCRIPT_DIR/fm-captain-hold.sh" intake-owner-retire "$task" \
    || fail "could not clear completed intake ownership"
  rm -f -- "$(pending_path "$task")"
  printf 'recorded: %s\n' "$receipt"
}

cmd_exempt() {
  local task=${1-} reason='' artifact receipt tmp
  shift || true
  validate_task_id "$task"
  EXEMPT_LOCK_PATH=$(intake_lock_path "$task")
  fm_lock_acquire_wait "$EXEMPT_LOCK_PATH" || fail "could not lock intake task $task"
  EXEMPT_LOCK_HELD=1
  trap exempt_cleanup EXIT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || fail "--reason requires text"; reason=$2; shift 2 ;;
      --reason=*) reason=${1#*=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown exempt argument: $1" ;;
    esac
  done
  validate_exemption_reason "$reason" "$task"
  artifact="$STATE/$task.lavish-intake-classification"
  receipt=$(receipt_path "$task")
  mkdir -p "$STATE"
  intake_state_active_for_task "$task" \
    && fail "cannot record an exemption while Lavish intake is active for task $task"
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    [ -f "$receipt" ] && [ ! -L "$receipt" ] \
      || fail "intake evidence is unsafe: $receipt"
    fail "intake evidence already exists for task $task"
  fi
  if [ -e "$artifact" ] || [ -L "$artifact" ]; then
    [ -f "$artifact" ] && [ ! -L "$artifact" ] || fail "not-applicable classification marker is unsafe"
    [ "$(meta_value "$artifact" reason)" = "$reason" ] \
      || fail "existing exemption reason differs for task $task"
  else
    tmp=$(mktemp "$STATE/.lavish-intake-classification.XXXXXX") || fail "cannot stage exemption classification"
    printf 'not-applicable classification for %s\nreason=%s\n' "$task" "$reason" > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$artifact"
  fi
  write_receipt "$task" not-applicable "$artifact" "" "$reason"
}

verify_receipt() {
  local task=$1 receipt=$2 allow_unhandled=${3-} classification artifact result sid seq expected_artifact expected_result key value reason
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
    validate_exemption_reason "$reason" "$task"
    [ "$(require_unique_meta "$receipt" feedback)" = not-applicable ] \
      || fail "not-applicable evidence has wrong feedback marker"
    printf 'status=not-applicable\nreason=%s\n' "$reason"
    return 0
  fi
  artifact_fields_present "$artifact" "$task"
  result=$(require_unique_meta "$receipt" result)
  result=$(real_file "$result") || fail "captured intake result is missing or unsafe: $result"
  expected_result=$(require_unique_meta "$receipt" result_sha256)
  [ "$expected_result" = "$(sha256_file "$result")" ] \
    || fail "captured intake result hash does not match evidence"
  sid=$(require_unique_meta "$receipt" source_id)
  seq=$(require_unique_meta "$receipt" sequence)
  [ "$(fm_procevent_result_source_id "$result")" = "$sid" ] || fail "result source identity changed"
  [ "$(fm_procevent_result_sequence "$result")" = "$seq" ] || fail "result sequence changed"
  if [ "$allow_unhandled" != allow-unhandled ]; then
    [ -f "$STATE/procevent-inbox/$sid.$seq.handled" ] \
      && [ ! -L "$STATE/procevent-inbox/$sid.$seq.handled" ] \
      || fail "captured intake result is not durably acknowledged"
  fi
  result_is_captured_feedback "$result" "$artifact" "$task" allow-retired >/dev/null
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
  local task=${1-} brief=${2-} contract evidence reason receipt receipt_reason
  [ "$#" -eq 2 ] || fail "check-brief requires <task-id> <brief.md>"
  validate_task_id "$task"
  brief=$(real_file "$brief") || fail "brief is not a regular file: $brief"
  contract=$(brief_value 'Lavish intake contract: ' "$brief")
  if [ -z "$contract" ]; then
    legacy_task_is_in_flight "$task" || fail "brief has no intake contract and task has no existing in-flight endpoint record"
    printf 'status=legacy\n'
    return 0
  fi
  case "$contract" in
    submitted)
      evidence=$(brief_value 'Lavish intake evidence: ' "$brief")
      [ -n "$evidence" ] || fail "submitted brief has no intake evidence"
      verify_receipt "$task" "$evidence"
      ;;
    not-applicable)
      reason=$(brief_value 'Lavish intake reason: ' "$brief")
      [ -n "$reason" ] || fail "not-applicable brief has no concrete reason"
      receipt=$(receipt_path "$task")
      receipt_reason=$(require_unique_meta "$receipt" reason)
      [ "$receipt_reason" = "$reason" ] || fail "not-applicable reason does not match intake evidence"
      verify_receipt "$task" "$receipt"
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
