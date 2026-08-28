#!/usr/bin/env bash
# Behavioral tests for the immutable factory source and normalized execution-
# manifest validator. All assertions drive the public CLI and inspect its JSON.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/fm-factory-manifest.py"
SOURCE="$ROOT/assets/local-software-factory-m1/phynd-firstmate-local-software-factory-m1-tasks.json"
SOURCE_SHA=9046dee80162c391a320df074a1b888c1e0c88fa69f8a6e04788f0d32d1a0b63
TMP_ROOT=$(fm_test_tmproot fm-factory-manifest)

assert_present "$CLI" "factory manifest CLI is missing"
[ -x "$CLI" ] || fail "factory manifest CLI must be executable"
assert_present "$SOURCE" "immutable source fixture is missing"

json_assert() {
  local file=$1 expression=$2 label=$3
  if ! python3 - "$file" "$expression" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
if not eval(sys.argv[2], {"__builtins__": {}}, {"r": value, "len": len, "set": set}):
    raise SystemExit(1)
PY
  then
    fail "$label"
  fi
}

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

mutate_source() {
  local mode=$1 output=$2
  python3 - "$SOURCE" "$mode" "$output" <<'PY'
import json
import pathlib
import sys

source, mode, output = sys.argv[1:]
doc = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
if mode == "nested-mismatch":
    doc["epics"][0]["tasks"][0][1] = "Changed only in nested form"
elif mode == "count-mismatch":
    doc["task_count"] = 120
elif mode == "duplicate-id":
    doc["tasks"][1]["id"] = doc["tasks"][0]["id"]
elif mode == "unknown-dependency":
    doc["tasks"][0]["dependencies"] = ["E9.99"]
    doc["epics"][0]["tasks"][0][5] = ["E9.99"]
elif mode == "cycle":
    doc["tasks"][0]["dependencies"] = ["E0.02"]
    doc["epics"][0]["tasks"][0][5] = ["E0.02"]
else:
    raise SystemExit(f"unknown mutation: {mode}")
pathlib.Path(output).write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
PY
}

error_codes_include() {
  local file=$1 code=$2
  json_assert "$file" "'$code' in set(e['code'] for e in r['errors'])" "expected error code $code"
}

run_invalid_source() {
  local mode=$1 expected_code=$2 fixture report sha rc
  fixture="$TMP_ROOT/source-$mode.json"
  report="$TMP_ROOT/source-$mode-report.json"
  mutate_source "$mode" "$fixture"
  sha=$(sha256_file "$fixture")
  set +e
  "$CLI" validate-source --source "$fixture" --expected-sha256 "$sha" >"$report"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "$mode source fixture should exit 1, got $rc"
  json_assert "$report" "r['valid'] is False" "$mode source fixture should be invalid"
  error_codes_include "$report" "$expected_code"
}

test_schema_interface() {
  local name expected
  while read -r name expected; do
    "$CLI" schema "$name" >"$TMP_ROOT/schema-$name.json" || fail "schema $name failed"
    json_assert "$TMP_ROOT/schema-$name.json" "r['\$id'] == '$expected'" "schema $name has wrong versioned ID"
  done <<'EOF'
source phynd-firstmate-m1-task-graph.v1
execution-manifest firstmate.m1-execution-manifest.v1
task firstmate.execution-task.v1
route firstmate.route-request.v1
EOF
  json_assert "$TMP_ROOT/schema-execution-manifest.json" "r['properties']['authority']['properties']['approval_id']['minLength'] == 1" "approval IDs must be non-empty in the published schema"
  json_assert "$TMP_ROOT/schema-task.json" "r['properties']['source_refs']['minItems'] == 1" "source references must be non-empty in the published schema"
  pass "public CLI exposes all four versioned schemas"
}

