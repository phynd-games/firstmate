# The local control-plane dashboard

A read-only React application, served by Firstmate over loopback, showing everything this home records about its own agent activity.
It is a supervision surface, not a control surface: Firstmate remains the only way to prompt, steer, merge, or tear down anything.
The server makes no network call, and the client loads nothing remote.

## Run it

Every Firstmate session start brings it up and prints its URL:

```
DASHBOARD
dashboard: started on 127.0.0.1 (read-only)
FIRSTMATE_DASHBOARD_URL=http://127.0.0.1:8787/
```

By hand:

```
bin/fm-dashboard-start.sh ensure    # start or adopt, then print the proven URL
bin/fm-dashboard-start.sh status    # report the owner, changing nothing
bin/fm-dashboard-start.sh stop      # close the pane this home owns
```

`bin/fm-dashboard-start.sh` owns startup and `bin/fm-session-start.sh` calls it.
The server runs inside a Herdr pane created for it, so the process is always attributable to a pane Herdr tracks.
There is no tmux path, and nothing is launched with `&`, `nohup`, `disown`, or `setsid`.

**The URL is a promise, not a guess.** It is printed only after this command has proven, in order: the owner record, that the listener is bound on `127.0.0.1`, the exact port, that the pane still exists, that the process answering is this dashboard for this home, and that the application shell and its bundle are actually being served.
Anything unproven prints `DASHBOARD_BLOCKED: <reason>` and no URL at all.
A blocked dashboard never fails session start, because supervision does not depend on it.

**Identity, not just a port.** Startup mints a random owner token, keeps it in the `0600` owner record, and passes only its SHA-256 digest to the server, which republishes that digest on `/healthz`.
A health answer counts as this home's dashboard only when its schema, home, and owner digest all match.
That is what separates our dashboard from an unrelated local process that happens to hold the port.

**Repeat starts converge.** A per-home lock serializes concurrent starts; a start that cannot take the lock waits and reports the winner's URL rather than starting a second server.
A record whose pane is gone, whose health does not answer, or whose identity does not match is stale: its pane is closed, the record dropped, and startup begins again.
A pane whose state Herdr cannot confirm is neither reclaimed nor discarded, because starting a second server beside one that may still be live is exactly the false claim this refuses to make.
A port held by something that is not ours is a collision, and startup moves to the next candidate.

## How it is built

```
authoritative text records
  -> bin/fm-dashboard.sh json        the bounded, symlink-safe evidence collector
  -> bin/fm_dashboard_server.py      cache, normalizers, versioned read-only API
  -> the React client                query layer, then views
```

The browser never reads a filesystem path.
It calls the API, and the API is the only thing that opens a record.
Every path decision, bound, and symlink check happens server-side, once, instead of being re-implemented in a client that cannot be trusted with a path.

The client lives in `ui/` and is bundled by esbuild into `assets/dashboard/`, which is **committed**.
That is what lets a fresh machine, and CI, serve the dashboard with no network and no install step: the toolchain is a development convenience, never a runtime or CI dependency.

```
bin/fm-dashboard-build.sh build     rebuild from ui/src when a toolchain exists
bin/fm-dashboard-build.sh verify    check the committed bundle is complete
bin/fm-dashboard-build.sh watch     rebuild on change (development)
npm ci --prefix ui                  install the toolchain (development only)
```

For live development, `bin/fm-dashboard.sh serve --dev` treats the built client as evidence too, so a rebuild reaches the browser the same way a changed record does.

## The API

Every resource answers one `fm-dashboard-api.v1` envelope carrying `collected_at`, `observed_at`, `age_seconds`, `generation`, the upstream snapshot identity, and the exact `sources` behind it, so a view never has to guess how old an answer is or where it came from.

| Route | What it answers |
| ----- | --------------- |
| `/api/v1/overview` | metrics, alerts, counts |
| `/api/v1/metrics` | derived metrics with provenance |
| `/api/v1/tasks`, `/api/v1/tasks/<id>` | worker table; one worker with its event timeline |
| `/api/v1/queue` | notifications, holds, open captain's calls |
| `/api/v1/backlog` | backlog records as recorded |
| `/api/v1/delivery` | pull requests recorded locally |
| `/api/v1/supervision` | monitoring, recovery, evidence gaps |
| `/api/v1/usage` | dispatched runtimes and the startup-memory estimate |
| `/api/v1/reports`, `/api/v1/reports/<id>` | report index; one report body |
| `/api/v1/sources` | every path the server read |
| `/api/v1/stream` | bounded change stream (SSE) |
| `/healthz` | identity and readiness |

