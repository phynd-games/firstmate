# The local control-plane dashboard

`bin/fm-dashboard.sh` renders one read-only page showing everything this firstmate home records about its own agent activity.
It is a supervision surface, not a control surface: firstmate remains the only way to prompt, steer, merge, or tear down anything.
The page never acts, and it makes no network call at all.

## Run it

```
bin/fm-dashboard.sh build
```

That writes `$FM_HOME/.dashboard/control-plane.html` and prints the path.
Open the file directly; it is self-contained, needs no server, and renders with no network access.
Re-run `build` whenever you want fresh evidence.

For a page that refreshes on reload instead:

```
bin/fm-dashboard.sh serve
```

`serve` binds `127.0.0.1` and nothing else, answers only `/` and `/healthz`, serves no file from disk, and rebuilds the payload on every request.
It needs `python3`, and it refuses with that requirement named when `python3` is absent.
It proves the page builds before it binds a port, so a broken home fails at startup rather than on the first request.
Stop it with Ctrl-C.

Two more subcommands are useful when something looks wrong:

```
bin/fm-dashboard.sh json > evidence.json    # the payload alone, for inspection
bin/fm-dashboard.sh render evidence.json    # rebuild the page from a saved payload
bin/fm-dashboard.sh path                    # this home's stable page path
```

`FM_HOME` selects the home, exactly as it does for every other firstmate command.

## It starts itself

Every firstmate session start brings the dashboard up and prints its URL:

```
DASHBOARD
dashboard: started on 127.0.0.1 (read-only)
FIRSTMATE_DASHBOARD_URL=http://127.0.0.1:8787/
```

`bin/fm-dashboard-start.sh` owns that, and `bin/fm-session-start.sh` calls it.
The server runs inside a Herdr pane created for it, so the process is always attributable to a pane Herdr tracks; there is no tmux path and nothing is ever launched with `&`, `nohup`, or `disown`.

**The URL is a promise, not a guess.** It is printed only after this command has proven, in order: the owner record, that the listener is bound on `127.0.0.1`, the exact port, that the pane still exists, and that the process answering that port is this dashboard for this home.
Anything unproven prints `DASHBOARD_BLOCKED: <reason>` and no URL at all.
A blocked dashboard never fails session start, because supervision does not depend on it.

**Identity, not just a port.** Startup mints a random owner token, keeps it in the `0600` owner record, and passes only its SHA-256 digest to the server, which republishes that digest on `/healthz`.
A health answer counts as this home's dashboard only when its schema, home, and owner digest all match.
That is what separates our dashboard from an unrelated local process that happens to hold the port, which a bare port check cannot tell apart.

**Repeat starts converge.** A per-home lock serializes concurrent starts, and a start that cannot take the lock waits, re-reads the winner's record, and reports that URL rather than starting a second server.
A record whose pane is gone, whose health does not answer, or whose identity does not match is stale: its pane is closed, the record is dropped, and startup begins again.
A pane whose state Herdr cannot confirm is neither reclaimed nor discarded - starting a second server beside one that may still be live is exactly the false claim the command refuses to make.

**Ports.** A port already held by something that is not ours is a collision, and startup moves to the next candidate rather than reporting a URL that belongs to another process.

Operate it by hand with:

```
bin/fm-dashboard-start.sh status   # report the owner, changing nothing
bin/fm-dashboard-start.sh stop     # close the pane this home owns
bin/fm-dashboard-start.sh ensure   # start or adopt, then print the proven URL
```

Attempt history lands in `state/.dashboard-start.log`, bounded, one line per outcome.

| Variable | Default | Effect |
| -------- | ------- | ------ |
| `FM_DASHBOARD_PORT` | 8787 | first candidate port |
| `FM_DASHBOARD_PORT_TRIES` | 10 | candidate ports before giving up |
| `FM_DASHBOARD_READY_TRIES` | 30 | readiness polls before giving up |
| `FM_DASHBOARD_READY_DELAY_MS` | 200 | delay between readiness polls |
| `FM_DASHBOARD_LOCK_WAIT` | 15 | seconds to wait for the startup lock |

