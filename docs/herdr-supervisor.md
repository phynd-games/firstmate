# Herdr-hosted watcher continuity

`bin/fm-herdr-supervisor.sh` keeps a firstmate home's watcher armed from a Herdr-tracked pane instead of from the primary harness process.
It exists for one failure this fleet actually hit: a home whose harness never loaded its continuity owner has no owner at all, and supervision then ends after a single watcher cycle with nothing to report it.
[`watcher-continuity.md`](watcher-continuity.md) owns the general continuity contract; this file owns the Herdr-hosted owner, what it guarantees, and what it does not.

## The problem it solves

`bin/fm-watch.sh` is deliberately one-shot.
One actionable reason closes one watcher cycle, and `bin/fm-watch-arm.sh` starts or attaches to exactly one such cycle and returns that reason.
Starting the next cycle is a separate job, and every other owner of that job lives inside the primary harness process: Pi's `.pi/extensions/fm-primary-pi-watch.ts`, Claude's Stop auto-arm, Cursor's stop-hook park, OpenCode's TUI plugin, Codex's foreground checkpoint.

On 2026-08-29 a Pi primary was launched with its project root set to the parent of the firstmate root.
Pi discovers project-local extensions relative to that root, found no `.pi/extensions/` there, and loaded neither primary extension.
The absent `state/.pi-watch-extension-loaded` marker proves it: the extension writes that marker whenever it loads in the session that holds the home lock.

With no extension there was no continuity owner, so each hand-started arm delivered exactly one wake and exited.
`state/.watch-cycle-exits.log` recorded the signature plainly - three cycles, each `successor=none` - and after the third, supervision was simply off, with three tasks in flight.

The existing session-start check detects the missing extension but only advises restarting Pi, and it runs once per session.
Nothing armed a watcher in the meantime and nothing rechecked.

## What it is

A continuity owner hosted in a Herdr pane.
`ensure` creates one workspace for the home, runs the loop in that workspace's pane through `herdr pane run`, and records the exact binding.

Two mechanics there are load-bearing, and both were learned from the real-Herdr smoke rather than from reading the API.
`herdr pane run` types its command into the pane's shell, so the command is subject to that terminal's line-length limit; an inlined environment made it long enough that a home with an ordinary temp-directory path silently ran a command truncated mid-argument while the CLI still reported success.
The command is therefore kept short and constant, and everything the loop needs travels in `state/.herdr-supervisor-launch.sh`.
The pane shell's environment comes from Herdr rather than from the calling process, so that launcher must carry every value explicitly, including the tuning this home resolved.
The loop calls `bin/fm-watch-arm.sh` and calls it again after every close, which is precisely what a harness-native owner does.

Because its host is a Herdr pane rather than the harness process, it survives every harness session transition - startup, new, resume, fork, compaction, reload, and session idle - and every watcher-cycle close, without depending on the model remembering a re-arm step.

## What it is not

It is not a second lifecycle authority.

- It starts nothing but `bin/fm-watch-arm.sh`.
  The arm layer stays the only thing that starts, attaches to, or verifies a watcher, and `state/.watch.lock` stays the only singleton.
- It uses the plain attach-or-start arm for healthy watchers, and uses `--restart` only for a live watcher whose home, path, process identity, and beacon staleness are all verified.
  A second supervisor that somehow raced past the establish lock attaches to the live watcher rather than evicting it, so the one-watcher singleton holds even under a duplicate arm.
- It never writes `state/.last-watcher-beat`.
  Only the watcher touches that beacon, so no helper can make a wedged watcher look alive.
- It never acknowledges a wake, merges, tears down, promotes, steers a task, or invokes no-mistakes.
  Its only durable queue write is the `check: herdr-supervisor` escalation below.
- It becomes a Herdr-tracked standby whenever another owner is provable, preserving the exact binding so it can resume if that owner disappears; only one owner actively arms a watcher.

## When it runs

`ensure` establishes only when every one of these holds.

- The home's runtime backend is `herdr`.
- The named Herdr session already has a running server.
  The supervisor never starts one: `ensure` runs inside a command substitution on the session-start path, and backgrounding a long-lived server from there wedges the caller, which would take bootstrap down with it.
  A home whose server is down has already lost the host this supervisor would live in, so it refuses with a durable diagnostic instead.
- `config/herdr-supervisor` is not `off`.
- Supervision is genuinely needed - in-flight work, a registered event source, or a Relay poll.
- No other owner is provable.
  Away mode is provable through `state/.afk` plus its live daemon lock and identity, and a loaded Pi primary extension is provable through either extension marker naming a live verified harness process at its current on-disk build.

