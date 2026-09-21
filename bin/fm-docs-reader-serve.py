#!/usr/bin/env python3
import argparse
import hashlib
import os
from pathlib import Path
import runpy
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("--launch", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    owner = Path(__file__).with_name("fm-launch-record.py")
    contract = runpy.run_path(str(owner))
    identity = contract["pid_identity"](os.getpid())
    if not identity:
        return 1
    digest = hashlib.sha256(identity.encode("utf-8", "surrogateescape")).hexdigest()
    result = subprocess.run([
        os.environ.get("FM_LAUNCH_RECORD_PYTHON", "python3"),
        os.environ.get("FM_LAUNCH_RECORD_OWNER", str(owner)),
        "--state", args.state, "created", "--helper", "docs-reader", "--launch", args.launch,
        "--identity-source", "process", "--identity", f"pid={os.getpid()}",
        "--identity", f"port={args.port}", "--identity", f"pid_identity_sha256={digest}",
    ], check=False)
    if result.returncode:
        return result.returncode
    sys.argv = ["mkdocs", "serve", "-f", args.config, "-a", f"127.0.0.1:{args.port}"]
    runpy.run_module("mkdocs", run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main())