## What the page shows

Each section names the exact file it came from, and the Sources section lists every path the page read, so any claim on the page can be checked at its source.

- **Workers and second mates** - one card per running worker: reconciled current state, the runtime, model and effort its spawn recorded, its endpoint, its local copy, and any recorded pull request. Each card carries the worker's own event history and, where one exists, its report.
- **Captain's calls and holds** - open decisions raised by workers, plus every backlog row held for the captain, with the hold reason, any deferral date, and unresolved blockers.
- **Backlog** - in flight, queued, and done, exactly as recorded in `data/backlog.md`.
- **Delivery evidence** - every pull request recorded locally, with where the record came from. Nothing here is a live check.
- **Reports and findings** - durable worker deliverables, opened in a reader inside the page.
- **Queued notifications** - durable records firstmate has not yet handled and acknowledged.
- **Model and token records** - the runtime each worker was dispatched on, and this home's startup-memory budget.

Current state and event history are deliberately kept apart.
A worker's state badge is reconciled at read time through the canonical snapshot; the event log below it is the status file's own history, newest first, and is never presented as current state.

## Where its facts come from

The dashboard is a renderer over existing read-only owners and never becomes a second authority:

| Surface | Owner |
| ------- | ----- |
| Fleet, backlog, tasks, endpoints, decisions, reports | `bin/fm-fleet-snapshot.sh --json`, embedded verbatim |
| Supervision health and the monitoring model | `bin/fm-wake-lib.sh` |
| Status-line verbs and notes | `bin/fm-classify-lib.sh` |
| The local token estimate | `bin/fm-startup-memory-budget.sh report` |

What the dashboard adds is only bounded presentation evidence the canonical snapshot deliberately does not project: status-log tails, queued wake records, and report bodies, each read from a path the snapshot itself supplies.
If the fleet snapshot fails, the dashboard refuses to render rather than showing a page that reads as an idle fleet.

## Safety boundaries

- **Read-only, with one disclosed exception.** Sourcing `bin/fm-wake-lib.sh` creates this home's `state/` directory when it is absent. Nothing else writes to `data/`, `state/`, or `projects/`.
- **Local only.** It binds `127.0.0.1` and nothing else, and makes no network, GitHub, or authentication call on any path. Recorded pull requests are labelled as recorded, never as a live check, and the page loads no remote font, script, or stylesheet.
- **Path-safe and symlink-safe.** A status log or report is read only when it is a regular file, is not itself a symlink, and resolves inside this home's state or data root. Anything refused is disclosed in `degraded[]` and named on the page.
- **Bounded.** Event tails, queued notifications, report count, and report bytes all have caps, and every cap discloses what it dropped.
- **Never executable.** Report bodies and status lines reach the page as text nodes. Markdown is rendered into real elements built through the DOM, so a report can style itself but can never inject script or markup, and only an `http(s)` target ever becomes a live link.
- **Private on disk.** The page is written under a `077` umask with mode `0600`, in a gitignored directory.

The page renders whatever your local files contain.
It applies no redaction, because hiding evidence from a supervision surface is worse than showing it, so treat the built page as being exactly as sensitive as the `data/` and `state/` files it draws from and do not copy it somewhere those files would not go.

## Bounds

| Variable | Default | Effect |
| -------- | ------- | ------ |
| `FM_DASHBOARD_EVENT_LINES` | 40 | status-log lines kept per task |
| `FM_DASHBOARD_WAKES` | 50 | queued notification records kept |
| `FM_DASHBOARD_REPORTS` | 40 | report bodies read |
| `FM_DASHBOARD_REPORT_BYTES` | 65536 | bytes read per report body |
| `FM_DASHBOARD_PORT` | 8787 | default `serve` port |

Each is validated as a positive integer, and an invalid value is refused by name rather than replaced with a default.

## Related

- [scripts.md](scripts.md) lists every `bin/` entrypoint.
- [architecture.md](architecture.md) covers the supervision machinery the dashboard reports on.
- The `/bearings` fleet board is the decision surface for picking work back up; this dashboard is the complete observational view.