With `config/herdr-supervisor` absent or `auto`, the default scope is exactly the harness class this was built for: a supervision model of `extension`, meaning Pi or pi-signed, whose owner lives in a project-local extension that can silently fail to load.
Any other harness needs a deliberate `on`, because its owner's presence is not provable from durable state and guessing would create the duplicate owner this design exists to avoid.

`bin/fm-bootstrap.sh` calls `ensure` as a local mutating sweep on the locked path only, so a read-only session neither establishes nor disturbs a supervisor.
Ordinary outcomes are silent; only a failure prints a `HERDR_SUPERVISOR:` line.

## How health is decided

Health is never inferred from a beacon alone, and never from a name.
`status` reports healthy only when all of the following agree.

- The binding record exists, is version 1, and names this home.
- A live record exists whose generation equals the binding's generation.
- The supervisor's own heartbeat is fresh within its grace, default 120 seconds.
  This beacon is separate from the watcher's and answers a different question: is the continuity owner alive.
- The recorded process is alive, and its current `fm_pid_identity` equals the recorded one, so a recycled pid cannot pass.
- The named Herdr session, canonical socket, and socket-instance identity still match the recorded ones.
- `herdr pane get` returns the exact recorded pane in the exact recorded tab and workspace.
- `herdr pane process-info` reports the recorded supervisor as the pane's tracked foreground process.

Anything unreadable, contradictory, or unknown is unhealthy.
An ambiguous answer is never resolved in favour of healthy.

Every Herdr call the supervisor makes is hard-bounded, default 15 seconds, through the shared `bin/fm-timeout-lib.sh` runner that kills the whole process group.
A vendor CLI that never returns is a real hazard here rather than a theoretical one, because `ensure` runs inside a command substitution during session start; an unbounded call would wedge bootstrap itself, which is strictly worse than the supervision lapse this exists to fix.

## Recovery

Recovery is bounded, idempotent, and generation-safe.

| Situation | What happens |
| --- | --- |
| Watcher exits on a wake | The loop re-arms immediately; the wake is already durable on the queue |
| Arm crashes, is killed, or fails | Every attempt leaves a durable alarm, ledger entry, and queue escalation; bounded exponential retry runs in rounds of five attempts by default while the tracked continuity owner remains alive |
| Stale or dead watcher lock | A dead holder is reclaimed by the arm layer's own self-eviction and steal path; an identity-verified live holder with a stale beacon is replaced through the arm's bounded `--restart` path |
| Stale or missing watcher beacon | An identity-verified live holder is replaced through the arm's bounded `--restart` path; unknown holders fail closed with durable escalation |
| Supervisor process killed | Unhealthy at the next `ensure`, which establishes a fresh generation |
| Supervisor wedged but alive | Its heartbeat goes stale and it reads unhealthy, even though the process and pane still check out |
| Herdr pane closed or moved | The pane binding stops matching and it reads unhealthy |
| Primary harness session replaced | Nothing happens; the supervisor is not bound to that process |
| Herdr server or session replaced | The old binding is retained as generation-named quarantine evidence without closing through the new server; once the named server is available again, `ensure` can establish a fresh generation |
| Duplicate arm | Only the generation the binding record names may arm; every other generation stands down |
| Rapid repeated cycles | A floor delay plus one durable diagnostic, never a stop, because a busy fleet does produce fast cycles |
| Herdr server not running | Refused with a durable diagnostic naming the missing server; no server is ever started from here |
| Herdr CLI hangs | Bounded and treated as a failed read, so no caller can be wedged |

Every failed or ambiguous establish and every failed arm attempt writes `state/.herdr-supervisor-alarm` and appends one `check: herdr-supervisor` record to the durable wake queue.
The latest alarm is retained after a later successful cycle, and each alarm is appended to `state/.herdr-supervisor-alarm-history` for per-attempt evidence.
When another owner is provable, the Herdr loop remains alive as a standby and rechecks ownership until it can resume arming.
That reuses the channels that already exist rather than inventing one, so the lapse reaches the captain through the normal drain.

## Guarantees, and what is not guaranteed

Guaranteed while the Herdr server that hosts the supervisor stays up:

- After one successful `ensure`, a watcher cycle follows every watcher cycle until the home stops needing supervision, another owner takes over, or an external Herdr failure prevents the tracked owner from continuing.
- At most one active watcher-arm authority per home; a Herdr standby may preserve the handoff binding while another owner is active.
- No wake is lost, because the watcher appends every reason to the durable queue before it exits.
- No healthy claim from a stale beacon, a recycled pid, or an unknown Herdr pane.

Not guaranteed, and deliberately not promised:

- **Recovery across a dead Herdr server or host.**
  The supervisor's host pane dies with them.
  Nothing inside Herdr can restart it, and no in-process fallback is offered, because one would be a second lifecycle authority.
  The gap is detected at the next `ensure`, which finds the socket changed or the pane gone, reports unhealthy, and establishes a new generation.
  The external prerequisite is therefore a live Herdr server plus something that calls `ensure` again after it returns - normally session start.
- **Notification latency into a harness session this process does not own.**
  The supervisor restores continuity and durability, not delivery.
  For a home with no harness-native owner, the model sees a queued wake at its next drain, session start, or guard banner, not the instant it is queued.
  Closing that gap needs a loaded harness continuity owner; the supervisor is what keeps the fleet supervised until there is one.
- **Zero-latency re-arm.**
  Lock verification, watcher startup, and bounded retry delays are deliberate safety work.

## Configuration

`config/herdr-supervisor` is local and gitignored.
`auto` or absent is the default scope above, `on` hosts continuity in Herdr for any harness, and `off` disables it entirely.
[`configuration.md`](configuration.md#herdr-hosted-watcher-continuity-configherdr-supervisor) owns the setting; this file owns the behavior behind it.

Tuning environment variables, all optional, are named in the script header: heartbeat grace, readiness timeout, retry limit, retry backoff base and cap, idle interval, rapid-cycle thresholds, and ledger bounds.

## Durable records

All under `state/`, all private to the home.

- `.herdr-supervisor` - the binding: generation, home, Herdr session, canonical socket and socket-instance identity, workspace, tab, pane, and active or quarantine mode.
  Written only by `ensure` and `retire`.
- `.herdr-supervisor-live` - the loop's own generation, pid, and process identity.
  Written only by the loop.
  It is a separate file on purpose: `ensure` holds the establish lock across the wait for the loop to come up, so a single shared record would deadlock the loop that has to publish into it.
- `.herdr-supervisor-launch.sh` - the generated launcher the pane executes, mode 0700.
  It exists so the pane command can stay short; it is rewritten on every establish and removed on retire, and is never edited by hand.
- `.herdr-supervisor-heartbeat` - the supervisor's liveness beacon, refreshed every pass and while the arm child is waiting.
- `.herdr-supervisor-pending-cleanup` - an exact session, socket, workspace, tab, and pane receipt retained across uncertain establish or retirement cleanup.
- `.herdr-supervisor-quarantine.<generation>` - an exact old binding retained when the recorded Herdr server or pane identity can no longer be proven safe to close.
- `.herdr-supervisor-alarm` - the latest durable actionable diagnostic; it remains available after later recovery so the last failed attempt is not erased.
- `.herdr-supervisor-alarm-history` - the append-only per-attempt alarm history.
- `.herdr-supervisor-emergency` - fallback evidence when alarm or queue persistence fails.
- `.herdr-supervisor.log` - a bounded lifecycle ledger.
  Diagnostic evidence only, written best-effort, and never read as authority for any decision, so an observability failure cannot stall supervision.
- `.lock-pid-identity` - the process-instance identity paired with the Pi session lock.

## Regression coverage

`tests/fm-herdr-supervisor.test.sh` drives the real script against a stateful fake Herdr CLI and a scripted arm.
It proves the central claim by counting arm invocations - one establish must produce many cycles, which is exactly what the incident lacked - and covers deference to away mode and to a loaded Pi extension, standby handoff, idempotent repeat establishes, recycled pids, post-query identity changes, superseded generations, stale heartbeats on a live but stopped supervisor, foreign pane processes, replaced Herdr servers, broken pane bindings, bounded retry with durable escalation, incomplete and partial Herdr responses, quarantine cleanup, retire, beacon separation, and both config gates.

Every gate in that list is mutation-tested: reverting the guard in the script makes its case fail.

`tests/fm-herdr-supervisor-smoke.test.sh` is the real-Herdr contract, and it passes.
It runs entirely inside a named non-default `fm-lab-*` session provisioned and torn down through `bin/fm-herdr-lab.sh`, whose fleet-state tripwire proves the default session never changed.
It establishes against a real server, checks that Herdr's own process tracking names the live supervisor in its pane, proves continuity by counting real watcher cycles, proves a duplicate real arm attaches without a second watcher, proves a repeat `ensure` adds no second pane or owner, kills the supervisor and proves a new generation takes over, and proves `retire` releases both the record and its own workspace.

That suite is in the `real-herdr-gated` family, so it never runs in a portable CI lane.
It is where the two mechanics above were found: the pane-command truncation, and the server-start hang that a fake CLI cannot reproduce.
