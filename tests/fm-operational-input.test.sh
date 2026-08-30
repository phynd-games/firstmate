#!/usr/bin/env bash
# Canonical current and isolated legacy operational-input protocol matrices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-operational-input.sh"
TMP_ROOT=$(fm_test_tmproot fm-operational-input)
# shellcheck source=/dev/null
. "$OWNER"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

test_current_generic_matrix() {
  local kind body encoded parsed stripped prefix_hex
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "current operational prefix lost the landed U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome; do
    body="CURRENT_BODY_FOR_${kind}"
    fm_operational_input_encode "$kind" "$body" encoded \
      || fail "could not encode current $kind fixture"
    fm_operational_input_kind "$encoded" parsed \
      || fail "could not parse current $kind fixture"
    [ "$parsed" = "$kind" ] \
      || fail "current $kind fixture became $parsed"
    [ "$(kind_cli "$encoded")" = "$kind" ] \
      || fail "cross-language CLI lost current $kind"
    [ "$(classify_cli "$encoded")" = "$kind" ] \
      || fail "classifier lost current $kind"
    fm_operational_input_body "$encoded" stripped \
      || fail "could not recover current $kind body"
    [ "$stripped" = "$body" ] \
      || fail "current $kind body changed during encode/parse"
  done
  pass "operational input: every current generic envelope retains its exact structured kind"
}

test_current_from_firstmate_carrier() {
  local encoded parsed separator
  separator=$(printf '\342\201\243')
  fm_message_mark_from_firstmate "corr=0123456789abcdef inspect the report" encoded
  [ "${encoded#"[fm-from-firstmate]$separator"}" != "$encoded" ] \
    || fail "from-firstmate lost its live-charter-compatible leading carrier"
  fm_operational_input_kind "$encoded" parsed \
    || fail "from-firstmate current carrier did not parse"
  [ "$parsed" = from-firstmate ] \
    || fail "from-firstmate current carrier became $parsed"
  [ "$(classify_cli "$encoded")" = from-firstmate ] \
    || fail "cross-language classifier lost from-firstmate"
  pass "operational input: the established from-firstmate carrier remains structurally typed and byte-compatible"
}

test_landed_untyped_prefix_is_explicitly_legacy() {
  local untyped legacy_v parsed
  untyped="${FM_OPERATIONAL_PREFIX}body whose historical subtype is unknowable"
  fm_legacy_operational_input_kind "$untyped" parsed \
    || fail "landed untyped FIRSTMATE_OP input was not retained"
  [ "$parsed" = legacy-operational ] \
    || fail "landed untyped FIRSTMATE_OP input falsely became $parsed"
  ! fm_operational_input_kind "$untyped" parsed \
    || fail "untyped FIRSTMATE_OP input passed the current typed parser"
  [ "$(classify_cli "$untyped")" = legacy-operational ] \
    || fail "CLI did not expose the untyped prefix as legacy-operational"
  legacy_v="${FM_OPERATIONAL_PREFIX}vintage body from a legacy transcript"
  [ "$(classify_cli "$legacy_v")" = legacy-operational ] \
    || fail "legacy FIRSTMATE_OP body beginning with v was not retained"
  [ "$(classify_cli "${FM_OPERATIONAL_PREFIX}v2 legacy body")" = legacy-operational ] \
    || fail "ambiguous numeric legacy FIRSTMATE_OP body was not retained"
  [ "$(classify_cli "${FM_OPERATIONAL_PREFIX}v2")" = legacy-operational ] \
    || fail "malformed legacy FIRSTMATE_OP body was not retained"
  ! fm_operational_input_classify "${FM_OPERATIONAL_PREFIX}v2 watcher: unknown" parsed \
    || fail "unknown versioned FIRSTMATE_OP envelope downgraded to legacy"
  pass "operational input: untyped landed FIRSTMATE_OP transcripts are explicit legacy-operational input"
}