test_known_source_graph() {
  local report="$TMP_ROOT/source-report.json" second="$TMP_ROOT/source-report-second.json"
  [ "$(sha256_file "$SOURCE")" = "$SOURCE_SHA" ] || fail "preserved source fixture bytes changed"
  "$CLI" validate-source --source "$SOURCE" --expected-sha256 "$SOURCE_SHA" >"$report" || fail "known source did not validate"
  "$CLI" validate-source --source "$SOURCE" --expected-sha256 "$SOURCE_SHA" >"$second" || fail "repeat source validation failed"
  cmp -s "$report" "$second" || fail "source validation report is not byte-stable"
  json_assert "$report" "r['valid'] is True and r['errors'] == []" "known source should be valid"
  json_assert "$report" "r['input']['byte_count'] == 121697 and r['provenance']['matches'] is True" "source provenance facts differ"
  json_assert "$report" "r['graph']['declared_task_count'] == 121 and r['graph']['flat_task_count'] == 121 and r['graph']['nested_task_count'] == 121" "task counts differ"
  json_assert "$report" "r['graph']['epic_count'] == 8 and r['graph']['dependency_edge_count'] == 193" "epic or edge count differs"
  json_assert "$report" "r['graph']['cycle_count'] == 0 and r['graph']['wave_count'] == 26" "cycle or wave count differs"
  json_assert "$report" "r['graph']['roots'] == ['E0.01', 'E5.01'] and r['graph']['nested_flat_equal'] is True" "root or representation facts differ"
  json_assert "$report" "r['graph']['acceptance_reachability']['covered_task_count'] == 88 and r['graph']['acceptance_reachability']['uncovered_task_count'] == 33" "acceptance reachability facts differ"
  pass "known source reproduces 121 tasks, 8 epics, 193 edges, 0 cycles, 26 waves, and two roots"
}

test_provenance_rejection() {
  local report="$TMP_ROOT/bad-provenance.json" rc
  set +e
  "$CLI" validate-source --source "$SOURCE" --expected-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$report"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "bad provenance should exit 1, got $rc"
  error_codes_include "$report" provenance.mismatch
  json_assert "$report" "r['provenance']['matches'] is False" "provenance mismatch was not reported"
  pass "source provenance mismatch is rejected"
}

test_malformed_source_fixtures() {
  run_invalid_source nested-mismatch representation.mismatch
  run_invalid_source count-mismatch count.declared
  run_invalid_source duplicate-id id.duplicate-flat-task
  run_invalid_source unknown-dependency graph.unknown-dependency
  run_invalid_source cycle graph.cycle
  pass "malformed source fixtures reject mismatches, counts, IDs, edges, and cycles"
}

