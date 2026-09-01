#!/usr/bin/env python3
"""fm-factory-manifest.py - validate immutable factory planning artifacts.

Usage:
  fm-factory-manifest.py validate-source --source FILE --expected-sha256 HEX
      [--acceptance-task ID]
  fm-factory-manifest.py validate-manifest --manifest FILE --source FILE
  fm-factory-manifest.py schema source|execution-manifest|task|route

Every successful command writes one canonical JSON document to stdout.
Validation commands exit 0 when structurally valid, 1 when content or a digest
binding is invalid, and 2 for command-line or file-read errors. A valid report
never grants authorization or verifies artifact origin. Commands never write
files, mutate configuration, import backlog work, launch processes, or make
network requests.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# This validation CLI is read-only, including when run directly from a source
# tree. Avoid leaving interpreter cache files beside the package.
sys.dont_write_bytecode = True

from firstmate_factory import (  # noqa: E402
    canonical_json_bytes,
    load_schema,
    validate_execution_manifest_bytes,
    validate_source_bytes,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate immutable Firstmate factory manifests."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    source = subparsers.add_parser(
        "validate-source", help="validate imported source task-graph bytes"
    )
    source.add_argument("--source", required=True, metavar="FILE")
    source.add_argument("--expected-sha256", required=True, metavar="HEX")
    source.add_argument("--acceptance-task", default="E7.14", metavar="ID")

    manifest = subparsers.add_parser(
        "validate-manifest", help="validate a normalized execution manifest"
    )
    manifest.add_argument("--manifest", required=True, metavar="FILE")
    manifest.add_argument(
        "--source", required=True, metavar="FILE",
        help="immutable source task graph bound by the manifest",
    )

    schema = subparsers.add_parser(
        "schema", help="print one bundled versioned JSON Schema"
    )
    schema.add_argument(
        "name", choices=("source", "execution-manifest", "task", "route")
    )
    return parser


def _read(path: str) -> bytes:
    try:
        return Path(path).read_bytes()
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc.strerror or exc}") from exc


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "schema":
            output = load_schema(args.name)
            valid = True
        elif args.command == "validate-source":
            output = validate_source_bytes(
                _read(args.source), args.expected_sha256, args.acceptance_task
            )
            valid = output["valid"]
        else:
            output = validate_execution_manifest_bytes(
                _read(args.manifest), _read(args.source)
            )
            valid = output["valid"]
    except ValueError as exc:
        print(f"fm-factory-manifest: {exc}", file=sys.stderr)
        return 2
    sys.stdout.buffer.write(canonical_json_bytes(output))
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
