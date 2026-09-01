#!/usr/bin/env python3
"""Read one dashboard record through a contained, descriptor-backed handle."""

from __future__ import annotations

import json
import os
import sys
from fm_dashboard_io import RecordError, bounded_report_paths, open_contained
LINE_EXACT_MAX_BYTES = 1024 * 1024
LINE_TAIL_MAX_BYTES = 4 * 1024 * 1024


def fail(message: str) -> int:
    sys.stderr.write(message + "\n")
    return 1


def open_record(path: str, roots: list[str]) -> tuple[int, str] | None:
    return open_contained(path, roots)


def write_meta(path: str, record_path: str, record_stat: os.stat_result,
               total_lines: int | None = None, truncated: bool = False,
               total_lines_exact: bool | None = None) -> None:
    result = {
        "path": record_path,
        "bytes": record_stat.st_size,
        "mtime_ns": record_stat.st_mtime_ns,
        "mtime_seconds": record_stat.st_mtime,
        "truncated": truncated,
    }
    if total_lines is not None:
        result["total_lines"] = total_lines
    if total_lines_exact is not None:
        result["total_lines_exact"] = total_lines_exact
    if path == "-":
        json.dump(result, sys.stdout)
        sys.stdout.write("\n")
    else:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(result, handle)


def output_handle(path: str):
    if path == "-":
        return os.fdopen(os.dup(sys.stdout.fileno()), "wb")
    return open(path, "wb")


def newline_lines(data: bytes) -> list[bytes]:
    pieces = data.split(b"\n")
    lines = [piece + b"\n" for piece in pieces[:-1]]
    if pieces[-1]:
        lines.append(pieces[-1])
    return lines


def read_lines(fd: int, size: int, limit: int) -> tuple[list[bytes], int, bool]:
    if size <= LINE_EXACT_MAX_BYTES:
        os.lseek(fd, 0, os.SEEK_SET)
        lines = []
        bytes_read = 0
        with os.fdopen(os.dup(fd), "rb") as source:
            while bytes_read < LINE_EXACT_MAX_BYTES:
                line = source.readline(LINE_EXACT_MAX_BYTES - bytes_read + 1)
                if not line:
                    break
                bytes_read += len(line)
                if bytes_read > LINE_EXACT_MAX_BYTES:
                    raise RecordError("refused: line history exceeds the read bound")
                lines.append(line)
            if bytes_read == LINE_EXACT_MAX_BYTES and source.read(1):
                raise RecordError("refused: line history exceeds the read bound")
        return lines[-limit:], len(lines), True

    position = size
    content = b""
    enough = limit + 1
    while position > 0 and len(content) < LINE_TAIL_MAX_BYTES:
        count = min(65536, position, LINE_TAIL_MAX_BYTES - len(content))
        position -= count
        content = os.pread(fd, count, position) + content
        parts = newline_lines(content)
        partial = position > 0 and os.pread(fd, 1, position - 1) != b"\n"
        complete = parts[1:] if partial and parts else parts
        if len(complete) >= enough:
            break
    parts = newline_lines(content)
    partial = position > 0 and bool(parts) and os.pread(fd, 1, position - 1) != b"\n"
    complete = parts[1:] if partial and parts else parts
    if position > 0 and len(complete) < enough:
        raise RecordError("refused: line history exceeds the read bound")
    if len(complete) > LINE_TAIL_MAX_BYTES:
        raise RecordError("refused: line history exceeds the read bound")
    if position == 0:
        return complete[-limit:], len(complete), True
    return complete[-limit:], limit + 1, False


def main() -> int:
    if len(sys.argv) < 7:
        return fail("usage: fm-dashboard-read.py PATH ROOT... MODE LIMIT OUTPUT META")
    path = sys.argv[1]
    mode, limit_text, output, meta = sys.argv[-4:]
    roots = sys.argv[2:-4]
    try:
        limit = int(limit_text)
    except ValueError:
        return fail("invalid read bound")
    if limit <= 0 or mode not in {"stat", "info", "lines", "bytes", "tail_bytes", "text", "decimal", "report_paths"} or not roots:
        return fail("invalid read request")
    if mode == "report_paths":
        try:
            excluded_paths = set(os.environ.get(
                "FM_DASHBOARD_REPORT_EXCLUDE_PATHS", "").splitlines())
            report_paths, omitted, errors, error_count = bounded_report_paths(
                path, limit, excluded_paths)
            for report_path in report_paths:
                json.dump({"path": report_path}, sys.stdout)
                sys.stdout.write("\n")
            for error in errors:
                json.dump(error, sys.stdout)
                sys.stdout.write("\n")
            if omitted:
                json.dump({"overflow": True, "count": omitted}, sys.stdout)
                sys.stdout.write("\n")
            if error_count:
                json.dump({"discovery_errors": True, "count": error_count}, sys.stdout)
                sys.stdout.write("\n")
            return 0
        except RecordError as exc:
            return fail(str(exc))
    try:
        opened = open_record(path, roots)
    except RecordError as exc:
        return fail(str(exc))
    fd, record_path = opened
    try:
        record_stat = os.fstat(fd)
        if mode == "stat":
            if output == "-":
                sys.stdout.write(str(record_stat.st_size) + "\n")
            else:
                write_meta(meta, record_path, record_stat)
            return 0
        if mode == "info":
            if output != "-":
                raise RecordError("info output must use stdout")
            json.dump({"path": record_path, "bytes": record_stat.st_size,
                       "mode": record_stat.st_mode,
                       "mtime_seconds": record_stat.st_mtime}, sys.stdout)
            sys.stdout.write("\n")
            return 0
        if mode == "decimal":
            if record_stat.st_nlink != 1:
                raise RecordError("file is hardlinked")
            if record_stat.st_size > limit:
                raise RecordError("value must be one positive decimal integer")
            data = os.read(fd, record_stat.st_size + 1)
            if len(data) != record_stat.st_size or not data.endswith(b"\n"):
                raise RecordError("value must be one positive decimal integer")
            value = data[:-1]
            if not value or any(byte < ord("0") or byte > ord("9") for byte in value) or value.startswith(b"0"):
                raise RecordError("value must be one positive decimal integer")
            sys.stdout.write(value.decode("ascii") + "\n")
            return 0
        with output_handle(output) as handle:
            if mode in {"bytes", "text", "tail_bytes"}:
                if mode == "text" and record_stat.st_size > limit:
                    raise RecordError("refused: record exceeds the read bound")
                if mode == "tail_bytes":
                    position = max(0, record_stat.st_size - limit)
                    while position < record_stat.st_size:
                        chunk = os.pread(fd, min(65536, record_stat.st_size - position), position)
                        if not chunk:
                            break
                        handle.write(chunk.replace(b"\x00", b""))
                        position += len(chunk)
                else:
                    remaining = limit
                    while remaining:
                        chunk = os.read(fd, min(65536, remaining))
                        if not chunk:
                            break
                        handle.write(chunk.replace(b"\x00", b""))
                        remaining -= len(chunk)
                write_meta(meta, record_path, record_stat,
                           truncated=record_stat.st_size > limit)
                return 0
            lines, total_lines, exact = read_lines(fd, record_stat.st_size, limit)
            handle.writelines(lines)
            write_meta(meta, record_path, record_stat, total_lines=total_lines,
                       truncated=total_lines > limit, total_lines_exact=exact)
            return 0
    except RecordError as exc:
        return fail(str(exc))
    except OSError as exc:
        return fail("could not read record: %s" % exc)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
