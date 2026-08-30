"""Deterministic, stdlib-only manifest validation.

This module reads bytes and returns plain JSON-compatible dictionaries. It does
not write files, import work, select routes, launch processes, read config, or
make network requests. Structural validity and digest equality never grant
authorization or verify artifact origin.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from pathlib import Path
from typing import Any, Callable, Iterable

VALIDATOR_VERSION = "1.1.0"
REPORT_SCHEMA = "firstmate.factory-validation-report.v1"
SOURCE_SCHEMA = "phynd-firstmate-m1-task-graph.v1"
MANIFEST_SCHEMA = "firstmate.m1-execution-manifest.v1"
TASK_SCHEMA = "firstmate.execution-task.v1"
ROUTE_SCHEMA = "firstmate.route-request.v1"

SOURCE_ID = re.compile(r"^E[0-9]+\.[0-9]{2}$")
EPIC_ID = re.compile(r"^E[0-9]+$")
EXECUTION_ID = re.compile(r"^M[0-9]+-[0-9]{3}$")
LOWER_SHA256 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
MANIFEST_ID = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
_NO_ACCEPTANCE_TASK = object()

SOURCE_KEYS = {"schema", "title", "generated", "task_count", "epics", "tasks"}
EPIC_KEYS = {"id", "title", "goal", "phase", "tasks"}
FLAT_TASK_KEYS = {
    "id", "epic", "epic_title", "phase", "title", "detail", "output",
    "acceptance", "dependencies", "owner",
}
MANIFEST_KEYS = {
    "schema", "manifest_id", "validator", "source", "plan", "authority",
    "tasks", "acceptance_tasks", "gates", "not_in_m1", "manifest_hash",
}
EXECUTION_TASK_KEYS = {
    "schema", "id", "title", "kind", "dependencies", "route_request",
    "delivery", "artifacts", "acceptance", "rollback", "source_refs",
}
ROUTE_KEYS = {"schema", "level_floor", "role", "harness", "model", "effort"}
ROLES = {
    "implementer", "scout", "planner", "reviewer", "validator",
    "design-author", "route-scout",
}
LEVELS = {"L0", "L1", "L2", "L3", "L4"}
EFFORTS = {"low", "medium", "high", "xhigh"}
KINDS = {"ship", "scout", "captain-gate"}
DELIVERY_MODES = {"no-mistakes", "direct-PR", "local-only"}
AUTHORITY_STATES = {
    "draft", "captain_approved", "active", "quiescing", "complete",
    "rolled_back",
}

SCHEMA_FILES = {
    "source": "source-task-graph-v1.json",
    "execution-manifest": "execution-manifest-v1.json",
    "task": "execution-task-v1.json",
    "route": "route-request-v1.json",
}


class DuplicateKeyError(ValueError):
    """Raised when JSON contains an object key more than once."""


class Errors:
    """Collect deterministic validation errors."""

    def __init__(self) -> None:
        self._items: list[dict[str, str]] = []

    def add(self, code: str, path: str, message: str) -> None:
        self._items.append({"code": code, "path": path, "message": message})

    def sorted(self) -> list[dict[str, str]]:
        return sorted(self._items, key=lambda item: (
            item["code"], item["path"], item["message"]
        ))

    def __bool__(self) -> bool:
        return bool(self._items)


def canonical_json_bytes(value: Any) -> bytes:
    """Encode one JSON value in the canonical form owned by this package."""
    serialized = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ) + "\n"
    try:
        return serialized.encode("utf-8")
    except UnicodeEncodeError:
        return (json.dumps(
            value, ensure_ascii=True, sort_keys=True, separators=(",", ":")
        ) + "\n").encode("utf-8")


def load_schema(name: str) -> dict[str, Any]:
    """Load one bundled versioned JSON Schema by its CLI name."""
    try:
        filename = SCHEMA_FILES[name]
    except KeyError as exc:
        raise ValueError(f"unknown schema: {name}") from exc
    path = Path(__file__).with_name("schemas") / filename
    return json.loads(path.read_text(encoding="utf-8"))


def _object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate object key: {key}")
        result[key] = value
    return result


def _contains_lone_surrogate(value: Any) -> bool:
    pending = [value]
    while pending:
        current = pending.pop()
        if isinstance(current, str):
            index = 0
            while index < len(current):
                codepoint = ord(current[index])
                if 0xD800 <= codepoint <= 0xDBFF:
                    if index + 1 >= len(current) or not 0xDC00 <= ord(current[index + 1]) <= 0xDFFF:
                        return True
                    index += 2
                    continue
                if 0xDC00 <= codepoint <= 0xDFFF:
                    return True
                index += 1
        elif isinstance(current, dict):
            pending.extend(current.keys())
            pending.extend(current.values())
        elif isinstance(current, list):
            pending.extend(current)
    return False


def _parse_json(data: bytes, errors: Errors) -> Any | None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        errors.add("json.utf8", "$", f"input is not UTF-8: byte {exc.start}")
        return None
    try:
        parsed = json.loads(text, object_pairs_hook=_object_without_duplicate_keys)
    except DuplicateKeyError as exc:
        errors.add("json.duplicate-key", "$", str(exc))
    except json.JSONDecodeError as exc:
        errors.add(
            "json.syntax", "$",
            f"invalid JSON at line {exc.lineno} column {exc.colno}",
        )
    except ValueError:
        errors.add("json.parse-limit", "$", "JSON value exceeds supported limits")
    except RecursionError:
        errors.add("json.depth", "$", "JSON nesting exceeds supported depth")
    else:
        if _contains_lone_surrogate(parsed):
            errors.add("json.unicode", "$", "input contains a lone surrogate code point")
            return None
        return parsed
    return None


def _object_keys(
    value: Any,
    required: set[str],
    allowed: set[str],
    path: str,
    errors: Errors,
) -> bool:
    if not isinstance(value, dict):
        errors.add("schema.type", path, "expected object")
        return False
    for key in sorted(required - set(value)):
        errors.add("schema.required", f"{path}.{key}", "required field is missing")
    for key in sorted(set(value) - allowed):
        errors.add("schema.additional-property", f"{path}.{key}", "field is not allowed")
    return required <= set(value)


def _exact_keys(value: Any, expected: set[str], path: str, errors: Errors) -> bool:
    return _object_keys(value, expected, expected, path, errors)


def _string(value: Any, path: str, errors: Errors, pattern: re.Pattern[str] | None = None) -> bool:
    if not isinstance(value, str) or not value:
        errors.add("schema.type", path, "expected non-empty string")
        return False
    if pattern is not None and pattern.fullmatch(value) is None:
        errors.add("schema.pattern", path, f"invalid value: {value}")
        return False
    return True


def _enum(value: Any, choices: set[str], path: str, errors: Errors) -> bool:
    if not isinstance(value, str) or value not in choices:
        errors.add("schema.enum", path, f"expected one of: {', '.join(sorted(choices))}")
        return False
    return True


def _string_list(
    value: Any,
    path: str,
    errors: Errors,
    pattern: re.Pattern[str] | None = None,
    minimum: int = 0,
) -> list[str] | None:
    if not isinstance(value, list):
        errors.add("schema.type", path, "expected array")
        return None
    if len(value) < minimum:
        errors.add("schema.min-items", path, f"expected at least {minimum} item(s)")
    output: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        item_path = f"{path}[{index}]"
        if _string(item, item_path, errors, pattern):
            output.append(item)
            if item in seen:
                errors.add("schema.unique-items", item_path, f"duplicate item: {item}")
            seen.add(item)
    return output


def _graph_analysis(
    records: dict[str, dict[str, Any]],
    id_pattern: re.Pattern[str],
    errors: Errors,
    dependency_path: Callable[[str, int], str],
) -> dict[str, Any]:
    ids = set(records)
    dependencies: dict[str, list[str]] = {}
    edge_count = 0
    cross_group_edges = 0
    for task_id in sorted(records):
        raw = records[task_id].get("dependencies")
        deps = raw if isinstance(raw, list) else []
        valid_deps: list[str] = []
        seen: set[str] = set()
        for index, dependency in enumerate(deps):
            path = dependency_path(task_id, index)
            if not isinstance(dependency, str) or id_pattern.fullmatch(dependency) is None:
                errors.add("graph.dependency-id", path, "dependency ID is malformed")
                continue
            edge_count += 1
            if dependency in seen:
                errors.add("graph.duplicate-edge", path, f"duplicate dependency: {dependency}")
                continue
            seen.add(dependency)
            if dependency == task_id:
                errors.add("graph.self-dependency", path, f"task depends on itself: {task_id}")
            if dependency not in ids:
                errors.add("graph.unknown-dependency", path, f"unknown dependency: {dependency}")
                continue
            valid_deps.append(dependency)
            if _id_group(task_id) != _id_group(dependency):
                cross_group_edges += 1
        dependencies[task_id] = valid_deps

    cycles = _strongly_connected_cycles(dependencies)
    for cycle in cycles:
        errors.add("graph.cycle", "$.tasks", "dependency cycle: " + " -> ".join(cycle))

    dependents: dict[str, list[str]] = {task_id: [] for task_id in ids}
    indegree: dict[str, int] = {}
    for task_id in sorted(ids):
        unique_known = set(dependencies.get(task_id, []))
        indegree[task_id] = len(unique_known)
        for dependency in unique_known:
            dependents[dependency].append(task_id)
    for task_id in dependents:
        dependents[task_id].sort()

    roots = sorted(task_id for task_id, degree in indegree.items() if degree == 0)
    waves: list[list[str]] = []
    remaining = dict(indegree)
    current = roots
    while current:
        waves.append(current)
        next_wave: list[str] = []
        for task_id in current:
            remaining.pop(task_id, None)
            for dependent in dependents[task_id]:
                remaining[dependent] -= 1
                if remaining[dependent] == 0:
                    next_wave.append(dependent)
        current = sorted(next_wave)
    complete_dag = not remaining and not cycles

    longest_path_nodes: int | None = None
    if complete_dag:
        distance: dict[str, int] = {}
        for wave in waves:
            for task_id in wave:
                deps = dependencies[task_id]
                distance[task_id] = 1 + max((distance[dep] for dep in deps), default=0)
        longest_path_nodes = max(distance.values(), default=0)

    sinks = sorted(task_id for task_id in ids if not dependents[task_id])
    return {
        "cycle_count": len(cycles),
        "cycles": cycles,
        "dependency_edge_count": edge_count,
        "cross_group_edge_count": cross_group_edges,
        "longest_path_nodes": longest_path_nodes,
        "roots": roots,
        "sink_count": len(sinks),
        "sinks": sinks,
        "wave_count": len(waves) if complete_dag else None,
        "waves": waves if complete_dag else None,
    }


def _id_group(task_id: str) -> str:
    if "." in task_id:
        return task_id.split(".", 1)[0]
    return task_id.split("-", 1)[0]


def _strongly_connected_cycles(dependencies: dict[str, list[str]]) -> list[list[str]]:
    nodes = sorted(dependencies)
    adjacency = {
        node: sorted(set(dependency for dependency in dependencies[node] if dependency in dependencies))
        for node in nodes
    }
    reverse: dict[str, list[str]] = {node: [] for node in nodes}
    for node in nodes:
        for dependency in adjacency[node]:
            reverse[dependency].append(node)
    for node in nodes:
        reverse[node].sort()

    visited: set[str] = set()
    finish_order: list[str] = []
    for root in nodes:
        if root in visited:
            continue
        visited.add(root)
        pending: list[tuple[str, int]] = [(root, 0)]
        while pending:
            node, next_index = pending[-1]
            if next_index < len(adjacency[node]):
                dependency = adjacency[node][next_index]
                pending[-1] = (node, next_index + 1)
                if dependency not in visited:
                    visited.add(dependency)
                    pending.append((dependency, 0))
            else:
                finish_order.append(node)
                pending.pop()

    visited.clear()
    components: list[list[str]] = []
    for root in reversed(finish_order):
        if root in visited:
            continue
        component: list[str] = []
        pending = [root]
        visited.add(root)
        while pending:
            node = pending.pop()
            component.append(node)
            for dependent in reverse[node]:
                if dependent not in visited:
                    visited.add(dependent)
                    pending.append(dependent)
        components.append(sorted(component))

    cycles = [component for component in components if len(component) > 1]
    for node in sorted(dependencies):
        if node in dependencies[node]:
            cycles.append([node])
    return sorted(cycles)


def _acceptance_analysis(
    records: dict[str, dict[str, Any]], targets: Iterable[str], errors: Errors
) -> dict[str, Any]:
    ids = set(records)
    target_list = sorted(set(targets))
    covered: set[str] = set()
    per_target: dict[str, int | None] = {}
    for target in target_list:
        if target not in ids:
            errors.add("graph.acceptance-unknown", "$.acceptance_tasks", f"unknown acceptance task: {target}")
            per_target[target] = None
            continue
        stack = [target]
        ancestors: set[str] = set()
        while stack:
            task_id = stack.pop()
            if task_id in ancestors:
                continue
            ancestors.add(task_id)
            deps = records[task_id].get("dependencies")
            if isinstance(deps, list):
                stack.extend(dep for dep in deps if isinstance(dep, str) and dep in ids)
        covered.update(ancestors)
        per_target[target] = len(ancestors)
    return {
        "covered_task_count": len(covered),
        "per_target_ancestor_count_including_self": per_target,
        "targets": target_list,
        "uncovered_task_count": len(ids - covered),
        "uncovered_task_ids": sorted(ids - covered),
    }


def _base_report(subject: str, data: bytes) -> dict[str, Any]:
    return {
        "errors": [],
        "input": {
            "byte_count": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        },
        "report_schema": REPORT_SCHEMA,
        "subject": subject,
        "trust": {
            "artifact_origin_verified": False,
            "authorization_granted": False,
            "structural_validation_only": True,
        },
        "validator_version": VALIDATOR_VERSION,
        "valid": False,
    }


def validate_source_bytes(
    data: bytes, expected_sha256: str, acceptance_task: Any = "E7.14"
) -> dict[str, Any]:
    """Validate immutable imported source bytes and return a deterministic report."""
    errors = Errors()
    report = _base_report("source-task-graph", data)
    actual_sha256 = report["input"]["sha256"]
    provenance = {
        "actual_sha256": actual_sha256,
        "binding_kind": "caller-supplied-sha256",
        "expected_sha256": expected_sha256,
        "matches": actual_sha256 == expected_sha256,
        "origin_verified": False,
    }
    report["provenance"] = provenance
    if (
        not isinstance(expected_sha256, str)
        or LOWER_SHA256.fullmatch(expected_sha256) is None
    ):
        errors.add("provenance.expected-sha256", "$.expected_sha256", "expected SHA-256 must be 64 lowercase hexadecimal characters")
    elif actual_sha256 != expected_sha256:
        errors.add("provenance.mismatch", "$", "source bytes do not match the expected SHA-256")

    acceptance_targets: list[str] = []
    if acceptance_task is not _NO_ACCEPTANCE_TASK and _string(
        acceptance_task, "$.acceptance_task", errors, SOURCE_ID
    ):
        acceptance_targets.append(acceptance_task)

    document = _parse_json(data, errors)
    if document is None:
        report["errors"] = errors.sorted()
        return report
    report["subject_schema"] = document.get("schema") if isinstance(document, dict) else None
    if not _exact_keys(document, SOURCE_KEYS, "$", errors):
        report["errors"] = errors.sorted()
        return report

    if document["schema"] != SOURCE_SCHEMA:
        errors.add("schema.version", "$.schema", f"expected {SOURCE_SCHEMA}")
    _string(document["title"], "$.title", errors)
    _string(document["generated"], "$.generated", errors, DATE)
    declared_count = document["task_count"]
    if isinstance(declared_count, bool) or not isinstance(declared_count, (int, float)):
        declared_count_valid = False
    elif isinstance(declared_count, float):
        declared_count_valid = (
            math.isfinite(declared_count)
            and declared_count >= 1
            and declared_count.is_integer()
        )
    else:
        declared_count_valid = declared_count >= 1
    if not declared_count_valid:
        errors.add("schema.type", "$.task_count", "expected positive integer")
    else:
        declared_count = int(declared_count)

    epics = document["epics"]
    flat_tasks = document["tasks"]
    if not isinstance(epics, list):
        errors.add("schema.type", "$.epics", "expected array")
        epics = []
    elif not epics:
        errors.add("schema.min-items", "$.epics", "expected at least 1 item(s)")
    if not isinstance(flat_tasks, list):
        errors.add("schema.type", "$.tasks", "expected array")
        flat_tasks = []
    elif not flat_tasks:
        errors.add("schema.min-items", "$.tasks", "expected at least 1 item(s)")

    nested_records: dict[str, dict[str, Any]] = {}
    nested_locations: dict[str, str] = {}
    epic_ids: set[str] = set()
    epic_counts: dict[str, int] = {}
    for epic_index, epic in enumerate(epics):
        epic_path = f"$.epics[{epic_index}]"
        if not _exact_keys(epic, EPIC_KEYS, epic_path, errors):
            continue
        epic_id = epic["id"]
        valid_epic_id = _string(epic_id, f"{epic_path}.id", errors, EPIC_ID)
        for field in ("title", "goal", "phase"):
            _string(epic[field], f"{epic_path}.{field}", errors)
        if valid_epic_id:
            if epic_id in epic_ids:
                errors.add("id.duplicate-epic", f"{epic_path}.id", f"duplicate epic ID: {epic_id}")
            epic_ids.add(epic_id)
        nested = epic["tasks"]
        if not isinstance(nested, list):
            errors.add("schema.type", f"{epic_path}.tasks", "expected array")
            continue
        if not nested:
            errors.add("schema.min-items", f"{epic_path}.tasks", "expected at least 1 item(s)")
        if valid_epic_id:
            epic_counts[epic_id] = len(nested)
        for task_index, item in enumerate(nested):
            item_path = f"{epic_path}.tasks[{task_index}]"
            if not isinstance(item, list) or len(item) != 7:
                errors.add("schema.tuple", item_path, "expected seven-item source task tuple")
                continue
            task_id, title, detail, output, acceptance, dependencies, owner = item
            valid_task_id = _string(task_id, f"{item_path}[0]", errors, SOURCE_ID)
            for index, value in ((1, title), (2, detail), (3, output), (4, acceptance), (6, owner)):
                _string(value, f"{item_path}[{index}]", errors)
            _string_list(dependencies, f"{item_path}[5]", errors, SOURCE_ID)
            if not valid_task_id or not valid_epic_id:
                continue
            if not task_id.startswith(epic_id + "."):
                errors.add("id.epic-prefix", f"{item_path}[0]", f"task {task_id} does not belong to {epic_id}")
            record = {
                "id": task_id,
                "epic": epic_id,
                "epic_title": epic["title"],
                "phase": epic["phase"],
                "title": title,
                "detail": detail,
                "output": output,
                "acceptance": acceptance,
                "dependencies": dependencies,
                "owner": owner,
            }
            if task_id in nested_records:
                errors.add("id.duplicate-nested-task", f"{item_path}[0]", f"duplicate nested task ID: {task_id}")
            else:
                nested_records[task_id] = record
                nested_locations[task_id] = item_path

    flat_records: dict[str, dict[str, Any]] = {}
    flat_locations: dict[str, str] = {}
    for index, task in enumerate(flat_tasks):
        task_path = f"$.tasks[{index}]"
        if not _exact_keys(task, FLAT_TASK_KEYS, task_path, errors):
            continue
        task_id = task["id"]
        valid_task_id = _string(task_id, f"{task_path}.id", errors, SOURCE_ID)
        valid_epic_id = _string(task["epic"], f"{task_path}.epic", errors, EPIC_ID)
        for field in ("epic_title", "phase", "title", "detail", "output", "acceptance", "owner"):
            _string(task[field], f"{task_path}.{field}", errors)
        _string_list(task["dependencies"], f"{task_path}.dependencies", errors, SOURCE_ID)
        if not valid_task_id:
            continue
        if valid_epic_id and task["epic"] not in epic_ids:
            errors.add("id.unknown-epic", f"{task_path}.epic", f"unknown epic: {task['epic']}")
        if valid_epic_id and not task_id.startswith(task["epic"] + "."):
            errors.add("id.epic-prefix", f"{task_path}.id", f"task {task_id} does not belong to {task['epic']}")
        if task_id in flat_records:
            errors.add("id.duplicate-flat-task", f"{task_path}.id", f"duplicate flat task ID: {task_id}")
        else:
            flat_records[task_id] = task
            flat_locations[task_id] = task_path

    nested_ids = set(nested_records)
    flat_ids = set(flat_records)
    for task_id in sorted(nested_ids - flat_ids):
        errors.add("representation.missing-flat", nested_locations[task_id], f"task missing from flat representation: {task_id}")
    for task_id in sorted(flat_ids - nested_ids):
        errors.add("representation.missing-nested", flat_locations[task_id], f"task missing from nested representation: {task_id}")
    for task_id in sorted(nested_ids & flat_ids):
        nested = nested_records[task_id]
        flat = flat_records[task_id]
        for field in sorted(FLAT_TASK_KEYS):
            if nested[field] != flat[field]:
                errors.add("representation.mismatch", f"{flat_locations[task_id]}.{field}", f"nested and flat values differ for {task_id}.{field}")

    actual_count = len(flat_tasks)
    if declared_count_valid and declared_count != actual_count:
        errors.add("count.declared", "$.task_count", f"declared {declared_count}, found {actual_count} flat tasks")
    if len(nested_records) != actual_count:
        errors.add("count.representations", "$.epics", f"found {len(nested_records)} unique nested tasks and {actual_count} flat task entries")

    graph = _graph_analysis(
        flat_records, SOURCE_ID, errors,
        lambda task_id, index: f"{flat_locations.get(task_id, '$.tasks')}.dependencies[{index}]",
    )
    graph.update({
        "acceptance_reachability": _acceptance_analysis(flat_records, acceptance_targets, errors),
        "declared_task_count": declared_count,
        "epic_count": len(epics),
        "epic_task_counts": {key: epic_counts[key] for key in sorted(epic_counts)},
        "flat_task_count": actual_count,
        "nested_flat_equal": nested_records == flat_records and len(nested_records) == actual_count,
        "nested_task_count": len(nested_records),
        "task_ids": sorted(flat_records),
    })
    report["graph"] = graph
    report["errors"] = errors.sorted()
    report["valid"] = not errors
    return report


def _validate_route(route: Any, path: str, errors: Errors) -> None:
    if not _object_keys(
        route, {"schema", "level_floor", "role"}, ROUTE_KEYS, path, errors
    ):
        return
    if route["schema"] != ROUTE_SCHEMA:
        errors.add("schema.version", f"{path}.schema", f"expected {ROUTE_SCHEMA}")
    _enum(route["level_floor"], LEVELS, f"{path}.level_floor", errors)
    _enum(route["role"], ROLES, f"{path}.role", errors)
    for field in ("harness", "model"):
        if field in route:
            _string(route[field], f"{path}.{field}", errors)
    if "effort" in route:
        _enum(route["effort"], EFFORTS, f"{path}.effort", errors)


def _validate_execution_task(task: Any, path: str, errors: Errors) -> dict[str, Any] | None:
    if not _exact_keys(task, EXECUTION_TASK_KEYS, path, errors):
        return None
    if task["schema"] != TASK_SCHEMA:
        errors.add("schema.version", f"{path}.schema", f"expected {TASK_SCHEMA}")
    valid_id = _string(task["id"], f"{path}.id", errors, EXECUTION_ID)
    _string(task["title"], f"{path}.title", errors)
    _enum(task["kind"], KINDS, f"{path}.kind", errors)
    _string_list(task["dependencies"], f"{path}.dependencies", errors, EXECUTION_ID)
    _validate_route(task["route_request"], f"{path}.route_request", errors)
    delivery = task["delivery"]
    if _exact_keys(delivery, {"mode", "yolo"}, f"{path}.delivery", errors):
        _enum(delivery["mode"], DELIVERY_MODES, f"{path}.delivery.mode", errors)
        if type(delivery["yolo"]) is not bool:
            errors.add("schema.type", f"{path}.delivery.yolo", "expected boolean")
    _string_list(task["artifacts"], f"{path}.artifacts", errors)
    _string_list(task["acceptance"], f"{path}.acceptance", errors, minimum=1)
    _string_list(task["rollback"], f"{path}.rollback", errors)
    _string_list(task["source_refs"], f"{path}.source_refs", errors, SOURCE_ID, minimum=1)
    return task if valid_id else None


def validate_execution_manifest_bytes(
    data: bytes, source_data: bytes
) -> dict[str, Any]:
    """Validate a normalized manifest and its bound immutable source bytes."""
    errors = Errors()
    report = _base_report("execution-manifest", data)
    document = _parse_json(data, errors)
    if document is None:
        report["errors"] = errors.sorted()
        return report
    report["subject_schema"] = document.get("schema") if isinstance(document, dict) else None
    if not _exact_keys(document, MANIFEST_KEYS, "$", errors):
        report["errors"] = errors.sorted()
        return report

    if document["schema"] != MANIFEST_SCHEMA:
        errors.add("schema.version", "$.schema", f"expected {MANIFEST_SCHEMA}")
    _string(document["manifest_id"], "$.manifest_id", errors, MANIFEST_ID)

    validator = document["validator"]
    if _exact_keys(validator, {"name", "version"}, "$.validator", errors):
        if validator["name"] != "firstmate_factory":
            errors.add("schema.const", "$.validator.name", "expected firstmate_factory")
        _string(validator["version"], "$.validator.version", errors, SEMVER)

    sources = document["source"]
    if not isinstance(sources, list) or not sources:
        errors.add("schema.min-items", "$.source", "expected at least one source binding")
        sources = []
    source_graph_bindings: list[tuple[int, dict[str, Any]]] = []
    for index, source in enumerate(sources):
        path = f"$.source[{index}]"
        if _exact_keys(source, {"path", "sha256", "schema"}, path, errors):
            _string(source["path"], f"{path}.path", errors)
            _string(source["sha256"], f"{path}.sha256", errors, LOWER_SHA256)
            _string(source["schema"], f"{path}.schema", errors)
            if source["schema"] == SOURCE_SCHEMA:
                source_graph_bindings.append((index, source))

    source_sha256 = hashlib.sha256(source_data).hexdigest()
    source_provenance: dict[str, Any] = {
        "actual_sha256": source_sha256,
        "artifact_origin_verified": False,
        "binding_kind": "manifest-declared-sha256",
        "bound_sha256": None,
        "matches": False,
        "source_valid": False,
    }
    source_task_ids: set[str] | None = None
    if len(source_graph_bindings) != 1:
        errors.add(
            "manifest.source-binding",
            "$.source",
            f"expected exactly one {SOURCE_SCHEMA} binding, found {len(source_graph_bindings)}",
        )
    else:
        binding_index, binding = source_graph_bindings[0]
        bound_sha256 = binding["sha256"]
        source_provenance["bound_sha256"] = bound_sha256
        source_provenance["matches"] = bound_sha256 == source_sha256
        if isinstance(bound_sha256, str):
            source_report = validate_source_bytes(
                source_data, bound_sha256, _NO_ACCEPTANCE_TASK
            )
            source_provenance["source_valid"] = source_report["valid"]
            source_provenance["validation_errors"] = source_report["errors"]
            source_graph = source_report.get("graph", {})
            if isinstance(source_graph, dict):
                task_ids = source_graph.get("task_ids")
                if isinstance(task_ids, list):
                    source_task_ids = {task_id for task_id in task_ids if isinstance(task_id, str)}
        else:
            source_provenance["validation_errors"] = []
        if bound_sha256 != source_sha256:
            errors.add(
                "manifest.source-hash-mismatch",
                f"$.source[{binding_index}].sha256",
                "bound source SHA-256 does not match supplied source bytes",
            )
        if not source_provenance["source_valid"]:
            errors.add(
                "manifest.source-invalid",
                "$.source",
                "bound source task graph is invalid",
            )
    report["source_provenance"] = source_provenance

    plan = document["plan"]
    if _exact_keys(plan, {"artifact_sha256", "repo_commit"}, "$.plan", errors):
        _string(plan["artifact_sha256"], "$.plan.artifact_sha256", errors, LOWER_SHA256)
        _string(plan["repo_commit"], "$.plan.repo_commit", errors, COMMIT)

    authority = document["authority"]
    if _exact_keys(authority, {"state", "approval_id", "scope"}, "$.authority", errors):
        state_ok = _enum(authority["state"], AUTHORITY_STATES, "$.authority.state", errors)
        approval_id = authority["approval_id"]
        if approval_id is not None:
            _string(approval_id, "$.authority.approval_id", errors)
        scope = _string_list(authority["scope"], "$.authority.scope", errors, EXECUTION_ID)
        if state_ok and authority["state"] != "draft" and approval_id is None:
            errors.add("authority.approval-required", "$.authority.approval_id", "non-draft authority requires an approval ID")
        if state_ok and authority["state"] != "draft" and not scope:
            errors.add("authority.scope-required", "$.authority.scope", "non-draft authority requires a non-empty scope")

    tasks = document["tasks"]
    if not isinstance(tasks, list) or not tasks:
        errors.add("schema.min-items", "$.tasks", "expected at least one execution task")
        tasks = []
    records: dict[str, dict[str, Any]] = {}
    task_locations: dict[str, str] = {}
    for index, task in enumerate(tasks):
        path = f"$.tasks[{index}]"
        validated = _validate_execution_task(task, path, errors)
        if validated is None:
            continue
        task_id = validated["id"]
        if task_id in records:
            errors.add("id.duplicate-execution-task", f"{path}.id", f"duplicate execution task ID: {task_id}")
        else:
            records[task_id] = validated
            task_locations[task_id] = path

    if source_task_ids is not None:
        for task_id in sorted(records):
            source_refs = records[task_id].get("source_refs")
            if not isinstance(source_refs, list):
                continue
            task_path = task_locations[task_id]
            for index, source_ref in enumerate(source_refs):
                if isinstance(source_ref, str) and source_ref not in source_task_ids:
                    errors.add(
                        "provenance.unknown-source-ref",
                        f"{task_path}.source_refs[{index}]",
                        f"unknown source task: {source_ref}",
                    )

    acceptance_tasks = _string_list(
        document["acceptance_tasks"], "$.acceptance_tasks", errors,
        EXECUTION_ID, minimum=1,
    ) or []
    _string_list(document["gates"], "$.gates", errors)
    _string_list(document["not_in_m1"], "$.not_in_m1", errors)

    scope_values = authority.get("scope", []) if isinstance(authority, dict) else []
    if isinstance(scope_values, list):
        for index, task_id in enumerate(scope_values):
            if isinstance(task_id, str) and EXECUTION_ID.fullmatch(task_id) and task_id not in records:
                errors.add("authority.unknown-scope-task", f"$.authority.scope[{index}]", f"unknown scoped task: {task_id}")

    graph = _graph_analysis(
        records, EXECUTION_ID, errors,
        lambda task_id, index: f"{task_locations.get(task_id, '$.tasks')}.dependencies[{index}]",
    )
    graph.update({
        "acceptance_reachability": _acceptance_analysis(records, acceptance_tasks, errors),
        "task_count": len(tasks),
    })
    report["graph"] = graph

    manifest_hash = document["manifest_hash"]
    hash_format_ok = _string(manifest_hash, "$.manifest_hash", errors, LOWER_SHA256)
    hash_input = dict(document)
    hash_input.pop("manifest_hash", None)
    calculated_hash = hashlib.sha256(canonical_json_bytes(hash_input)).hexdigest()
    report["manifest_hash"] = {
        "calculated": calculated_hash,
        "declared": manifest_hash,
        "matches": hash_format_ok and manifest_hash == calculated_hash,
    }
    if hash_format_ok and manifest_hash != calculated_hash:
        errors.add("manifest.hash-mismatch", "$.manifest_hash", "manifest hash does not match canonical manifest content excluding manifest_hash")

    report["errors"] = errors.sorted()
    report["valid"] = not errors
    return report