test_isolated_legacy_matrix() {
  local watcher turnend away parsed
  watcher="${FM_LEGACY_WATCHER_PREFIX}signal: legacy${FM_LEGACY_WATCHER_SUFFIX}"
  turnend="${FM_LEGACY_TURNEND_PREFIX}watcher: FAILED - legacy"
  away="${FM_LEGACY_AWAY_PREFIX}1 event(s)): done: legacy"

  for fixture in \
    "session-start|$FM_LEGACY_SESSIONSTART" \
    "watcher|$watcher" \
    "turn-end-guard|$turnend" \
    "away-supervisor|$away"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture leaked into the current parser"
    fm_legacy_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture was not recognized"
    [ "$parsed" = "$expected" ] \
      || fail "legacy $expected fixture became $parsed"
  done
  pass "operational input: historical prose compatibility is isolated from current parsing"
}

test_genuine_near_misses_remain_unclassified() {
  local marker fixture parsed
  marker=$FM_OPERATIONAL_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_operational_input_classify "$fixture" parsed \
      || fail "genuine near miss was classified as $parsed: $fixture"
    [ -z "$(classify_cli "$fixture" || true)" ] \
      || fail "CLI classified a genuine near miss: $fixture"
  done <<EOF
Captain quote: ${FM_OPERATIONAL_PREFIX}v1 watcher
FIRSTMATE_OP: v1 watcher
$marker arbitrary captain text
Captain quote: $FM_LEGACY_SESSIONSTART
${FM_LEGACY_SESSIONSTART} Please explain this sentence.
FIRSTMATE WATCHER WAKE: can you explain this phrase?
TURN WOULD END BLIND - can you make this warning friendlier?
Supervisor escalate (1 event(s)): is this wording clear?
[fm-from-firstmate] inspect this visible label
EOF
  pass "operational input: quoted, ASCII-only, arbitrary-U+2063, altered-legacy, and label-only near misses stay genuine"
}

test_cross_language_adapter_uses_the_owner() {
  local encoded parsed
  encoded=$(FM_TEST_ROOT="$ROOT" HELPER="$ROOT/.opencode/plugins/lib/fm-operational-input.js" \
    node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const { encodeFirstmateOperationalInput } = await import(pathToFileURL(process.env.HELPER).href);
process.stdout.write(await encodeFirstmateOperationalInput(process.env.FM_TEST_ROOT, "watcher", "CROSS_LANGUAGE_BODY"));
JS
  ) || fail "OpenCode cross-language adapter could not invoke the canonical owner"
  fm_operational_input_kind "$encoded" parsed \
    || fail "OpenCode cross-language adapter returned an invalid current envelope"
  [ "$parsed" = watcher ] \
    || fail "OpenCode cross-language adapter changed watcher to $parsed"
  pass "operational input: the OpenCode adapter constructs through the canonical owner"
}

test_invalid_current_encodings_are_rejected() {
  local output malformed parsed unknown_version
  output=$(printf 'body' | "$OWNER" encode legacy-operational 2>/dev/null) \
    && fail "legacy-operational was accepted as a current producer kind"
  [ -z "$output" ] || fail "invalid current kind printed protocol data"
  output=$(printf '' | "$OWNER" encode watcher 2>/dev/null) \
    && fail "empty current operational body was accepted"
  [ -z "$output" ] || fail "empty current body printed protocol data"
  malformed="${FM_OPERATIONAL_HEADER_PREFIX}watcher: "
  ! fm_operational_input_classify "$malformed" parsed \
    || fail "malformed current input downgraded into legacy kind $parsed"
  unknown_version="${FM_OPERATIONAL_PREFIX}v2 watcher: body"
  ! fm_operational_input_classify "$unknown_version" parsed \
    || fail "unknown operational wire version downgraded into $parsed"
  output=$(printf '%s' "$malformed" | "$OWNER" inspect 2>/dev/null) \
    && fail "structural inspection accepted malformed current input"
  [ -z "$output" ] || fail "malformed current inspection emitted a trust report"
  pass "operational input: malformed current construction is rejected without legacy downgrade"
}