write_manifest() {
  local mode=$1 output=$2
  python3 - "$mode" "$output" <<'PY'
import hashlib
import json
import pathlib
import sys

mode, output = sys.argv[1:]
def route(level="L3"):
    return {"schema": "firstmate.route-request.v1", "level_floor": level, "role": "implementer"}
def task(task_id, dependencies):
    return {
        "schema": "firstmate.execution-task.v1",
        "id": task_id,
        "title": "Task " + task_id,
        "kind": "ship",
        "dependencies": dependencies,
        "route_request": route(),
        "delivery": {"mode": "no-mistakes", "yolo": False},
        "artifacts": [],
        "acceptance": ["Behavior is verified through the public CLI."],
        "rollback": ["Remove the behavior-free manifest artifact."],
        "source_refs": ["E0.01"],
    }
doc = {
    "schema": "firstmate.m1-execution-manifest.v1",
    "manifest_id": "m1-local-factory-001",
    "validator": {"name": "firstmate_factory", "version": "1.0.0"},
    "source": [{
        "path": "assets/local-software-factory-m1/phynd-firstmate-local-software-factory-m1-tasks.json",
        "sha256": "9046dee80162c391a320df074a1b888c1e0c88fa69f8a6e04788f0d32d1a0b63",
        "schema": "phynd-firstmate-m1-task-graph.v1",
    }],
    "plan": {"artifact_sha256": "1" * 64, "repo_commit": "2" * 40},
    "authority": {"state": "draft", "approval_id": None, "scope": ["M1-001", "M1-002", "M1-003"]},
    "tasks": [task("M1-001", []), task("M1-002", []), task("M1-003", ["M1-001", "M1-002"])],
    "acceptance_tasks": ["M1-003"],
    "gates": ["D0"],
    "not_in_m1": ["Runtime authority changes"],
}
if mode == "bad-route":
    doc["tasks"][0]["route_request"]["level_floor"] = "L9"
elif mode == "unknown-dependency":
    doc["tasks"][2]["dependencies"] = ["M1-999"]
elif mode == "cycle":
    doc["tasks"][0]["dependencies"] = ["M1-003"]
elif mode == "empty-source-ref":
    doc["tasks"][0]["source_refs"] = []
elif mode == "unknown-source-ref":
    doc["tasks"][0]["source_refs"] = ["E999.99"]
elif mode not in ("valid", "bad-hash"):
    raise SystemExit(f"unknown mode: {mode}")
canonical = (json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
doc["manifest_hash"] = hashlib.sha256(canonical).hexdigest()
if mode == "bad-hash":
    doc["manifest_hash"] = "0" * 64
pathlib.Path(output).write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

test_normalized_manifest() {
  local manifest="$TMP_ROOT/manifest.json" report="$TMP_ROOT/manifest-report.json" second="$TMP_ROOT/manifest-report-second.json"
  write_manifest valid "$manifest"
  "$CLI" validate-manifest --manifest "$manifest" --source "$SOURCE" >"$report" || fail "normalized execution manifest did not validate"
  "$CLI" validate-manifest --manifest "$manifest" --source "$SOURCE" >"$second" || fail "repeat execution manifest validation failed"
  cmp -s "$report" "$second" || fail "execution manifest validation report is not byte-stable"
  json_assert "$report" "r['valid'] is True and r['manifest_hash']['matches'] is True and r['source_provenance']['source_valid'] is True" "valid manifest report differs"
  json_assert "$report" "r['graph']['task_count'] == 3 and r['graph']['roots'] == ['M1-001', 'M1-002'] and r['graph']['wave_count'] == 2" "manifest graph facts differ"
  json_assert "$report" "r['graph']['acceptance_reachability']['covered_task_count'] == 3 and r['graph']['acceptance_reachability']['uncovered_task_count'] == 0" "manifest acceptance does not cover all tasks"
  pass "normalized manifest validates hashes, routes, DAG waves, roots, and acceptance reachability"
}

run_invalid_manifest() {
  local mode=$1 expected_code=$2 manifest report rc
  manifest="$TMP_ROOT/manifest-$mode.json"
  report="$TMP_ROOT/manifest-$mode-report.json"
  write_manifest "$mode" "$manifest"
  set +e
  "$CLI" validate-manifest --manifest "$manifest" --source "$SOURCE" >"$report"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "$mode manifest fixture should exit 1, got $rc"
  error_codes_include "$report" "$expected_code"
}

test_malformed_manifest_fixtures() {
  local manifest="$TMP_ROOT/manifest-source-drift.json" source="$TMP_ROOT/manifest-tampered-source.json" report="$TMP_ROOT/manifest-source-drift-report.json" rc
  run_invalid_manifest bad-route schema.enum
  run_invalid_manifest unknown-dependency graph.unknown-dependency
  run_invalid_manifest cycle graph.cycle
  run_invalid_manifest empty-source-ref schema.min-items
  run_invalid_manifest unknown-source-ref provenance.unknown-source-ref
  run_invalid_manifest bad-hash manifest.hash-mismatch
  write_manifest valid "$manifest"
  mutate_source count-mismatch "$source"
  set +e
  "$CLI" validate-manifest --manifest "$manifest" --source "$source" >"$report"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "source-drift manifest fixture should exit 1, got $rc"
  error_codes_include "$report" manifest.source-hash-mismatch
  pass "malformed manifest fixtures reject routes, edges, cycles, hash drift, and source drift"
}

test_malformed_json_limits() {
  local oversized="$TMP_ROOT/oversized-integer.json" deep="$TMP_ROOT/deep-json.json" report rc
  python3 - "$oversized" "$deep" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(b'{"value":' + b'9' * 5000 + b'}')
pathlib.Path(sys.argv[2]).write_bytes(b'[' * 2000 + b']' * 2000)
PY
  for fixture in "$oversized" "$deep"; do
    report="$fixture.report"
    set +e
    "$CLI" validate-source --source "$fixture" --expected-sha256 "$(sha256_file "$fixture")" >"$report"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "malformed JSON should exit 1, got $rc"
    json_assert "$report" "r['valid'] is False and r['errors']" "malformed JSON should produce a validation report"
  done
  error_codes_include "$oversized.report" json.parse-limit
  pass "oversized integers and deep JSON produce deterministic validation reports"
}

write_long_chain_manifest() {
  local output=$1
  python3 - "$output" <<'PY'
import hashlib
import json
import pathlib
import sys

source_sha = "9046dee80162c391a320df074a1b888c1e0c88fa69f8a6e04788f0d32d1a0b63"
def task(index):
    task_id = f"M{index:04d}-001"
    dependency = f"M{index + 1:04d}-001" if index < 1000 else None
    return {
        "schema": "firstmate.execution-task.v1",
        "id": task_id,
        "title": "Long chain task",
        "kind": "ship",
        "dependencies": [dependency] if dependency else [],
        "route_request": {"schema": "firstmate.route-request.v1", "level_floor": "L3", "role": "implementer"},
        "delivery": {"mode": "no-mistakes", "yolo": False},
        "artifacts": [],
        "acceptance": ["The long chain validates."],
        "rollback": ["Remove the long chain manifest."],
        "source_refs": ["E0.01"],
    }
tasks = [task(index) for index in range(1001)]
doc = {
    "schema": "firstmate.m1-execution-manifest.v1",
    "manifest_id": "m1-long-chain",
    "validator": {"name": "firstmate_factory", "version": "1.0.0"},
    "source": [{"path": "assets/local-software-factory-m1/phynd-firstmate-local-software-factory-m1-tasks.json", "sha256": source_sha, "schema": "phynd-firstmate-m1-task-graph.v1"}],
    "plan": {"artifact_sha256": "1" * 64, "repo_commit": "2" * 40},
    "authority": {"state": "draft", "approval_id": None, "scope": ["M0000-001"]},
    "tasks": tasks,
    "acceptance_tasks": ["M0000-001"],
    "gates": [],
    "not_in_m1": [],
}
canonical = (json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
doc["manifest_hash"] = hashlib.sha256(canonical).hexdigest()
pathlib.Path(sys.argv[1]).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

test_long_chain_and_surrogate_inputs() {
  local long_manifest="$TMP_ROOT/long-chain-manifest.json" long_report="$TMP_ROOT/long-chain-report.json"
  local surrogate_manifest="$TMP_ROOT/surrogate-manifest.json" surrogate_report="$TMP_ROOT/surrogate-report.json" rc
  write_long_chain_manifest "$long_manifest"
  "$CLI" validate-manifest --manifest "$long_manifest" --source "$SOURCE" >"$long_report" || fail "long dependency chain should validate without recursion failure"
  json_assert "$long_report" "r['valid'] is True and r['graph']['task_count'] == 1001 and r['graph']['cycle_count'] == 0 and r['graph']['wave_count'] == 1001" "long dependency chain report differs"

  write_manifest valid "$surrogate_manifest"
  python3 - "$surrogate_manifest" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
doc["tasks"][0]["title"] = "\ud800"
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
  set +e
  "$CLI" validate-manifest --manifest "$surrogate_manifest" --source "$SOURCE" >"$surrogate_report"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "lone surrogate input should exit 1, got $rc"
  json_assert "$surrogate_report" "r['valid'] is False and set(e['code'] for e in r['errors']) == {'json.unicode'}" "lone surrogate should produce a deterministic validation report"
  pass "long dependency chains and lone surrogates are handled safely"
}

test_read_only_execution() {
  local sandbox="$TMP_ROOT/read-only" before after
  mkdir -p "$sandbox"
  cp "$SOURCE" "$sandbox/source.json"
  before=$(find "$sandbox" -type f -print | LC_ALL=C sort)
  HOME="$sandbox/home-that-does-not-exist" "$CLI" validate-source \
    --source "$sandbox/source.json" --expected-sha256 "$SOURCE_SHA" >/dev/null \
    || fail "read-only source validation failed"
  after=$(find "$sandbox" -type f -print | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "validation created or removed files in its input sandbox"
  [ "$(sha256_file "$sandbox/source.json")" = "$SOURCE_SHA" ] || fail "validation changed source bytes"
  pass "validation leaves source bytes and input directory unchanged"
}

test_schema_interface
test_known_source_graph
test_provenance_rejection
test_malformed_source_fixtures
test_normalized_manifest
test_malformed_manifest_fixtures
test_malformed_json_limits
test_long_chain_and_surrogate_inputs
test_read_only_execution
