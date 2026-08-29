#!/usr/bin/env python3
"""Perform one workspace operation on one verified Herdr socket."""

import json
import os
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
RECV_CHUNK = 65536


def socket_identity(path):
    stat_result = os.stat(path)
    return f"{stat_result.st_dev}:{stat_result.st_ino}"


def read_line(sock, deadline):
    buffer = b""
    while b"\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > MAX_RESPONSE_BYTES:
            return None
    return buffer.split(b"\n", 1)[0]


def main(argv):
    if len(argv) < 4:
        return 2
    socket_path, expected_identity, operation = argv[1:4]
    if not socket_path.startswith("/") or not expected_identity:
        return 2
    if operation == "close":
        if len(argv) != 5:
            return 2
        method = "workspace.close"
        params = {"workspace_id": argv[4]}
    elif operation == "list":
        if len(argv) != 4:
            return 2
        method = "workspace.list"
        params = {}
    else:
        return 2

    try:
        if socket_identity(socket_path) != expected_identity:
            return 4
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
        if socket_identity(socket_path) != expected_identity:
            return 4
    except (OSError, ValueError):
        return 3

    request_id = "fm-workspace-control"
    request = {"id": request_id, "method": method, "params": params}
    try:
        sock.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
    except OSError:
        return 3
    line = read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    if line is None:
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    result = response.get("result") if isinstance(response, dict) else None
    if (
        not isinstance(response, dict)
        or response.get("id") != request_id
        or response.get("error") is not None
        or not isinstance(result, dict)
    ):
        return 4
    if operation == "list" and not isinstance(result.get("workspaces"), list):
        return 4
    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