The stream pushes only a generation number; the client refetches what it is showing.
That keeps the stream tiny and means a missed event costs one stale render, never a wrong one.

## Metrics: what is real, and what is not

Firstmate keeps no metrics store, and the captain has ruled that none may be added.
Metrics are therefore either point-in-time reads of current records, or derived from history Firstmate already retains.
Every metric names its own sources; anything this home cannot support is reported unavailable with a reason.

Derived exactly, point-in-time: work in flight, queue depth, oldest work in flight, unacknowledged notifications, oldest notification waiting, monitor heartbeat age, monitoring health, recovery state, recorded pull requests, worker and second-mate counts.

Derived from already-retained history: completions, failures, blocks, blocks cleared, and decisions raised, counted over the retained status tail and labelled as such, including when the read bound dropped older events.

**Reported unavailable, by construction:**

- **Model token usage.** No vendor usage meter exists locally. The only local token record is a conservative `ceil(bytes/3)` estimate of this home's startup-memory files, which is a budget, not consumption, and is shown separately labelled as an estimate.
- **Monitoring uptime as a ratio**, and **throughput trend**. This home retains no time series and no durable metrics store is permitted, so neither can be computed from evidence.
- **Live CI state.** Pull requests are shown as recorded locally; the server makes no network call, so no live check state is claimed.

## Safety boundaries

- **Read-only.** There is no endpoint that launches, routes, steers, acknowledges, merges, tears down, or controls anything. Every mutating HTTP method is refused with `405` before routing, so a future route cannot accidentally accept one.
- **Loopback only.** The bind address is `127.0.0.1` and is not configurable. Health and readiness probes disable proxies explicitly, so a loopback check never leaves the machine.
- **The asset route is not a filesystem read.** A request names one file, not a path: it is matched against a strict charset, an extension allowlist, and a realpath containment check inside the application directory, and must not be a symlink.
- **Path-safe and symlink-safe reads.** A status log or report is read only when it is a regular file, is not itself a symlink, and resolves inside this home's state or data root. Anything refused is disclosed in `degraded[]` and surfaced on the page.
- **Bounded.** Event tails, notification records, report count and bytes, the collector timeout, the evidence cache, stream client count, and stream lifetime all have limits, and every limit discloses what it dropped.
- **Never executable.** Report bodies are served as JSON data and rendered into React elements, never as markup. Raw HTML in a report stays visible as literal text, and only an `http(s)` target becomes a link.

The dashboard renders whatever your local records contain and applies no redaction, because hiding evidence from a supervision surface is worse than showing it.
Treat what it serves as exactly as sensitive as the `data/` and `state/` files behind it.

## Tuning

| Variable | Default | Effect |
| -------- | ------- | ------ |
| `FM_DASHBOARD_PORT` | 8787 | first candidate port |
| `FM_DASHBOARD_PORT_TRIES` | 10 | candidate ports before giving up |
| `FM_DASHBOARD_READY_TRIES` | 30 | readiness polls before giving up |
| `FM_DASHBOARD_READY_DELAY_MS` | 200 | delay between readiness polls |
| `FM_DASHBOARD_LOCK_WAIT` | 15 | seconds to wait for the startup lock |
| `FM_DASHBOARD_EVENT_LINES` | 40 | status-log lines kept per task |
| `FM_DASHBOARD_WAKES` | 50 | notification records kept |
| `FM_DASHBOARD_REPORTS` | 40 | report bodies read |
| `FM_DASHBOARD_REPORT_BYTES` | 65536 | bytes read per report body |
| `FM_DASHBOARD_CACHE_TTL` | 2 | seconds before the evidence stamp is re-checked |
| `FM_DASHBOARD_MAX_STREAM_CLIENTS` | 8 | concurrent stream clients |

## Related

- [scripts.md](scripts.md) lists every `bin/` entrypoint.
- [architecture.md](architecture.md) covers the supervision machinery the dashboard reports on.
