#!/usr/bin/env python3
"""Single owner of Firstmate's durable launch-record contract.

A launch record makes one Firstmate-owned launch accountable on disk: what
Firstmate intended to start, what the runtime actually created, whether it
became ready, and how it ended. The record is written BEFORE any external
creation call, so an interrupted launcher leaves an inspectable partial record
instead of silence, and every later phase is bound to the launch id the intent
minted.

Records (all private to the home, mode 0600, atomically replaced):
  state/<task-id>.launch      one worker task (crewmate, scout, secondmate)
  state/.launch-<helper>      one Firstmate-owned long-lived helper

Phases of one launch:
  intended   durable intent exists; nothing external is proven to exist yet
  created    the runtime returned exact native identity for what it created
  ready      a meaningful readiness source confirmed the launched agent/process
  uncertain  an external effect may exist and could not be proven either way
             (lost response, interrupted launcher, retained endpoint); this phase
             carries a reconciliation obligation and blocks a blind duplicate
  failed     nothing external remains (nothing was created, or it was cleaned)
  stopped    a deliberate stop through the owning control path
  exited     the launched process or agent was observed gone
  retired    the owning cleanup path removed the endpoint
  reconciled an open launch was settled from native evidence by a later launcher
`failed`, `stopped`, `exited`, `retired`, and `reconciled` are terminal.
`intended`, `created`, `ready`, and `uncertain` are open: a new `intend` for the
same subject is refused (exit 3) until the open launch is settled through
`stop`, `exit`, `retire`, `fail`, or `reconcile`.

Identity is never a pid alone, a display label, or a process-name match:
Herdr subjects record the exact response ids (workspace, tab, pane, terminal);
process subjects record pid plus the SHA-256 of the same start-time identity
string bin/fm-wake-lib.sh's fm_pid_identity computes (`pid-identity` below
mirrors it). Readiness is a recorded verdict from a named source, and an
acknowledged launch is never automatically ready.

Privacy: values are bounded, newline-free, drawn from a key allowlist, and
refused when they look like credentials. Launcher identity strings are hashed
before storage. Callers pass identifiers and short reasons, never command
lines, environment, prompts, or brief text.

Usage:
  fm-launch-record.py [--home DIR] [--state DIR] <command> [options]

  Subject selection (every command except list and pid-identity):
    --task <id> | --helper <name>

  intend    --owner NAME --origin ORIGIN [--launcher-pid N] [--launcher-identity STR]
            [--field K=V]...
            Mint a launch id and publish the intent. Prints `launch=<id>`.
            Exit 3 when an open launch exists (its `check` summary is printed).
  created   --launch ID --identity K=V... [--identity-source SRC] [--field K=V]...
  ready     --launch ID --source SRC [--field K=V]...
  unready   --launch ID --reason TEXT [--source SRC]
            Readiness verdict `unconfirmed`; the phase stays created.
  fail      --launch ID --reason TEXT --effect none|cleaned|retained|unknown
            none|cleaned -> failed (terminal); retained|unknown -> uncertain.
  stop      (--launch ID | --current) --reason TEXT
  supersede (--launch ID | --current) --reason TEXT
            Successor-chain owners only: the current open launch becomes
            superseded (terminal) so the successor's intent is not a refused
            duplicate; `exit --launch ID` on it later annotates its real exit.
  exit      (--launch ID | --current) --reason TEXT [--code N]
  retire    (--launch ID | --current) --reason TEXT
  reconcile (--launch ID | --current) --verdict VERDICT --evidence TEXT
            VERDICT: absent|husk-replaced|agent-exited|adopted|launcher-gone|manual
  check     Exit 0 with `open=none`, or exit 3 with the open launch summary:
            launch=, phase=, origin=, owner=, launcher=alive|gone|unknown,
            reconcile=yes|no, and identity.<k>= lines.
  show      [--json]
  get       FIELD          dotted path, e.g. launch.phase, launch.identity.pane_id
  list      [--open] [--reconcile]   one summary line per record in the home
  pid-identity PID        print the identity string for a live pid

Exit codes: 0 ok; 1 record could not be read or written (the caller must treat
this as a refused launch when it happens before creation); 2 usage or invalid
value; 3 refused by contract (open launch on intend, phase mismatch, or
`check` reporting an open launch).
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import platform
import re
import secrets
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone

VERSION = 1
HISTORY_MAX = 64
PREVIOUS_MAX = 8
VALUE_MAX = 512
LOCK_WAIT_SECONDS = 3.0

OPEN_PHASES = ("intended", "created", "ready", "uncertain")
TERMINAL_PHASES = ("failed", "stopped", "exited", "retired", "reconciled", "superseded")
RECONCILE_VERDICTS = ("absent", "husk-replaced", "agent-exited", "adopted", "launcher-gone", "manual")
EFFECTS = ("none", "cleaned", "retained", "unknown")
IDENTITY_SOURCES = ("native-response", "adopted-record", "recovered-by-label", "process")

IDENTITY_KEYS = frozenset(
    {
        "backend",
        "session",
        "socket_identity",
        "workspace_id",
        "tab_id",
        "pane_id",
        "terminal_id",
        "window",
        "pid",
        "pid_identity_sha256",
        "port",
        "worktree",
        "label",
    }
)
FIELD_KEYS = frozenset(
    {
        "harness",
        "kind",
        "worktree",
        "generation",
        "label",
        "adopted",
        "identity_source",
        "recovered_by",
        "hint",
        "cleanup",
        "note",
        "code",
        "status",
        "endpoint",
        "home",
        "mode",
        "effort",
        "model",
        "project",
        "port",
        "readiness_status",
        "container",
        "predecessor",
        "successor",
    }
)

SECRET_SHAPES = (
    re.compile(r"(?i)(api[_-]?key|secret|token|passw(or)?d|bearer|authorization|credential)\s*[=:]\s*\S{8,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bxox[abpr]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"),
)
KEY_SHAPE = re.compile(r"^[a-z][a-z0-9_]{0,39}$")
SUBJECT_SHAPE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
HELPER_SHAPE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
LAUNCH_ID_SHAPE = re.compile(r"^l[0-9]+\.[0-9]+\.[0-9a-f]{8}$")


class RecordError(Exception):
    """A read or write failure; exit 1."""


class ContractRefusal(Exception):
    """A refusal by the phase contract; exit 3."""


class UsageError(Exception):
    """Invalid arguments or values; exit 2."""


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


# --- process identity (mirrors bin/fm-wake-lib.sh fm_pid_identity) ---------


def pid_identity(pid: int) -> str | None:
    """Return the same identity string fm_pid_identity prints, or None."""
    if pid <= 0:
        return None
    proc_root = os.environ.get("FM_PROC_ROOT_OVERRIDE", "/proc")
    stat_path = os.path.join(proc_root, str(pid), "stat")
    cmd_path = os.path.join(proc_root, str(pid), "cmdline")
    if os.access(stat_path, os.R_OK) and os.access(cmd_path, os.R_OK):
        try:
            with open(stat_path, "r", encoding="utf-8", errors="surrogateescape") as handle:
                stat_line = handle.read()
            with open(cmd_path, "rb") as handle:
                cmdline = handle.read()
        except OSError:
            return None
        tail = stat_line.rsplit(")", 1)[-1].split()
        if len(tail) < 20:
            return None
        starttime = tail[19]
        if not starttime.isdigit() or not cmdline:
            return None
        key = "linux-starttime" if platform.system() == "Linux" else "proc-starttime"
        return f"{key}={starttime} cmdline-hex={cmdline.hex()}"
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart=", "-o", "command="],
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    return out.stdout.rstrip("\n").lstrip()


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def launcher_state(launch: dict) -> str:
    launcher = launch.get("launcher") or {}
    pid = launcher.get("pid")
    digest = launcher.get("pid_identity_sha256")
    if not isinstance(pid, int) or pid <= 0 or not digest:
        return "unknown"
    if not pid_alive(pid):
        return "gone"
    current = pid_identity(pid)
    if current is None:
        return "unknown"
    return "alive" if sha256_text(current) == digest else "gone"


# --- validation -------------------------------------------------------------


def check_value(name: str, value: str) -> str:
    if value is None:
        raise UsageError(f"{name} is required")
    if len(value) > VALUE_MAX:
        raise UsageError(f"{name} exceeds {VALUE_MAX} characters")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise UsageError(f"{name} must not contain control characters or newlines")
    for shape in SECRET_SHAPES:
        if shape.search(value):
            raise UsageError(f"{name} looks like a credential and is refused from an ordinary launch record")
    return value


def parse_pairs(pairs: list[str], allowed: frozenset, what: str) -> dict:
    result: dict = {}
    for pair in pairs or []:
        if "=" not in pair:
            raise UsageError(f"{what} expects KEY=VALUE, got {pair!r}")
        key, value = pair.split("=", 1)
        if not KEY_SHAPE.match(key):
            raise UsageError(f"{what} key {key!r} is not a valid key")
        if key not in allowed:
            raise UsageError(f"{what} key {key!r} is not in the documented allowlist")
        result[key] = check_value(f"{what} {key}", value)
    return result


def parse_launch_id(value: str) -> str:
    if not LAUNCH_ID_SHAPE.match(value or ""):
        raise UsageError(f"invalid launch id {value!r}")
    return value


# --- paths and I/O ----------------------------------------------------------


def state_dir(args) -> str:
    if args.state:
        return args.state
    if os.environ.get("FM_STATE_OVERRIDE"):
        return os.environ["FM_STATE_OVERRIDE"]
    home = args.home or os.environ.get("FM_HOME")
    if not home:
        raise UsageError("--home, FM_HOME, or --state/FM_STATE_OVERRIDE is required")
    return os.path.join(home, "state")


def record_path(state: str, args) -> tuple[str, str, str]:
    task = getattr(args, "task", None)
    helper = getattr(args, "helper", None)
    if bool(task) == bool(helper):
        raise UsageError("exactly one of --task or --helper is required")
    if task:
        if not SUBJECT_SHAPE.match(task):
            raise UsageError(f"invalid task id {task!r}")
        return os.path.join(state, f"{task}.launch"), "task", task
    if not HELPER_SHAPE.match(helper):
        raise UsageError(f"invalid helper name {helper!r}")
    return os.path.join(state, f".launch-{helper}"), "helper", helper


def refuse_symlink(path: str) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise RecordError(f"cannot inspect {path}: {exc.strerror}") from exc
    if stat.S_ISLNK(info.st_mode):
        raise RecordError(f"refused: {path} is a symlink")
    if not stat.S_ISREG(info.st_mode):
        raise RecordError(f"refused: {path} is not a regular file")


def read_record(path: str) -> dict | None:
    refuse_symlink(path)
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise RecordError(f"cannot open {path}: {exc.strerror}") from exc
    try:
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            raw = handle.read(4 * 1024 * 1024)
    except OSError as exc:
        raise RecordError(f"cannot read {path}: {exc.strerror}") from exc
    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise RecordError(f"malformed launch record at {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("version") != VERSION:
        raise RecordError(f"unsupported launch record version at {path}")
    return data


def write_record(path: str, data: dict) -> None:
    refuse_symlink(path)
    directory = os.path.dirname(path) or "."
    tmp = f"{path}.tmp.{os.getpid()}"
    payload = json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError as exc:
        raise RecordError(f"cannot create {tmp}: {exc.strerror}") from exc
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        try:
            dir_fd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise RecordError(f"cannot publish {path}: {exc.strerror}") from exc


class RecordLock:
    def __init__(self, path: str):
        self.path = f"{path}.lock"
        self.fd = None

    def __enter__(self):
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        try:
            self.fd = os.open(
                self.path,
                os.O_RDWR | os.O_CREAT | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            if not stat.S_ISREG(os.fstat(self.fd).st_mode):
                raise RecordError(f"lock path is not a regular file ({self.path})")
            while True:
                try:
                    fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return self
                except OSError as exc:
                    if exc.errno not in (errno.EACCES, errno.EAGAIN):
                        raise
                    if time.monotonic() >= deadline:
                        raise RecordError(f"launch record is locked by another writer ({self.path})")
                    time.sleep(0.02)
        except (OSError, RecordError) as exc:
            self.__exit__()
            if isinstance(exc, RecordError):
                raise
            raise RecordError(f"cannot lock {self.path}: {exc.strerror}") from exc

    def __exit__(self, *exc):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        return False


# --- record shape -----------------------------------------------------------


def new_record(kind: str, subject: str) -> dict:
    return {"version": VERSION, "kind": kind, "subject": subject, "launch": None, "previous": []}


def current_launch(data: dict | None) -> dict | None:
    if not data:
        return None
    launch = data.get("launch")
    return launch if isinstance(launch, dict) else None


def is_open(launch: dict | None) -> bool:
    return bool(launch) and launch.get("phase") in OPEN_PHASES


def append_history(launch: dict, event: str, **extra) -> None:
    entry = {"at": now_iso(), "event": event}
    for key, value in extra.items():
        if value is not None:
            entry[key] = value
    history = launch.setdefault("history", [])
    history.append(entry)
    if len(history) > HISTORY_MAX:
        del history[: len(history) - HISTORY_MAX]


def require_launch(data: dict | None, launch_id: str | None, current: bool) -> dict:
    launch = current_launch(data)
    if launch is None:
        raise ContractRefusal("no launch is recorded for this subject")
    if current:
        return launch
    if launch.get("id") != launch_id:
        raise ContractRefusal(
            f"launch {launch_id} is not the current launch (current is {launch.get('id')} in phase {launch.get('phase')})"
        )
    return launch


def summary_lines(launch: dict, kind: str, subject: str) -> list[str]:
    lines = [
        f"subject={kind}:{subject}",
        f"launch={launch.get('id')}",
        f"phase={launch.get('phase')}",
        f"origin={launch.get('origin')}",
        f"owner={launch.get('owner')}",
        f"launcher={launcher_state(launch)}",
        f"reconcile={'yes' if launch.get('reconcile', {}).get('required') else 'no'}",
        f"intended_at={launch.get('intended_at')}",
    ]
    readiness = launch.get("readiness")
    if isinstance(readiness, dict) and readiness.get("verdict"):
        lines.append(f"readiness={readiness.get('verdict')}")
    outcome = launch.get("outcome")
    if isinstance(outcome, dict) and outcome.get("reason"):
        lines.append(f"reason={outcome.get('reason')}")
    hint = launch.get("reconcile", {}).get("hint")
    if hint:
        lines.append(f"hint={hint}")
    for key, value in sorted((launch.get("fields") or {}).items()):
        lines.append(f"field.{key}={value}")
    for key, value in sorted((launch.get("identity") or {}).items()):
        lines.append(f"identity.{key}={value}")
    return lines


# --- commands ---------------------------------------------------------------


def cmd_intend(args, path: str, kind: str, subject: str) -> int:
    owner = check_value("--owner", args.owner)
    origin = check_value("--origin", args.origin)
    if not KEY_SHAPE.match(origin.replace("-", "_")):
        raise UsageError("--origin must be a short lowercase token")
    fields = parse_pairs(args.field, FIELD_KEYS, "--field")
    launcher: dict = {}
    if args.launcher_pid is not None:
        if args.launcher_pid <= 0:
            raise UsageError("--launcher-pid must be positive")
        launcher["pid"] = args.launcher_pid
        identity = args.launcher_identity
        if identity is None:
            identity = pid_identity(args.launcher_pid)
        if identity:
            launcher["pid_identity_sha256"] = sha256_text(identity)
    with RecordLock(path):
        data = read_record(path)
        launch = current_launch(data)
        if is_open(launch):
            for line in summary_lines(launch, kind, subject):
                print(line)
            raise ContractRefusal(
                f"an open launch {launch.get('id')} in phase {launch.get('phase')} exists for {kind} {subject}; settle it (stop, exit, retire, fail, or reconcile) before a new intent"
            )
        if data is None:
            data = new_record(kind, subject)
        if launch is not None:
            previous = data.setdefault("previous", [])
            previous.append(launch)
            if len(previous) > PREVIOUS_MAX:
                del previous[: len(previous) - PREVIOUS_MAX]
        launch_id = f"l{int(time.time())}.{os.getpid()}.{secrets.token_hex(4)}"
        new_launch = {
            "id": launch_id,
            "phase": "intended",
            "owner": owner,
            "origin": origin,
            "intended_at": now_iso(),
            "launcher": launcher,
            "fields": fields,
            "identity": {},
            "readiness": {},
            "outcome": {},
            "reconcile": {"required": False},
            "history": [],
        }
        append_history(new_launch, "intended", owner=owner, origin=origin)
        data["launch"] = new_launch
        write_record(path, data)
    print(f"launch={launch_id}")
    return 0


def cmd_created(args, path: str, kind: str, subject: str) -> int:
    launch_id = parse_launch_id(args.launch)
    identity = parse_pairs(args.identity, IDENTITY_KEYS, "--identity")
    if not identity:
        raise UsageError("created requires at least one --identity K=V")
    source = args.identity_source or "native-response"
    if source not in IDENTITY_SOURCES:
        raise UsageError(f"--identity-source must be one of {', '.join(IDENTITY_SOURCES)}")
    fields = parse_pairs(args.field, FIELD_KEYS, "--field")
    with RecordLock(path):
        data = read_record(path)
        launch = require_launch(data, launch_id, False)
        if launch.get("phase") not in ("intended", "uncertain"):
            raise ContractRefusal(f"created is only valid from intended, not {launch.get('phase')}")
        launch["identity"] = identity
        launch["identity_source"] = source
        launch["fields"].update(fields)
        launch["phase"] = "created"
        launch["created_at"] = now_iso()
        launch["reconcile"] = {"required": False}
        append_history(launch, "created", identity_source=source)
        write_record(path, data)
    print(f"launch={launch_id} phase=created")
    return 0


def cmd_ready(args, path: str, kind: str, subject: str) -> int:
    launch_id = parse_launch_id(args.launch)
    source = check_value("--source", args.source)
    fields = parse_pairs(args.field, FIELD_KEYS, "--field")
    with RecordLock(path):
        data = read_record(path)
        launch = require_launch(data, launch_id, False)
        if launch.get("phase") != "created":
            raise ContractRefusal(f"ready is only valid from created, not {launch.get('phase')}")
        launch["readiness"] = {"verdict": "ready", "source": source, "observed_at": now_iso()}
        launch["fields"].update(fields)
        launch["phase"] = "ready"
        append_history(launch, "ready", source=source)
        write_record(path, data)
    print(f"launch={launch_id} phase=ready")
    return 0


def cmd_unready(args, path: str, kind: str, subject: str) -> int:
    launch_id = parse_launch_id(args.launch)
    reason = check_value("--reason", args.reason)
    source = check_value("--source", args.source) if args.source else None
    with RecordLock(path):
        data = read_record(path)
        launch = require_launch(data, launch_id, False)
        if launch.get("phase") != "created":
            raise ContractRefusal(f"unready is only valid from created, not {launch.get('phase')}")
        launch["readiness"] = {"verdict": "unconfirmed", "reason": reason, "observed_at": now_iso()}
        if source:
            launch["readiness"]["source"] = source
        append_history(launch, "unready", reason=reason)
        write_record(path, data)
    print(f"launch={launch_id} phase=created readiness=unconfirmed")
    return 0


def cmd_fail(args, path: str, kind: str, subject: str) -> int:
    launch_id = parse_launch_id(args.launch)
    reason = check_value("--reason", args.reason)
    if args.effect not in EFFECTS:
        raise UsageError(f"--effect must be one of {', '.join(EFFECTS)}")
    fields = parse_pairs(args.field, FIELD_KEYS, "--field")
    with RecordLock(path):
        data = read_record(path)
        launch = require_launch(data, launch_id, False)
        if launch.get("phase") not in OPEN_PHASES:
            raise ContractRefusal(f"fail is only valid from an open phase, not {launch.get('phase')}")
        launch["fields"].update(fields)
        if args.effect in ("none", "cleaned"):
            phase = "failed"
            launch["reconcile"] = {"required": False}
        else:
            phase = "uncertain"
            hint = fields.get("hint") or launch["fields"].get("hint")
            launch["reconcile"] = {"required": True, "effect": args.effect}
            if hint:
                launch["reconcile"]["hint"] = hint
        launch["outcome"] = {"phase": phase, "reason": reason, "effect": args.effect, "at": now_iso()}
        launch["phase"] = phase
        append_history(launch, phase, reason=reason, effect=args.effect)
        write_record(path, data)
    print(f"launch={launch_id} phase={phase} effect={args.effect}")
    return 0


def _terminal(args, path: str, phase: str, extra: dict) -> int:
    reason = check_value("--reason", args.reason)
    with RecordLock(path):
        data = read_record(path)
        launch = require_launch(data, args.launch, args.current)
        if launch.get("phase") not in OPEN_PHASES:
            raise ContractRefusal(f"{phase} is only valid from an open phase, not {launch.get('phase')}")
        outcome = {"phase": phase, "reason": reason, "at": now_iso()}
        outcome.update(extra)
        launch["outcome"] = outcome
        launch["phase"] = phase
        launch["reconcile"] = {"required": False}
        append_history(launch, phase, reason=reason, **extra)
        write_record(path, data)
    print(f"launch={launch.get('id')} phase={phase}")
    return 0


def cmd_stop(args, path: str, kind: str, subject: str) -> int:
    return _terminal(args, path, "stopped", {})


def cmd_exit(args, path: str, kind: str, subject: str) -> int:
    extra = {}
    if args.code is not None:
        extra["code"] = args.code
    # A superseded launch (a successor-chain predecessor) still exits later;
    # that exit is annotated on the superseded launch, wherever it now lives,
    # instead of being refused as a phase mismatch.
    if not args.current and args.launch:
        with RecordLock(path):
            data = read_record(path)
            launch = current_launch(data)
            candidates = ([launch] if launch else []) + list((data or {}).get("previous") or [])
            for old in candidates:
                if old.get("id") == args.launch and old.get("phase") == "superseded":
                    reason = check_value("--reason", args.reason)
                    old.setdefault("outcome", {})["exit"] = {"reason": reason, "at": now_iso(), **extra}
                    append_history(old, "exited-after-supersede", reason=reason, **extra)
                    write_record(path, data)
                    print(f"launch={args.launch} phase=superseded exit=recorded")
                    return 0
    return _terminal(args, path, "exited", extra)


def cmd_supersede(args, path: str, kind: str, subject: str) -> int:
    """A successor-chain owner (the watcher arm) deliberately starts the next
    launch while the current one still runs: the current launch becomes
    superseded (terminal) so the new intent is not a refused duplicate, and its
    later real exit is still annotated through `exit --launch <id>`."""
    reason = check_value("--reason", args.reason)
    with RecordLock(path):
        data = read_record(path)
        launch = require_launch(data, args.launch, args.current)
        if launch.get("phase") not in OPEN_PHASES:
            raise ContractRefusal(f"supersede is only valid from an open phase, not {launch.get('phase')}")
        launch["outcome"] = {"phase": "superseded", "reason": reason, "at": now_iso()}
        launch["phase"] = "superseded"
        launch["reconcile"] = {"required": False}
        append_history(launch, "superseded", reason=reason)
        write_record(path, data)
    print(f"launch={launch.get('id')} phase=superseded")
    return 0


def cmd_retire(args, path: str, kind: str, subject: str) -> int:
    return _terminal(args, path, "retired", {})


def cmd_reconcile(args, path: str, kind: str, subject: str) -> int:
    if args.verdict not in RECONCILE_VERDICTS:
        raise UsageError(f"--verdict must be one of {', '.join(RECONCILE_VERDICTS)}")
    evidence = check_value("--evidence", args.evidence)
    with RecordLock(path):
        data = read_record(path)
        launch = require_launch(data, args.launch, args.current)
        if launch.get("phase") not in OPEN_PHASES:
            raise ContractRefusal(f"reconcile is only valid from an open phase, not {launch.get('phase')}")
        launch["outcome"] = {"phase": "reconciled", "verdict": args.verdict, "evidence": evidence, "at": now_iso()}
        launch["phase"] = "reconciled"
        launch["reconcile"] = {"required": False}
        append_history(launch, "reconciled", verdict=args.verdict, evidence=evidence)
        write_record(path, data)
    print(f"launch={launch.get('id')} phase=reconciled verdict={args.verdict}")
    return 0


def cmd_check(args, path: str, kind: str, subject: str) -> int:
    data = read_record(path)
    launch = current_launch(data)
    if not is_open(launch):
        print("open=none")
        return 0
    for line in summary_lines(launch, kind, subject):
        print(line)
    return 3


def cmd_show(args, path: str, kind: str, subject: str) -> int:
    data = read_record(path)
    if data is None:
        raise RecordError(f"no launch record at {path}")
    if args.json:
        print(json.dumps(data, sort_keys=True, indent=2))
        return 0
    launch = current_launch(data)
    if launch is None:
        print(f"subject={kind}:{subject}")
        print("launch=none")
        return 0
    for line in summary_lines(launch, kind, subject):
        print(line)
    for entry in launch.get("history", []):
        parts = [f"{k}={v}" for k, v in entry.items() if k not in ("at", "event")]
        print(f"history {entry.get('at')} {entry.get('event')} {' '.join(parts)}".rstrip())
    previous = data.get("previous") or []
    for old in previous:
        outcome = old.get("outcome") or {}
        line = f"previous launch={old.get('id')} phase={old.get('phase')} reason={outcome.get('reason', '')}"
        if outcome.get("verdict"):
            line += f" verdict={outcome.get('verdict')}"
        if isinstance(outcome.get("exit"), dict):
            line += f" exit={outcome['exit'].get('reason', '')}"
        print(line)
    return 0


def cmd_get(args, path: str, kind: str, subject: str) -> int:
    data = read_record(path)
    if data is None:
        raise RecordError(f"no launch record at {path}")
    node = data
    for part in args.field.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            raise ContractRefusal(f"field {args.field} is not present")
    if isinstance(node, (dict, list)):
        print(json.dumps(node, sort_keys=True))
    elif node is None:
        print("")
    else:
        print(node)
    return 0


def cmd_list(args, state: str) -> int:
    try:
        names = sorted(os.listdir(state))
    except FileNotFoundError:
        return 0
    except OSError as exc:
        raise RecordError(f"cannot list {state}: {exc.strerror}") from exc
    printed = 0
    for name in names:
        if name.endswith(".launch"):
            kind, subject = "task", name[: -len(".launch")]
        elif name.startswith(".launch-") and not name.endswith(".lock") and ".tmp." not in name:
            kind, subject = "helper", name[len(".launch-"):]
        else:
            continue
        path = os.path.join(state, name)
        try:
            data = read_record(path)
        except RecordError as exc:
            print(f"subject={kind}:{subject} error={exc}")
            printed += 1
            continue
        launch = current_launch(data)
        if launch is None:
            continue
        opened = is_open(launch)
        if args.open and not opened:
            continue
        needs_reconcile = opened and (
            launch.get("reconcile", {}).get("required")
            or (launch.get("phase") in ("intended", "created") and launcher_state(launch) == "gone")
        )
        if args.reconcile and not needs_reconcile:
            continue
        summary = summary_lines(launch, kind, subject)
        head = [item for item in summary if not item.startswith("identity.")]
        idents = [item for item in summary if item.startswith("identity.")]
        line = " ".join(head)
        if needs_reconcile:
            line += " needs_reconcile=yes"
        if idents:
            line += " " + " ".join(idents)
        print(line)
        printed += 1
    return 0


def cmd_pid_identity(args) -> int:
    identity = pid_identity(args.pid)
    if identity is None:
        raise RecordError(f"no identity readable for pid {args.pid}")
    print(identity)
    return 0


# --- argument parsing -------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-launch-record.py", add_help=True, description=__doc__.split("\n\n")[0])
    parser.add_argument("--home", help="Firstmate home (default FM_HOME)")
    parser.add_argument("--state", help="state directory (default FM_STATE_OVERRIDE or <home>/state)")
    sub = parser.add_subparsers(dest="command", required=True)

    def subject(p):
        group = p.add_mutually_exclusive_group(required=True)
        group.add_argument("--task", help="worker task id")
        group.add_argument("--helper", help="Firstmate-owned helper name")

    p = sub.add_parser("intend")
    subject(p)
    p.add_argument("--owner", required=True)
    p.add_argument("--origin", required=True)
    p.add_argument("--launcher-pid", type=int)
    p.add_argument("--launcher-identity")
    p.add_argument("--field", action="append", default=[])

    p = sub.add_parser("created")
    subject(p)
    p.add_argument("--launch", required=True)
    p.add_argument("--identity", action="append", default=[])
    p.add_argument("--identity-source")
    p.add_argument("--field", action="append", default=[])

    p = sub.add_parser("ready")
    subject(p)
    p.add_argument("--launch", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--field", action="append", default=[])

    p = sub.add_parser("unready")
    subject(p)
    p.add_argument("--launch", required=True)
    p.add_argument("--reason", required=True)
    p.add_argument("--source")

    p = sub.add_parser("fail")
    subject(p)
    p.add_argument("--launch", required=True)
    p.add_argument("--reason", required=True)
    p.add_argument("--effect", required=True)
    p.add_argument("--field", action="append", default=[])

    for name in ("stop", "exit", "retire", "supersede"):
        p = sub.add_parser(name)
        subject(p)
        sel = p.add_mutually_exclusive_group(required=True)
        sel.add_argument("--launch")
        sel.add_argument("--current", action="store_true")
        p.add_argument("--reason", required=True)
        if name == "exit":
            p.add_argument("--code", type=int)

    p = sub.add_parser("reconcile")
    subject(p)
    sel = p.add_mutually_exclusive_group(required=True)
    sel.add_argument("--launch")
    sel.add_argument("--current", action="store_true")
    p.add_argument("--verdict", required=True)
    p.add_argument("--evidence", required=True)

    p = sub.add_parser("check")
    subject(p)

    p = sub.add_parser("show")
    subject(p)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("get")
    subject(p)
    p.add_argument("field")

    p = sub.add_parser("list")
    p.add_argument("--open", action="store_true")
    p.add_argument("--reconcile", action="store_true")

    p = sub.add_parser("pid-identity")
    p.add_argument("pid", type=int)
    return parser


COMMANDS = {
    "intend": cmd_intend,
    "created": cmd_created,
    "ready": cmd_ready,
    "unready": cmd_unready,
    "fail": cmd_fail,
    "stop": cmd_stop,
    "exit": cmd_exit,
    "retire": cmd_retire,
    "reconcile": cmd_reconcile,
    "supersede": cmd_supersede,
    "check": cmd_check,
    "show": cmd_show,
    "get": cmd_get,
}


def main(argv: list[str]) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code not in (0, None) else 0
    try:
        if args.command == "pid-identity":
            return cmd_pid_identity(args)
        state = state_dir(args)
        if args.command == "list":
            return cmd_list(args, state)
        if getattr(args, "launch", None) is not None and args.command != "intend":
            parse_launch_id(args.launch)
        path, kind, subject = record_path(state, args)
        return COMMANDS[args.command](args, path, kind, subject)
    except UsageError as exc:
        print(f"fm-launch-record: {exc}", file=sys.stderr)
        return 2
    except ContractRefusal as exc:
        print(f"fm-launch-record: refused: {exc}", file=sys.stderr)
        return 3
    except RecordError as exc:
        print(f"fm-launch-record: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
