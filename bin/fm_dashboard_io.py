#!/usr/bin/env python3
"""Bounded descriptor-relative reads for dashboard evidence."""

from __future__ import annotations

import errno
import hashlib
import os
import stat


class RecordError(Exception):
    pass


def _flags(directory: bool = False) -> int:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    if directory:
        flags |= getattr(os, "O_DIRECTORY", 0)
    return flags


def _canonical_path(path: str, reject_symlinks: bool) -> str:
    normalized = os.path.abspath(os.path.normpath(path))
    if reject_symlinks:
        cursor = os.sep
        for component in normalized.split(os.sep):
            if not component:
                continue
            cursor = os.path.join(cursor, component)
            if os.path.islink(cursor) and cursor not in {"/var", "/tmp"}:
                raise RecordError("refused: an ancestor is a symlink")
    return os.path.realpath(normalized)


def open_directory_path(path: str, reject_symlinks: bool = False) -> tuple[int, str]:
    canonical = _canonical_path(path, reject_symlinks)
    components = [part for part in canonical.split(os.sep) if part]
    fd = os.open(os.sep, _flags(True))
    try:
        for component in components:
            next_fd = os.open(component, _flags(True), dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd, canonical
    except OSError as exc:
        os.close(fd)
        if exc.errno == errno.ELOOP:
            raise RecordError("refused: an ancestor is a symlink") from exc
        raise RecordError("refused: the directory could not be opened") from exc


def _open_relative(root_fd: int, relative: str) -> int:
    components = [part for part in relative.split(os.sep) if part not in {"", "."}]
    if not components or any(part == ".." for part in components):
        raise RecordError("refused: invalid relative path")
    current_fd = os.dup(root_fd)
    try:
        for component in components[:-1]:
            next_fd = os.open(component, _flags(True), dir_fd=current_fd)
            os.close(current_fd)
            current_fd = next_fd
        fd = os.open(components[-1], _flags(), dir_fd=current_fd)
        os.close(current_fd)
        return fd
    except OSError as exc:
        os.close(current_fd)
        if exc.errno == errno.ENOENT:
            raise RecordError("not present") from exc
        if exc.errno == errno.ELOOP:
            raise RecordError("refused: the path is a symlink") from exc
        raise RecordError("refused: the record could not be opened") from exc


def open_contained(path: str, roots: list[str]) -> tuple[int, str, str]:
    """Open one record and return (fd, recorded path, resolved source path).

    The descriptor is opened relative to a root descriptor, so the file it reads
    is the canonical one inside that root - never whatever a recorded alias
    points at by the time the bytes are read. Both paths are returned because
    they answer different questions: the recorded path is where this home says
    the record lives, and the resolved path is the exact file these bytes came
    from. A consumer must publish both when they differ rather than letting
    either stand in for the other.
    """
    if path in {"", "-"}:
        raise RecordError("no recorded path")
    normalized = os.path.abspath(os.path.normpath(path))
    if os.path.islink(normalized):
        raise RecordError("refused: the path is a symlink")
    candidate = os.path.realpath(normalized)
    for root in roots:
        root_real = os.path.realpath(os.path.abspath(os.path.normpath(root)))
        try:
            relative = os.path.relpath(candidate, root_real)
        except ValueError:
            continue
        if relative == "." or relative == ".." or relative.startswith(".." + os.sep):
            continue
        root_fd, _ = open_directory_path(root_real, reject_symlinks=True)
        try:
            fd = _open_relative(root_fd, relative)
        finally:
            os.close(root_fd)
        record = os.fstat(fd)
        if not stat.S_ISREG(record.st_mode):
            os.close(fd)
            raise RecordError("refused: not a regular file")
        return fd, path, os.path.join(root_real, relative)
    raise RecordError("refused: resolves outside this home")


def stat_contained(path: str, roots: list[str]) -> tuple[os.stat_result, str, str]:
    fd, record_path, resolved_path = open_contained(path, roots)
    try:
        return os.fstat(fd), record_path, resolved_path
    finally:
        os.close(fd)


def bounded_report_paths(root: str, max_entries: int,
                         excluded_paths: set[str] | None = None
                         ) -> tuple[list[str], int, list[dict], int]:
    root_fd, _ = open_directory_path(root, reject_symlinks=True)
    reports = []
    omitted = 0
    errors = []
    error_count = 0
    excluded_paths = excluded_paths or set()

    def record_error(path: str, reason: str) -> None:
        nonlocal error_count
        error_count += 1
        if len(errors) < max_entries:
            errors.append({"path": path, "reason": reason, "error": True})

    try:
        with os.scandir(root_fd) as entries:
            for entry in entries:
                candidate_path = os.path.join(root, entry.name, "report.md")
                if candidate_path in excluded_paths:
                    continue
                try:
                    entry_stat = entry.stat(follow_symlinks=False)
                except OSError as exc:
                    record_error(candidate_path, "refused: report directory could not be inspected (%s)" % exc)
                    continue
                if stat.S_ISLNK(entry_stat.st_mode):
                    record_error(candidate_path, "refused: report directory is a symlink")
                    continue
                if not stat.S_ISDIR(entry_stat.st_mode):
                    continue
                child_fd = -1
                report_fd = -1
                try:
                    child_fd = os.open(entry.name, _flags(True), dir_fd=root_fd)
                    try:
                        report_fd = os.open("report.md", _flags(), dir_fd=child_fd)
                    except OSError as exc:
                        if exc.errno == errno.ENOENT:
                            continue
                        raise
                    report_stat = os.fstat(report_fd)
                    if stat.S_ISLNK(report_stat.st_mode):
                        record_error(candidate_path, "refused: report is a symlink")
                    elif not stat.S_ISREG(report_stat.st_mode):
                        record_error(candidate_path, "refused: report is not a regular file")
                    elif len(reports) < max_entries:
                        reports.append(candidate_path)
                    else:
                        omitted += 1
                except OSError as exc:
                    reason = "refused: report could not be opened (%s)" % exc
                    if exc.errno == errno.ELOOP:
                        reason = "refused: report is a symlink"
                    record_error(candidate_path, reason)
                finally:
                    if report_fd != -1:
                        os.close(report_fd)
                    if child_fd != -1:
                        os.close(child_fd)
    finally:
        os.close(root_fd)
    return reports, omitted, errors, error_count


def stamp_tree(root: str, label: str, depth: int, max_entries: int,
               parts: list[str]) -> None:
    try:
        root_fd, _ = open_directory_path(root, reject_symlinks=True)
    except RecordError:
        parts.append("%s:unreadable" % label)
        return
    count = [0]

    def visit(fd: int, current_label: str, remaining: int) -> None:
        try:
            root_stat = os.fstat(fd)
            parts.append("%s:dir:%s:%s" % (
                current_label, root_stat.st_mtime_ns, root_stat.st_size))
            if remaining <= 0:
                return
            with os.scandir(fd) as entries:
                for entry in entries:
                    count[0] += 1
                    if count[0] > max_entries:
                        parts.append("%s:entry-limit" % current_label)
                        break
                    entry_label = "%s/%s" % (current_label, entry.name)
                    try:
                        entry_stat = entry.stat(follow_symlinks=False)
                    except OSError:
                        parts.append("%s:unreadable" % entry_label)
                        continue
                    parts.append("%s:%s:%s:%s" % (
                        entry_label, entry_stat.st_mode, entry_stat.st_mtime_ns,
                        entry_stat.st_size))
                    if (stat.S_ISDIR(entry_stat.st_mode)
                            and not stat.S_ISLNK(entry_stat.st_mode)):
                        child_fd = -1
                        try:
                            child_fd = os.open(entry.name, _flags(True), dir_fd=fd)
                            visit(child_fd, entry_label, remaining - 1)
                        except OSError:
                            parts.append("%s:unreadable" % entry_label)
                        finally:
                            if child_fd != -1:
                                os.close(child_fd)
        except OSError:
            parts.append("%s:unreadable" % current_label)

    try:
        visit(root_fd, label, depth)
    finally:
        os.close(root_fd)


def bounded_stamp(roots: list[tuple[str, str]], depth: int,
                  max_entries: int) -> str:
    parts: list[str] = []
    for root, label in roots:
        stamp_tree(root, label, depth, max_entries, parts)
    parts.sort()
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()