test_agent_interchange_schema_and_trust_boundaries() {
  local schema body kind encoded first second limit at_limit oversized parsed schema_kinds runtime_kinds
  schema="$TMP_ROOT/agent-interchange-schema.json"
  "$OWNER" schema > "$schema" || fail "agent interchange schema command failed"
  python3 - "$schema" <<'PY' || fail "agent interchange schema trust constraints differ"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    schema = json.load(handle)
assert schema["$id"] == "firstmate.agent-interchange.v1"
properties = schema["properties"]
assert properties["authorization_granted"]["const"] is False
assert properties["provenance_verified"]["const"] is False
assert properties["body_byte_count"]["maximum"] == 1048576
assert set(properties["kind"]["enum"]) == {
    "away-supervisor", "branch-outcome", "from-firstmate", "launch-brief",
    "session-start", "turn-end-guard", "watcher",
}
PY
  schema_kinds=$(python3 - "$schema" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print("\n".join(sorted(json.load(handle)["properties"]["kind"]["enum"])))
PY
  )
  runtime_kinds=$(printf '%s\n' "$FM_OPERATIONAL_KINDS from-firstmate" | tr ' ' '\n' | LC_ALL=C sort)
  [ "$runtime_kinds" = "$schema_kinds" ] \
    || fail "runtime kinds differ from agent interchange schema"

  while IFS= read -r kind; do
    body="bounded instructions for $kind"
    [ "$kind" != launch-brief ] || body="bounded 😀 instructions for $kind"
    fm_operational_input_construct "$kind" "$body" encoded \
      || fail "schema-declared kind $kind did not construct"
    first=$(printf '%s' "$encoded" | "$OWNER" inspect) \
      || fail "schema-declared kind $kind did not inspect"
    second=$(printf '%s' "$encoded" | "$OWNER" inspect) \
      || fail "schema-declared kind $kind did not inspect twice"
    [ "$first" = "$second" ] || fail "$kind inspection was not deterministic"
    BODY="$body" KIND="$kind" INSPECTION="$first" python3 - <<'PY' \
      || fail "$kind inspection misstated structure or trust"
import hashlib
import json
import os

report = json.loads(os.environ["INSPECTION"])
body = os.environ["BODY"].encode()
assert report["kind"] == os.environ["KIND"]
assert report["body_byte_count"] == len(body)
assert report["body_sha256"] == hashlib.sha256(body).hexdigest()
assert report["structurally_valid"] is True
assert report["authorization_granted"] is False
assert report["provenance_verified"] is False
assert report["provenance_evidence"] == "body-sha256-only"
PY
    fm_operational_input_kind "$encoded" parsed || fail "$kind inspection fixture no longer parses"
    [ "$parsed" = "$kind" ] || fail "$kind inspection fixture parsed as $parsed"
  done < <(python3 - "$schema" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print("\n".join(json.load(handle)["properties"]["kind"]["enum"]))
PY
  )

  limit=$(python3 - "$schema" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["properties"]["body_byte_count"]["maximum"])
PY
  )
  [ "$limit" -eq "$FM_OPERATIONAL_MAX_BODY_BYTES" ] \
    || fail "runtime body limit $FM_OPERATIONAL_MAX_BODY_BYTES differs from schema $limit"
  at_limit=$(python3 -c "import sys; sys.stdout.write('x' * $limit)")
  fm_operational_input_construct launch-brief "$at_limit" encoded \
    || fail "schema-maximum launch brief was rejected"
  oversized="${at_limit}x"
  ! fm_operational_input_construct launch-brief "$oversized" encoded \
    || fail "oversized launch brief was accepted"
  ! fm_operational_input_construct from-firstmate "$oversized" encoded \
    || fail "oversized secondmate instruction was accepted"
  pass "agent interchange: runtime matches schema and structural evidence grants no trust"
}

test_current_generic_matrix
test_current_from_firstmate_carrier
test_landed_untyped_prefix_is_explicitly_legacy
test_isolated_legacy_matrix
test_genuine_near_misses_remain_unclassified
test_cross_language_adapter_uses_the_owner
test_invalid_current_encodings_are_rejected
test_agent_interchange_schema_and_trust_boundaries
