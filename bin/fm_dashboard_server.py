#!/usr/bin/env python3
"""fm_dashboard_server.py - the read-only control-plane API the dashboard talks to.

The browser never reads a filesystem path. It calls this server, which consumes
the evidence document produced by the collector. The collector is the only
component that touches firstmate's durable text records.

WHAT THIS IS NOT. There is no endpoint that launches, routes, steers,
acknowledges, merges, tears down, or controls anything. Every route is a read.
Any method other than GET or HEAD is refused before routing, so a mutating
request cannot reach a handler even by accident. Firstmate remains the only
control-plane interface.

LOOPBACK ONLY. The bind address is 127.0.0.1 and is not configurable.

EVIDENCE FLOW.
    authoritative text records
      -> bin/fm-dashboard.sh json          (the bounded, symlink-safe collector)
      -> this server's cache + normalizers
      -> versioned read-only API documents  (provenance, source path, freshness)
      -> the React client

The collector is the single authority for what may be read; this server never
opens a record path of its own. It caches the collector's output and re-runs it
on a bounded schedule, so a browser that polls, or twenty SSE clients, cannot
turn into twenty collector runs.

FRESHNESS IS EXPLICIT. Every document carries `generated`, `age_seconds`, and
the exact source paths behind it, so a stale answer is visibly stale rather than
silently old.

NO INVENTED NUMBERS. A metric this home cannot support is emitted with
`available: false` and a reason. Nothing is estimated into existence.
"""

from __future__ import annotations

import json
import os
import signal
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from fm_dashboard_io import RecordError, open_directory_path

API_VERSION = "v1"
# One configured bound covers a complete collection, and the request-read
# deadline is derived from it exactly as the earlier server derived it, so
# lowering the bound tightens both together.
COLLECTOR_TIMEOUT = int(os.environ.get("FM_DASHBOARD_BUILD_TIMEOUT",
                                      os.environ.get("FM_DASHBOARD_COLLECT_TIMEOUT", "120")))
# How long a cached collection may be served before the collector is run again.
CACHE_TTL_SECONDS = float(os.environ.get("FM_DASHBOARD_CACHE_TTL", "2"))
LIVE_REFRESH_SECONDS = max(0.1, min(60.0, float(
    os.environ.get("FM_DASHBOARD_LIVE_REFRESH", "2"))))
REFRESH_SECONDS = max(0.1, min(60.0, CACHE_TTL_SECONDS, LIVE_REFRESH_SECONDS))
ERROR_RETRY_SECONDS = max(0.1, min(60.0, float(
    os.environ.get("FM_DASHBOARD_ERROR_RETRY", "2"))))
# Bounded backpressure: a stream client that cannot keep up is dropped rather
# than allowed to grow an unbounded queue inside this process.
MAX_STREAM_CLIENTS = int(os.environ.get("FM_DASHBOARD_MAX_STREAM_CLIENTS", "8"))
STREAM_POLL_SECONDS = float(os.environ.get("FM_DASHBOARD_STREAM_POLL", "1"))
STREAM_MAX_SECONDS = float(os.environ.get("FM_DASHBOARD_STREAM_MAX_SECONDS", "3600"))
STAMP_TIMEOUT = max(1.0, min(float(COLLECTOR_TIMEOUT), 10.0))

SELF = os.environ["FM_DASHBOARD_SELF"]
PORT = int(os.environ["FM_DASHBOARD_BIND_PORT"])
OWNER_DIGEST = os.environ.get("FM_DASHBOARD_OWNER_DIGEST", "")
HOME = os.environ.get("FM_DASHBOARD_HEALTH_HOME", "")
APP_DIR = os.environ.get("FM_DASHBOARD_APP_DIR", "")
DEV_RELOAD = os.environ.get("FM_DASHBOARD_DEV_RELOAD", "") == "1"

# Only these files are ever served from the app directory, by exact name. A
# request cannot name a path: it selects one of these, or it gets a 404. That is
# what keeps a static route from becoming a filesystem read primitive.
ASSET_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".map": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}
ASSET_MAX_BYTES = 16 * 1024 * 1024


def _now() -> float:
    return time.time()


GROUP_CLEANUP_GRACE = 5.0

# Sticky, because an unreclaimed process group does not heal on its own. Health
# must stop claiming readiness once cleanup could not be proven: a caller that
# treats a degraded server as ready would report a working dashboard while
# something the collector started is still running unattended.
_DEGRADED_LOCK = threading.Lock()
_DEGRADED_REASON: str | None = None


def _mark_degraded(reason: str) -> None:
    global _DEGRADED_REASON
    with _DEGRADED_LOCK:
        if _DEGRADED_REASON is None:
            _DEGRADED_REASON = reason


def degraded_reason() -> str | None:
    with _DEGRADED_LOCK:
        return _DEGRADED_REASON


