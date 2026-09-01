#!/usr/bin/env python3
"""Append one bounded diagnostics line through a descriptor-anchored handle.

The startup script validates its state boundary and then has to WRITE. Doing
that with a shell redirect reopens the path by name, so a concurrent
replacement could redirect the write - and the trim read that follows it - onto
a symlink target outside this home, and a special file at that path could block
startup outright.

This helper closes that window: it anchors one descriptor on the state
directory, opens the record relative to that descriptor without following a
symlink and without blocking, proves it is an ordinary un-hardlinked file, and
then appends and trims through the descriptor it already holds. Nothing here
ever resolves the record by name a second time.

usage: fm-dashboard-log.py STATE_DIR NAME MAX_LINES MAX_BYTES LINE
"""

from __future__ import annotations

import errno
import os
import stat
import sys

from fm_dashboard_io import RecordError, open_directory_path

MODE = 0o600


def fail(message: str) -> int:
    sys.stderr.write(message + "\n")
    return 1


def _open_record(dir_fd: int, name: str, flags: int) -> int:
    # O_NOFOLLOW refuses a symlink at the record itself; O_NONBLOCK means a fifo
    # or device left at that path fails or returns instead of wedging startup.
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        return os.open(name, flags, MODE, dir_fd=dir_fd)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise RecordError("refused: the diagnostics record is a symlink") from exc
        if exc.errno in {errno.ENXIO, errno.EWOULDBLOCK, errno.EAGAIN}:
            raise RecordError(
                "refused: the diagnostics record is not an ordinary file") from exc
        raise RecordError(
            "refused: the diagnostics record could not be opened (%s)" % exc) from exc


def _require_plain_file(fd: int) -> None:
    record = os.fstat(fd)
    if not stat.S_ISREG(record.st_mode):
        raise RecordError("refused: the diagnostics record is not a regular file")
    if record.st_nlink != 1:
        raise RecordError("refused: the diagnostics record is hardlinked")


def append_line(dir_fd: int, name: str, line: str) -> None:
    fd = _open_record(dir_fd, name, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
    try:
        _require_plain_file(fd)
        os.write(fd, line.encode("utf-8", "replace"))
    finally:
        os.close(fd)


def trim_record(dir_fd: int, name: str, max_lines: int, max_bytes: int) -> None:
    # Trimmed in place on the descriptor already proven above, so the bounded
    # rewrite can never land on a path that was swapped underneath it.
    fd = _open_record(dir_fd, name, os.O_RDWR)
    try:
        _require_plain_file(fd)
        size = os.fstat(fd).st_size
        if size <= max_bytes:
            data = os.pread(fd, size, 0) if size else b""
            start = 0
        else:
            start = size - max_bytes
            data = os.pread(fd, max_bytes, start)
            cut = data.find(b"\n")
            start += 0 if cut < 0 else cut + 1
            data = data[cut + 1:] if cut >= 0 else data
        lines = data.splitlines(keepends=True)
        if len(lines) > max_lines:
            lines = lines[-max_lines:]
        elif start == 0:
            return
        kept = b"".join(lines)
        os.pwrite(fd, kept, 0)
        os.ftruncate(fd, len(kept))
    finally:
        os.close(fd)


def main() -> int:
    if len(sys.argv) != 6:
        return fail("usage: fm-dashboard-log.py STATE_DIR NAME MAX_LINES MAX_BYTES LINE")
    directory, name, max_lines_text, max_bytes_text, line = sys.argv[1:]
    try:
        max_lines = int(max_lines_text)
        max_bytes = int(max_bytes_text)
    except ValueError:
        return fail("invalid diagnostics bound")
    if max_lines <= 0 or max_bytes <= 0:
        return fail("invalid diagnostics bound")
    if not name or name != os.path.basename(name) or name in {".", ".."}:
        return fail("invalid diagnostics record name")
    if not line.endswith("\n"):
        line += "\n"
    try:
        dir_fd, _ = open_directory_path(directory)
    except RecordError as exc:
        return fail(str(exc))
    try:
        append_line(dir_fd, name, line)
        trim_record(dir_fd, name, max_lines, max_bytes)
    except RecordError as exc:
        return fail(str(exc))
    except OSError as exc:
        return fail("the diagnostics record could not be written: %s" % exc)
    finally:
        os.close(dir_fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