def _dev_asset_stamp():
    if not DEV_RELOAD or not APP_DIR:
        return None
    try:
        app_fd, _ = open_directory_path(APP_DIR, reject_symlinks=True)
        try:
            values = []
            for name in ("index.html", "app.js", "app.css"):
                fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=app_fd)
                try:
                    asset = os.fstat(fd)
                    if not stat.S_ISREG(asset.st_mode):
                        return None
                    values.append((name, asset.st_mtime_ns, asset.st_size))
                finally:
                    os.close(fd)
            return tuple(values)
        finally:
            os.close(app_fd)
    except (OSError, RecordError):
        return None


def _kill_group(proc, pgid: int | None = None) -> bool:
    """Reclaim a collector and every descendant, and PROVE the group is gone.

    Returns True only when the process group is observably empty. A cleanup that
    cannot be proven must never be reported as success: a surviving grandchild
    would still hold whatever the collector held, with nothing pointing at it.
    """
    if pgid is None:
        try:
            pgid = os.getpgid(proc.pid)
        except OSError:
            pgid = None
    if pgid is not None:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
    try:
        proc.kill()
    except OSError:
        pass
    try:
        proc.communicate(timeout=GROUP_CLEANUP_GRACE)
    except Exception:  # noqa: BLE001 - the direct child is already gone
        pass
    if pgid is None:
        return False
    deadline = time.monotonic() + GROUP_CLEANUP_GRACE
    while time.monotonic() < deadline:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return True          # the group is observably empty
        except PermissionError:
            break                # cannot observe it, so cannot claim it
        except OSError:
            break
        time.sleep(0.1)
    _mark_degraded("an evidence collector process group could not be proven reclaimed")
    return False


class Evidence:
    """The collector's output, cached between bounded refreshes."""

    def __init__(self) -> None:
        self._condition = threading.Condition(threading.Lock())
        self._payload: dict | None = None
        self._error: str | None = None
        self._collected_at = 0.0
        self._stamp = ""
        self._retry_at = 0.0
        self._collecting = False
        self._generation = 0

    def _read_stamp(self, payload: dict | None = None) -> str:
        if isinstance(payload, dict) and isinstance(payload.get("freshness_stamp"), str):
            return payload["freshness_stamp"]
        return ""

    def generation(self) -> int:
        with self._condition:
            return self._generation

    def current(self) -> tuple[dict | None, str | None, int]:
        while True:
            now = _now()
            with self._condition:
                fresh_enough = (now - self._collected_at) < REFRESH_SECONDS
                if fresh_enough and self._payload is not None:
                    return self._payload, None, self._generation
                if fresh_enough and self._error is not None and now < self._retry_at:
                    return None, self._error, self._generation
                if self._collecting:
                    self._condition.wait()
                    continue
                self._collecting = True
                break
        generation_changed = True
        try:
            if self._payload is not None and self._error is None:
                stamp, stamp_error = self._read_live_stamp()
                if stamp_error is None and stamp == self._stamp:
                    payload, error = self._payload, None
                    generation_changed = False
                else:
                    payload, error = self._collect()
            else:
                payload, error = self._collect()
        except Exception as exc:  # noqa: BLE001 - surfaced as bounded evidence failure
            payload, error = None, "the evidence collector failed: %s" % exc
        with self._condition:
            self._payload = payload
            self._error = error
            if payload is not None:
                self._stamp = self._read_stamp(payload)
            self._collected_at = _now()
            self._retry_at = self._collected_at + ERROR_RETRY_SECONDS if error else 0.0
            if generation_changed:
                self._generation += 1
            self._collecting = False
            self._condition.notify_all()
            return self._payload, self._error, self._generation

    def _read_live_stamp(self) -> tuple[str, str | None]:
        try:
            proc = subprocess.Popen(
                [SELF, "stamp"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except Exception as exc:  # noqa: BLE001 - surfaced, never swallowed
            return "", "the evidence freshness stamp could not run: %s" % exc
        try:
            out, err = proc.communicate(timeout=STAMP_TIMEOUT)
        except subprocess.TimeoutExpired:
            reclaimed = _kill_group(proc, proc.pid)
            detail = "the evidence freshness stamp exceeded its bound"
            if not reclaimed:
                detail += "; its process group could not be proven reclaimed"
            return "", detail
        if proc.returncode != 0 or not out:
            detail = err.decode("utf-8", "replace").strip() or "no detail"
            return "", "the evidence freshness stamp failed: %s" % detail
        value = out.decode("utf-8", "replace").strip()
        try:
            parsed = json.loads(value)
        except ValueError:
            parsed = None
        if isinstance(parsed, dict):
            value = self._read_stamp(parsed)
        if not value:
            return "", "the evidence freshness stamp was empty"
        return value, None

    def _collect(self) -> tuple[dict | None, str | None]:
        # The collector owns its own process group, so a timeout reclaims the
        # WHOLE tree. Killing only the direct child would leave a wedged
        # grandchild holding the bound open with nothing left pointing at it.
        try:
            proc = subprocess.Popen(
                [SELF, "json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except Exception as exc:  # noqa: BLE001 - surfaced, never swallowed
            return None, "the evidence collector could not run: %s" % exc
        pgid = proc.pid
        try:
            out, err = proc.communicate(timeout=COLLECTOR_TIMEOUT)
        except subprocess.TimeoutExpired:
            reclaimed = _kill_group(proc, pgid)
            detail = ("the evidence collector exceeded its %ss bound"
                      % COLLECTOR_TIMEOUT)
            if not reclaimed:
                detail += "; its process group could not be proven reclaimed"
            return None, detail
        except Exception as exc:  # noqa: BLE001
            reclaimed = _kill_group(proc, pgid)
            detail = "the evidence collector failed: %s" % exc
            if not reclaimed:
                detail += "; its process group could not be proven reclaimed"
            return None, detail
        if proc.returncode != 0 or not out:
            detail = err.decode("utf-8", "replace").strip() or "no detail"
            return None, "the evidence collector failed: %s" % detail
        try:
            return json.loads(out), None
        except ValueError as exc:
            return None, "the evidence collector returned unreadable JSON: %s" % exc

    def collected_at(self) -> float:
        with self._condition:
            return self._collected_at


EVIDENCE = Evidence()


# --- derived metrics -------------------------------------------------------
# Every metric names the exact records it came from. A metric this home cannot
# support is emitted unavailable with a reason, never estimated. The captain's
# standing ruling is that there is no durable metrics store, so nothing here may
# depend on history that was not already retained by firstmate itself.

def _metric(key, label, value, sources, kind="point_in_time", unit=None,
            available=True, reason=None, detail=None):
    return {
        "key": key,
        "label": label,
        "value": value if available else None,
        "unit": unit,
        "kind": kind,
        "available": available,
        "reason": reason,
        "detail": detail,
        "sources": sources,
    }


def _unavailable(key, label, reason, sources=None):
    return _metric(key, label, None, sources or [], available=False, reason=reason)


def _state_path(*parts):
    return os.path.join(HOME, "state", *parts) if HOME else os.path.join("state", *parts)


def derive_metrics(payload: dict, now: float) -> list[dict]:
    snapshot = payload.get("snapshot") or {}
    tasks = snapshot.get("tasks") or []
    backlog_obj = snapshot.get("backlog") or {}
    backlog_available = backlog_obj.get("available", True)
    backlog = backlog_obj.get("records") or [] if backlog_available else []
    backlog_path = backlog_obj.get("path")
    supervision = payload.get("supervision") or {}
    wakes = supervision.get("wakes") or {}
    events = payload.get("events") or []
    usage = payload.get("usage") or {}
    roots_state = (snapshot.get("roots") or {}).get("state")
    out = []

    # -- work in flight, aging, queue depth (point-in-time, exact) ----------
    if backlog_available:
        in_flight = [r for r in backlog if r.get("state") == "in_flight"]
        queued = [r for r in backlog if r.get("state") == "queued"]
        out.append(_metric("wip", "Work in flight", len(in_flight), [backlog_path]))
        out.append(_metric("queue_depth", "Queued", len(queued), [backlog_path]))
    else:
        reason = backlog_obj.get("reason") or "the backlog could not be read"
        out.append(_unavailable("wip", "Work in flight", reason, [backlog_path]))
        out.append(_unavailable("queue_depth", "Queued", reason, [backlog_path]))

    in_flight = [r for r in backlog if r.get("state") == "in_flight"]

    ages = []
    today = time.strftime("%Y-%m-%d", time.gmtime(now))
    for row in in_flight:
        since = row.get("since")
        if not since:
            continue
        try:
            started = time.mktime(time.strptime(since, "%Y-%m-%d"))
        except ValueError:
            continue
        ages.append(max(0, int((now - started) // 86400)))
    if not backlog_available:
        out.append(_unavailable("wip_oldest_days", "Oldest work in flight",
                                backlog_obj.get("reason") or "the backlog could not be read",
                                [backlog_path]))
    elif ages:
        out.append(_metric("wip_oldest_days", "Oldest work in flight", max(ages),
                           [backlog_path], unit="days",
                           detail="observation date %s" % today))
    else:
        out.append(_unavailable("wip_oldest_days", "Oldest work in flight",
                                "no in-flight row records a start date",
                                [backlog_path]))

    # -- wake backlog and acknowledgement lag (point-in-time, exact) --------
    wake_path = _state_path(".wake-queue")
    if wakes.get("available"):
        records = [w for w in (wakes.get("records") or []) if not w.get("malformed")]
        out.append(_metric("wake_backlog", "Unacknowledged notifications",
                           wakes.get("total", 0), [wake_path]))
        epochs = [w.get("epoch") for w in records if isinstance(w.get("epoch"), (int, float))]
        if epochs:
            out.append(_metric("wake_ack_lag_seconds", "Oldest notification waiting",
                               int(now - min(epochs)), [wake_path], unit="seconds"))
        else:
            out.append(_metric("wake_ack_lag_seconds", "Oldest notification waiting", 0,
                               [wake_path], unit="seconds",
                               detail="nothing is waiting"))
        malformed = len([w for w in (wakes.get("records") or []) if w.get("malformed")])
        if malformed:
            out.append(_metric("wake_malformed", "Unreadable queue records", malformed,
                               [wake_path]))
    else:
        reason = wakes.get("reason") or "the notification queue could not be read"
        out.append(_unavailable("wake_backlog", "Unacknowledged notifications", reason, [wake_path]))
        out.append(_unavailable("wake_ack_lag_seconds", "Oldest notification waiting", reason, [wake_path]))

    # -- supervision freshness (point-in-time, exact) ----------------------
    beat_path = _state_path(".last-watcher-beat")
    if supervision.get("beacon_present"):
        out.append(_metric("supervision_beacon_age_seconds", "Monitor heartbeat age",
                           supervision.get("beacon_age_seconds"), [beat_path], unit="seconds"))
    else:
        out.append(_unavailable("supervision_beacon_age_seconds", "Monitor heartbeat age",
                                "no monitoring heartbeat has ever been recorded", [beat_path]))
    out.append(_metric("supervision_healthy", "Monitoring confirmed healthy",
                       bool(supervision.get("healthy")), [beat_path],
                       detail="reported reason: %s" % (supervision.get("reason") or "unknown")))
    out.append(_metric("supervision_recovering", "Notification recovery in progress",
                       bool(supervision.get("recovery_marker")), [_state_path(".watcher-down")]))

    # -- observed outcomes, from ALREADY-RETAINED status history -----------
    # Scoped honestly: these are counts over the retained tail of each status
    # log, not lifetime rates, because no history beyond that tail is kept.
    verbs: dict[str, int] = {}
    event_sources, truncated_any = [], False
    for ev in events:
        if not ev.get("readable"):
            continue
        event_sources.append(ev.get("path"))
        if ev.get("truncated"):
            truncated_any = True
        for line in ev.get("lines") or []:
            verb = (line.get("verb") or "").strip().lower()
            if verb:
                verbs[verb] = verbs.get(verb, 0) + 1
    if event_sources:
        scope = "counted over the retained status tail only"
        if truncated_any:
            scope += "; older events were dropped by the read bound"
        for verb, label in (("done", "Completions observed"),
                            ("failed", "Failures observed"),
                            ("blocked", "Blocks observed"),
                            ("resolved", "Blocks cleared"),
                            ("needs-decision", "Decisions raised")):
            out.append(_metric("observed_%s" % verb.replace("-", "_"), label,
                               verbs.get(verb, 0), sorted(set(event_sources)),
                               kind="retained_history", detail=scope))
    else:
        out.append(_unavailable("observed_done", "Completions observed",
                                "no readable status history in this home",
                                [roots_state]))

    # -- delivery (recorded locally, never a live check) -------------------
    recorded = [t for t in tasks if (t.get("pr") or {}).get("url")]
    pr_sources = [t["paths"]["meta"]["path"] for t in recorded
                  if (t.get("paths") or {}).get("meta", {}).get("path")]
    # A count of zero still has to say where it looked, or the reader cannot
    # tell "nothing recorded" from "nothing read".
    out.append(_metric("recorded_prs", "Pull requests recorded", len(recorded),
                       pr_sources or [roots_state, backlog_path],
                       detail="recorded locally; this server makes no network call, "
                              "so no live check state is claimed"))

    # -- runtime identity --------------------------------------------------
    out.append(_metric("workers", "Workers", len([t for t in tasks if t.get("kind") != "secondmate"]),
                       [(snapshot.get("roots") or {}).get("state")]))
    out.append(_metric("secondmates", "Second mates",
                       len([t for t in tasks if t.get("kind") == "secondmate"]),
                       [(snapshot.get("roots") or {}).get("state")]))

    # -- explicitly unavailable, by construction ---------------------------
    budget = usage.get("budget") or {}
    out.append(_unavailable(
        "token_usage", "Model token usage",
        "no vendor usage meter exists locally; the only local token record is a "
        "conservative ceil(bytes/3) estimate of this home's startup memory files, "
        "which is a budget estimate and not consumption",
        [os.path.join(HOME, "config", "startup-memory-budget")] if HOME else []))
    if budget.get("available"):
        out.append(_metric("startup_memory_tokens", "Startup memory estimate",
                           budget.get("total_estimated_tokens"),
                           [os.path.join(HOME, "config", "startup-memory-budget")] if HOME else [],
                           unit="estimated tokens",
                           detail="conservative local estimate, not a vendor meter; "
                                  "budget %s" % budget.get("effective_budget_tokens")))
    out.append(_unavailable(
        "supervision_uptime_ratio", "Monitoring uptime",
        "this home retains no supervision time series and no durable metrics "
        "store is permitted, so an uptime ratio cannot be computed from evidence"))
    out.append(_unavailable(
        "throughput_trend", "Throughput trend",
        "no retained time series; only point-in-time values and the retained "
        "status tail are available"))
    return out


def alerts_from(payload: dict, metrics: list[dict]) -> list[dict]:
    """Severity rollup. Every alert names the evidence that raised it."""
    out = []
    supervision = payload.get("supervision") or {}
    snapshot = payload.get("snapshot") or {}
    if not supervision.get("healthy"):
        out.append({"severity": "critical", "key": "supervision",
                    "title": "Monitoring is not confirmed healthy",
                    "detail": "reported reason: %s" % (supervision.get("reason") or "unknown"),
                    "sources": [_state_path(".last-watcher-beat")]})
    inventory = snapshot.get("main_inventory") or {}
    if inventory.get("valid") is False:
        out.append({"severity": "critical", "key": "inventory",
                    "title": "Current-work inventory does not add up",
                    "detail": inventory.get("reason") or "",
                    "sources": [(snapshot.get("backlog") or {}).get("path")]})
    for d in payload.get("degraded") or []:
        out.append({"severity": "warning", "key": "degraded",
                    "title": "Evidence not shown: %s" % d.get("source"),
                    "detail": d.get("reason") or "", "sources": [d.get("path")]})
    for t in snapshot.get("tasks") or []:
        for dec in ((t.get("hints") or {}).get("open_decisions") or []):
            out.append({"severity": "warning", "key": "decision",
                        "title": "Open captain's call: %s" % (dec.get("key") or ""),
                        "detail": dec.get("summary") or "",
                        "sources": [((t.get("paths") or {}).get("status_log") or {}).get("path")]})
    if supervision.get("away_mode"):
        out.append({"severity": "info", "key": "afk", "title": "Away mode is on",
                    "detail": "routine notifications are handled without interrupting",
                    "sources": [_state_path(".afk")]})
    return out


# --- versioned API documents ----------------------------------------------

def _iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def envelope(resource: str, data, payload: dict, generation: int, sources) -> dict:
    """One shape for every resource, so a client always knows how old an answer
    is and exactly which records produced it."""
    collected = EVIDENCE.collected_at()
    snapshot = payload.get("snapshot") or {}
    return {
        "schema": "fm-dashboard-api.v1",
        "resource": resource,
        "generation": generation,
        "home": payload.get("fm_home"),
        "collected_at": payload.get("generated"),
        "observed_at": _iso(_now()),
        "age_seconds": max(0, int(_now() - collected)) if collected else None,
        "upstream": {
            "schema": snapshot.get("schema"),
            "generated": snapshot.get("generated"),
        },
        "sources": [s for s in sources if s],
        "data": data,
    }


def _task_sources(task: dict) -> list:
    paths = task.get("paths") or {}
    return [((paths.get("meta") or {}).get("path")),
            ((paths.get("status_log") or {}).get("path"))]


def _task_report_view(task: dict, reports: dict) -> dict:
    paths = task.get("paths") or {}
    report = paths.get("report") or {}
    report_path = report.get("path")
    if not report_path or report.get("present") is False:
        return task
    indexed = next((item for item in (reports.get("records") or [])
                    if item.get("path") == report_path), None)
    if indexed is not None and indexed.get("readable") is True:
        return task
    updated = dict(task)
    updated_paths = dict(paths)
    updated_report = dict(report)
    updated_report["present"] = False
    updated_report["available"] = False
    updated_report["reason"] = ((indexed or {}).get("reason")
                                 or "the report was omitted by the bounded report index")
    updated_paths["report"] = updated_report
    updated["paths"] = updated_paths
    return updated


def build_document(resource: str, payload: dict, generation: int, arg: str | None):
    snapshot = payload.get("snapshot") or {}
    tasks = snapshot.get("tasks") or []
    roots = snapshot.get("roots") or {}
    backlog_obj = snapshot.get("backlog") or {}
    backlog_available = backlog_obj.get("available", True)
    backlog = backlog_obj.get("records") or [] if backlog_available else []
    events = {e.get("task_id"): e for e in (payload.get("events") or [])}
    reports = payload.get("reports") or {}
    now = _now()

    if resource == "overview":
        metrics = derive_metrics(payload, now)
        return envelope(resource, {
            "metrics": metrics,
            "alerts": alerts_from(payload, metrics),
            "counts": {
                "workers": len([t for t in tasks if t.get("kind") != "secondmate"]),
                "secondmates": len([t for t in tasks if t.get("kind") == "secondmate"]),
                "reports": reports.get("total", 0),
                "degraded": len(payload.get("degraded") or []),
            },
            "backlog": {"available": backlog_available,
                        "reason": backlog_obj.get("reason"),
                        "records": backlog},
            "supervision": payload.get("supervision"),
        }, payload, generation, [roots.get("state"), backlog_obj.get("path")])

    if resource == "metrics":
        return envelope(resource, {"metrics": derive_metrics(payload, now)},
                        payload, generation, [roots.get("state"), backlog_obj.get("path")])

    if resource == "tasks":
        rows = []
        for t in tasks:
            ev = events.get(t.get("id")) or {}
            rows.append({
                "id": t.get("id"), "kind": t.get("kind"),
                "state": (t.get("current_state") or {}).get("state"),
                "state_source": (t.get("current_state") or {}).get("source"),
                "state_detail": (t.get("current_state") or {}).get("detail"),
                "freshness": (t.get("current_state") or {}).get("freshness"),
                "observed_at": (t.get("current_state") or {}).get("observed_at"),
                "harness": t.get("harness"), "model": t.get("model"),
                "effort": t.get("effort"), "backend": t.get("backend"),
                "mode": t.get("mode"), "yolo": t.get("yolo"),
                "endpoint": t.get("endpoint"), "remote": t.get("remote"),
                "pr": t.get("pr"),
                "open_decisions": (t.get("hints") or {}).get("open_decisions") or [],
                "backlog": t.get("backlog"),
                "event_count": ev.get("shown", 0),
                "event_total": ev.get("total", 0),
                "event_readable": bool(ev.get("readable")),
                "sources": _task_sources(t),
            })
        return envelope(resource, {"tasks": rows}, payload, generation, [roots.get("state")])

    if resource == "task":
        for t in tasks:
            if t.get("id") == arg:
                ev = events.get(arg) or {}
                return envelope(resource, {"task": _task_report_view(t, reports), "events": ev},
                                payload, generation, _task_sources(t))
        return None

    if resource == "queue":
        holds = [r for r in backlog
                 if r.get("hold_kind") or r.get("captain_actionable")
                 or (r.get("unresolved_blocker_ids") or [])]
        decisions = []
        for t in tasks:
            for d in ((t.get("hints") or {}).get("open_decisions") or []):
                decisions.append({"task_id": t.get("id"), "decision": d,
                                  "sources": _task_sources(t)})
        return envelope(resource, {
            "wakes": (payload.get("supervision") or {}).get("wakes"),
            "holds": holds, "decisions": decisions,
            "backlog": {"available": backlog_available,
                        "reason": backlog_obj.get("reason")},
        }, payload, generation, [_state_path(".wake-queue"), backlog_obj.get("path")])

    if resource == "backlog":
        return envelope(resource, {"available": backlog_available,
                                    "reason": backlog_obj.get("reason"),
                                    "records": backlog}, payload, generation,
                        [backlog_obj.get("path")])

    if resource == "delivery":
        rows = []
        for t in tasks:
            pr = t.get("pr") or {}
            if pr.get("url"):
                rows.append({"task_id": t.get("id"), "url": pr.get("url"),
                             "source": pr.get("source"), "mode": t.get("mode"),
                             "yolo": t.get("yolo"), "sources": _task_sources(t)})
        for r in backlog:
            if r.get("pr_url") and not any(x["url"] == r["pr_url"] for x in rows):
                rows.append({"task_id": r.get("id"), "url": r.get("pr_url"),
                             "source": "backlog", "merged": r.get("merged"),
                             "sources": [backlog_obj.get("path")]})
        return envelope(resource, {
            "records": rows,
            "note": "recorded locally; this server makes no network call, so no "
                    "live check state is claimed",
        }, payload, generation, [backlog_obj.get("path")])

    if resource == "supervision":
        return envelope(resource, {
            "supervision": payload.get("supervision"),
            "degraded": payload.get("degraded") or [],
            "inventory": snapshot.get("main_inventory"),
        }, payload, generation,
            [_state_path(".last-watcher-beat"), _state_path(".watcher-down"),
             _state_path(".wake-queue")])

    if resource == "usage":
        return envelope(resource, {"usage": payload.get("usage")}, payload, generation,
                        [os.path.join(HOME, "config", "startup-memory-budget") if HOME else None])

    if resource == "reports":
        index = [{"id": r.get("id"), "path": r.get("path"),
                  "readable": r.get("readable"), "reason": r.get("reason"),
                  "bytes": r.get("bytes"), "truncated": r.get("truncated"),
                  "modified": r.get("modified")}
                 for r in (reports.get("records") or [])]
        return envelope(resource, {"reports": index, "total": reports.get("total", 0),
                                   "truncated": reports.get("truncated", 0)},
                        payload, generation, [roots.get("data")])

    if resource == "report":
        for r in (reports.get("records") or []):
            if r.get("id") == arg:
                return envelope(resource, {"report": r}, payload, generation, [r.get("path")])
        return None

    if resource == "sources":
        listed = [{"surface": "home", "path": payload.get("fm_home")},
                  {"surface": "state", "path": roots.get("state")},
                  {"surface": "data", "path": roots.get("data")},
                  {"surface": "projects", "path": roots.get("projects")},
                  {"surface": "backlog", "path": backlog_obj.get("path")},
                  {"surface": "notification queue", "path": _state_path(".wake-queue")},
                  {"surface": "monitor heartbeat", "path": _state_path(".last-watcher-beat")},
                  {"surface": "notification recovery", "path": _state_path(".watcher-down")},
                  {"surface": "away mode", "path": _state_path(".afk")}]
        if HOME:
            listed.append({"surface": "startup memory budget",
                           "path": os.path.join(HOME, "config", "startup-memory-budget")})
        for f in (((payload.get("usage") or {}).get("budget") or {}).get("files") or []):
            listed.append({"surface": "startup memory file",
                           "path": os.path.join(HOME, f.get("file", "")) if HOME else f.get("file")})
        for e in (payload.get("events") or []):
            if e.get("readable"):
                listed.append({"surface": "events %s" % e.get("task_id"), "path": e.get("path")})
        for t in tasks:
            meta = ((t.get("paths") or {}).get("meta") or {}).get("path")
            if meta:
                listed.append({"surface": "task record %s" % t.get("id"), "path": meta})
        for r in (reports.get("records") or []):
            if r.get("readable"):
                listed.append({"surface": "report %s" % r.get("id"), "path": r.get("path")})
        return envelope(resource, {"sources": listed}, payload, generation, [])

    return None


# --- HTTP ------------------------------------------------------------------

def health_body() -> bytes:
    """Built per request, because readiness can stop being true."""
    reason = degraded_reason()
    doc = {
        "schema": "fm-dashboard-health.v1",
        "home": HOME,
        "owner": OWNER_DIGEST,
        "ready": reason is None,
        "api": API_VERSION,
    }
    if reason is not None:
        doc["reason"] = reason
    return json.dumps(doc).encode() + b"\n"

STREAM_CLIENTS = threading.Semaphore(MAX_STREAM_CLIENTS)

# Slowloris defence. A client that dribbles a request one byte at a time never
# trips a per-read timeout, so the request read needs an ABSOLUTE deadline. The
# deadline is reset per request, which keeps keep-alive working, and the stream
# route clears it explicitly because a change stream is meant to stay open.
HTTP_IO_TIMEOUT = 5
REQUEST_READ_TIMEOUT = float(os.environ.get("FM_DASHBOARD_REQUEST_TIMEOUT",
                                            COLLECTOR_TIMEOUT + HTTP_IO_TIMEOUT))


class DeadlineReader:
    """A readline() that gives up at an absolute deadline, not per read."""

    def __init__(self, connection, deadline):
        self.connection = connection
        self.deadline = deadline
        self.buffer = bytearray()

    def readline(self, limit=-1):
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                end = newline + 1
                if limit >= 0:
                    end = min(end, limit)
                result = bytes(self.buffer[:end])
                del self.buffer[:end]
                return result
            if limit >= 0 and len(self.buffer) >= limit:
                result = bytes(self.buffer[:limit])
                del self.buffer[:limit]
                return result
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("request read deadline exceeded")
            self.connection.settimeout(min(HTTP_IO_TIMEOUT, remaining))
            chunk = self.connection.recv(4096)
            if not chunk:
                result = bytes(self.buffer)
                self.buffer.clear()
                return result
            self.buffer.extend(chunk)

    def close(self):
        return None

RESOURCES = {
    "overview", "metrics", "tasks", "queue", "backlog", "delivery",
    "supervision", "usage", "reports", "sources",
}
ITEM_RESOURCES = {"tasks": "task", "reports": "report"}


def safe_asset(name: str) -> tuple[str, str] | None:
    """Resolve one asset by EXACT basename inside the app directory.

    A request never names a path. It names one file, matched against a strict
    charset and an extension allowlist, then resolved and required to sit
    directly inside the app directory and not be a symlink. That is what stops a
    static route from becoming a filesystem read primitive.
    """
    if not APP_DIR or not name:
        return None
    if name != os.path.basename(name):
        return None
    if not all(c.isalnum() or c in "._-" for c in name) or name.startswith("."):
        return None
    ext = os.path.splitext(name)[1]
    ctype = ASSET_TYPES.get(ext)
    if not ctype:
        return None
    return name, ctype


class Handler(BaseHTTPRequestHandler):
    server_version = "fm-dashboard"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # --- refusals ---------------------------------------------------------
    # There is no mutating endpoint, so every mutating method is refused before
    # routing rather than per-handler. A future route cannot accidentally accept
    # one.
    def _refuse_method(self):
        body = b'{"error":"this dashboard is read-only; no mutating method is accepted"}\n'
        self._send(405, body, "application/json; charset=utf-8",
                   extra={"Allow": "GET, HEAD"})

    do_POST = do_PUT = do_PATCH = do_DELETE = _refuse_method
    do_OPTIONS = do_CONNECT = do_TRACE = _refuse_method

    def setup(self):
        super().setup()
        self.rfile = DeadlineReader(self.connection, time.monotonic() + REQUEST_READ_TIMEOUT)

    def handle_one_request(self):
        # Each request gets its own absolute read budget, so keep-alive is not
        # penalised while a dribbling client still cannot hold a thread open.
        self.rfile.deadline = time.monotonic() + REQUEST_READ_TIMEOUT
        try:
            self.connection.settimeout(HTTP_IO_TIMEOUT)
        except OSError:
            pass
        try:
            return super().handle_one_request()
        except (TimeoutError, OSError):
            self.close_connection = True
            return None

    def _send(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        # The app is same-origin only and loads nothing remote; say so, so a
        # stray remote reference fails loudly instead of silently egressing.
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; connect-src 'self'; base-uri 'none'; "
            "form-action 'none'; frame-ancestors 'none'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode() + b"\n", "application/json; charset=utf-8")

    def do_HEAD(self):
        if self.path.split("?", 1)[0].rstrip("/") == "/api/%s/stream" % API_VERSION:
            self._send(405, b'{"error":"the event stream only accepts GET"}\n',
                       "application/json; charset=utf-8", extra={"Allow": "GET"})
            return
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path == "/healthz":
            body = health_body()
            self._send(200 if degraded_reason() is None else 503, body,
                       "application/json; charset=utf-8")
            return

        if path == "/api/%s/stream" % API_VERSION:
            self._stream()
            return

        if path.startswith("/api/"):
            self._api(path)
            return

        if path == "/" or path == "/index.html":
            self._asset("index.html", spa=True)
            return
        if path.startswith("/assets/"):
            self._asset(path[len("/assets/"):])
            return
        # Client-side routing: any other non-API path is a view, so hand back the
        # app shell and let the router resolve it.
        if "." not in os.path.basename(path):
            self._asset("index.html", spa=True)
            return
        self._json(404, {"error": "not found"})

    def _asset(self, name, spa=False):
        resolved = safe_asset(name)
        if not resolved:
            if spa:
                self._send(503, b"the dashboard application assets are not built or not "
                                b"readable; startup should have refused rather than "
                                b"serving a partial app\n",
                           "text/plain; charset=utf-8")
                return
            self._json(404, {"error": "not found"})
            return
        name, ctype = resolved
        try:
            app_fd, _ = open_directory_path(APP_DIR, reject_symlinks=True)
            try:
                fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                             dir_fd=app_fd)
            finally:
                os.close(app_fd)
            try:
                asset_stat = os.fstat(fd)
                if not stat.S_ISREG(asset_stat.st_mode) or asset_stat.st_size > ASSET_MAX_BYTES:
                    self._json(503 if spa else 404, {"error": "asset exceeds the read bound"})
                    return
                body = bytearray()
                while len(body) < asset_stat.st_size:
                    chunk = os.read(fd, min(65536, asset_stat.st_size - len(body)))
                    if not chunk:
                        break
                    body.extend(chunk)
                if len(body) != asset_stat.st_size:
                    self._json(404, {"error": "not found"})
                    return
                body = bytes(body)
            finally:
                os.close(fd)
        except (OSError, RecordError):
            self._json(404, {"error": "not found"})
            return
        self._send(200, body, ctype)

    def _api(self, path):
        parts = [p for p in path.split("/") if p]
        if len(parts) < 3 or parts[0] != "api" or parts[1] != API_VERSION:
            self._json(404, {"error": "unknown api version"})
            return
        resource, arg = parts[2], (parts[3] if len(parts) > 3 else None)
        if len(parts) > 4:
            self._json(404, {"error": "not found"})
            return
        if resource not in RESOURCES:
            self._json(404, {"error": "unknown resource"})
            return
        if arg is not None:
            resource_name = ITEM_RESOURCES.get(resource)
            if not resource_name:
                self._json(404, {"error": "not found"})
                return
        else:
            resource_name = resource

        payload, error, generation = EVIDENCE.current()
        if error or payload is None:
            self._json(503, {"schema": "fm-dashboard-api.v1", "resource": resource_name,
                             "error": error or "no evidence available"})
            return
        doc = build_document(resource_name, payload, generation, arg)
        if doc is None:
            self._json(404, {"error": "not found"})
            return
        self._json(200, doc)

    def _stream(self):
        """Bounded same-origin change stream.

        Emits an event when the evidence generation advances, so the client
        refetches instead of polling. Bounded three ways: a hard client cap, a
        maximum lifetime, and a fixed poll interval, so neither a stuck browser
        tab nor twenty of them can grow work inside this process.
        """
        if not STREAM_CLIENTS.acquire(blocking=False):
            self._json(503, {"error": "too many stream clients", "limit": MAX_STREAM_CLIENTS})
            return
        try:
            # A change stream is meant to stay open, so the request-read budget
            # must not become a response-write budget.
            try:
                self.connection.settimeout(None)
            except OSError:
                pass
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            started = _now()
            # Confirm the stream immediately, using the generation already known.
            # Collecting first would make a client wait for a full evidence read
            # before it learns the stream is even alive.
            last = EVIDENCE.generation()
            self._emit("hello", {"generation": last, "dev_reload": DEV_RELOAD})
            last_dev_asset = _dev_asset_stamp()
            while _now() - started < STREAM_MAX_SECONDS:
                time.sleep(STREAM_POLL_SECONDS)
                current_dev_asset = _dev_asset_stamp()
                if (DEV_RELOAD and last_dev_asset is not None
                        and current_dev_asset is not None
                        and current_dev_asset != last_dev_asset):
                    last_dev_asset = current_dev_asset
                    self._emit("dev_reload", {"observed_at": _iso(_now())})
                _, _, generation = EVIDENCE.current()
                if generation != last:
                    last = generation
                    self._emit("evidence", {"generation": generation,
                                            "observed_at": _iso(_now())})
                else:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            STREAM_CLIENTS.release()

    def _emit(self, event, data):
        self.wfile.write(("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode())
        self.wfile.flush()

    def log_message(self, fmt, *args):
        sys.stderr.write("fm-dashboard: %s\n" % (fmt % args))


def main() -> int:
    # Loopback only. Binding 127.0.0.1 rather than 0.0.0.0 is the whole
    # local-only guarantee, so it is not configurable.
    with ThreadingHTTPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.daemon_threads = True
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
