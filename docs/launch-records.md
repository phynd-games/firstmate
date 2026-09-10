# Launch records

Every launch Firstmate owns - a worker (crewmate, scout, or secondmate) and each Firstmate-owned long-lived helper - leaves a durable launch record: what Firstmate intended to start, what the runtime actually created, whether it became ready, and how it ended.
What is retained, exactly: the subject's current launch with up to 64 history events, and its last 8 previous launches with their terminal outcomes; a task's record is removed by teardown after the `retired` outcome (teardown's own backlog close and completion note are what outlive it), a process-event runner's record is removed when its source is retired, and the other helper records persist with their subject.
`bin/fm-launch-record.py` is the single owner of the record contract (its header owns the exact commands, phases, fields, and exit codes); `bin/fm-launch-record-lib.sh` is the shell seam the launch owners call.
This page is the operator view: what the records mean, where they live, what they guarantee, and what they deliberately do not.

## Why

A launch used to be accountable only after it fully succeeded: a worker's task record was published hundreds of steps after the Herdr creation call, and nothing durable existed in between.
A launcher interrupted or refused in that window left either a silent orphan in Herdr or nothing at all, and the only way to know which was to look.
The record closes that gap by being written before the first external creation call and by keeping an explicit obligation whenever the effect of a launch cannot be proven.

## Where the records live

| Record | Subject |
| --- | --- |
| `state/<task-id>.launch` | one worker task; removed by teardown after a `retired` outcome |
| `state/.launch-docs-reader` | the local document reader (`bin/fm-docs-reader.sh`) |
| `state/.launch-herdr-supervisor` | the Herdr-hosted watcher continuity owner (`bin/fm-herdr-supervisor.sh`) |
| `state/.launch-herdr-supervisor-monitor` | that supervisor's detached monitor |
| `state/.launch-afk-daemon` | the away-mode daemon terminal (`bin/fm-afk-launch.sh`) |
| `state/.launch-watcher` | the watcher cycle the arm forks (`bin/fm-watch-arm.sh`); one launch per cycle, successor cycles supersede |
| `state/.launch-procevent-<source>-<checksum>` | one registered process-event runner (`bin/fm-procevent.sh`); removed when the source is retired |

Records are private JSON, mode 0600, replaced atomically, and refused when the path is a symlink or not a regular file.
Their sibling `.lock` files retain a stable inode across retirement so concurrent writers continue to share one kernel lock.
Cleanup uses `retire --launch <id> --remove` to record retirement and remove only that exact launch under the same lock; a successor with another launch id is preserved.
Each holds the current launch plus a bounded history of its transitions and a bounded list of previous launches with their outcomes, so the last few terminal results of a subject survive its next launch.

## One launch, in order

1. **intended** - the record exists before any Herdr `workspace create` or `tab create` request leaves, and before a helper's process is forked.
   It names the owner script, the origin (`fresh`, `relaunch`, `ensure`, `adopt`, `afk-start`), and the launcher's pid plus start identity (stored as a digest), so a later launcher can tell a concurrent launch from an interrupted one.
2. **created** - the exact native identity the runtime returned: session, workspace, tab, pane, and terminal ids for a Herdr endpoint; pid plus start-identity digest for a process helper.
   A display label, a CLI pid, or a process-name match is never identity.
3. **ready** or **unconfirmed** - a verdict from a named source.
   A worker is ready when Herdr's native agent registration reports a recognized agent (`working`, `idle`, `blocked`, or `done`) on the exact recorded pane; the document reader when its loopback token probe answers; the supervisor when Herdr's pane process proof tracks its loop; the away-mode daemon when its identity-bound lock is live.
   A delivered launch command is never readiness, and an unconfirmed verdict keeps the launch `created`.
4. A terminal outcome - `failed` (nothing external remains, either because nothing was created or the cleanup was confirmed), `stopped` (a deliberate stop through the owning control path), `exited` (observed gone), `retired` (the owning cleanup removed it), or `reconciled` (settled from native evidence by a later launcher).
5. **uncertain** - the one non-terminal outcome.
   A create request was issued and its result is unknown, or a created endpoint was deliberately retained with no confirmed agent.
   It carries a reconciliation obligation and a hint naming what may exist.

## What the obligation does

A new launch of the same subject is refused while a record is open.
The launch owners settle an open record only from native evidence, never from the record's own words and never from a label:

- A launcher that is still alive with its recorded start identity is a concurrent launch and refuses.
- A recorded Herdr pane is classified natively, presence first: a gone pane is recorded absent (the one native fact that settles an open record by itself); a live agent refuses the duplicate and points at `bin/fm-control.sh`.
  A present pane with no registered agent is never settled automatically: `agent_not_found` also describes a harness that has not registered yet, and the adapter's strict idle-shell proof (idle foreground, no attached child, sleeping shell) cannot exclude a process that already detached from the pane - the 0.8.2 lab shows the proof passing with such a process alive.
  The launch reports that classification as a diagnostic and retains the obligation until the owning control path records the stop or exit it proved (`bin/fm-control.sh exit` or `relaunch`, teardown), the endpoint is natively gone, or an operator settles the record after inspection.
- No recorded identity is settled automatically in one case only: the launcher's own pre-create journal (`state/.<id>.create-issued`, kept by the spawn from the moment before its first request) shows that no request of the launch can have had an effect - nothing was issued, or only the shared per-home container was created and answered with exact ids for its placement owner.
  The journal is bound to its exact launch; the record owner serializes request issuance with this no-effect settlement.
  Every other identity-less open record refuses the next launch until an operator settles it explicitly with `bin/fm-launch-record.py --home <home> reconcile --task <id> --current --verdict manual --evidence "<what was verified natively>"` after inspecting Herdr and stopping or closing a leftover endpoint through its ordinary owner.
  The refusal reports what the exact-label inventory shows as a hint: a tab carrying the task's label, with its native agent state, is never adopted as the task's endpoint, and the absence of such a tab never proves the create had no effect.
- A create request that left and did not answer with exact ids is an obligation whatever the answer was: a structured Herdr error is not source-proven to exclude an allocation, and the adapter's immediate inventory of the creation scope is journaled as a hint (`refused ... inventory=empty:<scope>`, or `hint ... <ids>` when it found a matching label), never as proof.
  Only exact-identity cleanup of a launch's known effects, confirmed by the launcher itself, closes such an attempt as failed and cleaned.
  Retry and teardown inspect every response-derived effect retained in the attempt-bound journal, including a projected seed or reclaim replacement that task metadata does not name.
  Their settlement checks the same effect snapshot under the record lock; a new journal entry invalidates earlier inspection.
  Incomplete native responses retain each unambiguous returned identity axis and require inspected settlement; missing axes are never inferred from labels.
- A helper whose recorded process is alive with its recorded identity refuses a second start; a gone or recycled pid is recorded as an observed exit.
  An unavailable process identity remains unresolved, and a runner publishes created only with its verified claim identity and digest.

Session start prints one `LAUNCH_RECONCILE:` line per open obligation; the `bootstrap-diagnostics` playbook owns the response.
`bin/fm-launch-record.py --home <home> list --reconcile` prints the same list on demand, and `show --task <id>` or `show --helper <name>` prints one record with its history.

## What is integrated

Every selected entry point below either uses the contract or is listed as unsupported with its reason; nothing else claims coverage.

| Entry point | Integration |
| --- | --- |
| `bin/fm-spawn.sh` fresh worker (flat, projected, and projection reclaim) | intent before the first Herdr create; native ids; readiness poll; abort classification |
| `bin/fm-spawn.sh --relaunch` (via `bin/fm-control.sh relaunch`) | a new launch with `origin=relaunch` adopting the recorded endpoint; the previous launch reads stopped |
| `bin/fm-control.sh exit` | stopped only after a delivered stop is proved for the captured launch |
| `bin/fm-teardown.sh` | retired, then the record leaves with the task's other runtime state |
| `bin/fm-docs-reader.sh` ensure and stop | intent before the fork; `fm-docs-reader-serve.py` records its own stable Python process identity before starting MkDocs; readiness from the token probe; interrupted startup can be adopted or stopped from its exact launch identity |
| `bin/fm-herdr-supervisor.sh` establish and retire | a projection of the supervisor's own records, which already satisfy the whole contract and stay the authority (see "Owners that satisfy the contract themselves") |
| `bin/fm-herdr-supervisor.sh monitor` | intent before the detach; stable child pid plus identity before readiness; observed exit on stand-down |
| `bin/fm-afk-launch.sh` start and stop | intent before `workspace create`; the terminal's exact ids; readiness from the daemon lock; stop |
| `bin/fm-watch-arm.sh` cycle | intent before the fork; the child's pid plus start identity; readiness when the beacon confirms it; the cycle's exit code or an uncertain outcome for an unverifiable child; a matching predecessor invoking its successor is superseded, and its later exit is annotated |
| `bin/fm-procevent.sh` runner (start, detach) | intent before the fork; pid plus start identity once the runner holds the claim; readiness when the long wait actually begins, never a result; exit code; a fork the claim refuses reads failed with no effect |

Unsupported, each with its reason: the deferred network stage (`bin/fm-startup-network.sh`, a bounded one-shot with its own pre-fork status record and recorded outcome; its pid-plus-age identity is a disclosed weakness, not fixed here), the remote secondmate spawn and the remote job worker (another host holds the identity), promotion (no process is created), and the Herdr server itself (Herdr-owned).
Retained non-Herdr adapters record nothing on their fresh path; the relaunch path records for every backend.

## The supervisor's record is a projection

The Herdr supervisor loop is accountable through its own records: it writes its create intent (`state/.herdr-supervisor-pending-cleanup`) before `workspace create`, binds the exact workspace, tab, pane, terminal and socket identity after, proves readiness through Herdr's own process-info tracked pid, keeps an unprovable create as pending intent, escalates every failed establish, and closes the exact recorded workspace on retire under a continuity claim and a generation.
Its `.launch-herdr-supervisor` record is a projection of those records into the `list --reconcile` view, not what makes it accountable; a projection write failure is ledgered and is never a second refusal.
Incomplete pending receipts and unresolved prior bindings block establish and retire; explicit manual settlement must match the pending generation.
The detached monitor has no independent create receipt, so its central intent is required before detaching and a live or unidentified predecessor refuses replacement.
Falsifier: a `workspace create` in `establish` without the pending intent on disk (`tests/fm-launch-helpers.test.sh` reads the fake's call log for exactly that).

## Local forks are launches too

The watcher cycle and the process-event runners fork local processes whose child must claim its singleton lock or per-source claim before it does anything.
That claim prevents duplicate polling, but it does not account for an attempt interrupted before the child claimed, so both owners write the launch record before the fork.
Process-event start holds the source lock through intent and fork; the child rechecks its registration and launch before claiming, and an unidentified attempt remains open for inspection.
Their existing authorities are unchanged: the singleton lock and cycle ledger for the watcher, the per-source claim and result files for a runner.
Two owner-specific rules apply:

- The watcher is a successor chain: a successor cycle is forked while its predecessor still runs and hands the lock over.
  The next arm supersedes a live launch only when the invoking predecessor matches its recorded pid and start identity; the predecessor's real exit is annotated on its superseded launch later.
  Arm preparation holds its launch lock through fork and singleton-bound identity publication; an unidentified attempt remains open for inspection.
  The intent is required before a new child: when it cannot be persisted, or a running predecessor cannot be superseded, the arm forks nothing, publishes the refusal through its ordinary failure path (a `check: watcher-arm` wake or the emergency record), and exits non-zero; a healthy predecessor is attached to before that point and is never touched by the refusal.
- A runner's result is completion evidence, not evidence that its long wait started.
  Readiness is recorded when the claimed runner is about to execute the adapter command; a fork the claim refuses closes its launch as failed with no effect, and a child that died before publishing identity leaves the intended attempt open for inspection.
  A start whose intent cannot be persisted forks nothing and fails; a start that finds the recorded runner alive under its recorded start identity forks nothing and reports it as already owned.

## Limits stated plainly

- Creation is not idempotent at the Herdr API: a create request carries no client id, so a lost response can leave a created container.
  The record does not promise exactly-once creation; it promises that the loss is recorded and that nothing is created again for that subject until an operator settles it from native inspection.
- Readiness is Herdr's agent detection.
  A harness Herdr does not recognize, or a raw command, reads unconfirmed even when it is running; that is a recorded verdict, not a failure, and recovery reconciles it.
  The same limit cuts the other way: a pane with no registered agent may be a launch still starting, which is why a present agent-free pane remains unresolved even when its foreground is an idle shell.
- Worker exits are observed at the owning control points (exit, relaunch, teardown, the next launch), not streamed from Herdr's event feed, which the record does not claim to capture losslessly.
- The supervisor mirror is best-effort by design: when its own pending intent cannot be persisted the supervisor already refuses to create, so a mirror write failure is ledgered rather than treated as a second refusal.
  A refused create that the supervisor keeps as pending intent reads uncertain in the mirror, exactly as the owner reads it.
- Killing a launcher with SIGKILL does not stop its already-running adapter subprocess; a create it had issued may still complete.
  Journal issuance and automatic no-effect settlement share the record owner's lock and exact launch identity, so a surviving descendant cannot issue a request after its attempt is settled.
  A request already issued remains an obligation; label inventory only supplies inspection hints.
- A structured Herdr error is not proof that nothing was allocated, and an inventory that finds nothing under the label is not proof either (the fleet's own test harness creates the effect under another label to show it).
  Such an attempt stays uncertain with its inventory as a hint; an error carrying exact native response IDs keeps that container as the launch's known partial identity; a partial container (a task workspace without its tab, a tab created while Herdr answered an error) is never replaced automatically.
  The journal line for a request is written before the request leaves and refuses the request when it cannot be written.
- No idle-shell observation settles an open attempt on a present pane.
  The strict proof refuses a delayed start held by a foreground command and an attached background child, but passes a process that already detached from the pane's shell (all three observed on the 0.8.2 lab), so it can only ever be a diagnostic; the obligation is settled by attempt-bound evidence - the owning control path's recorded stop or exit, the endpoint natively gone - or by explicit disposition through the existing owners.
  Typed but unsubmitted input is discarded when a pane is closed through its owner, so it can never run there.
- `python3` is required for every launch: a home without it refuses to launch before any creation call rather than launching unrecorded, and session start reports the missing interpreter.

## Privacy

Records hold identifiers and short reasons only: allowlisted identity keys, allowlisted fields, bounded newline-free values, credential-shaped values refused, launcher identity strings stored only as a digest, and never a command line, environment, prompt, or brief text.
The fleet's own test harness verifies the refusal and its positive control.

## Verification

- `tests/fm-launch-record.test.sh` - the contract through its executable interface: phases, duplicate refusal, concurrent intents, obligations, launcher identity, privacy, unsafe paths.
- `tests/fm-launch-spawn.test.sh` - the worker owners end to end against a stateful fake Herdr: intent before creation, native identity, readiness controls, refused and lost creates, explicit settlement, interruption on both sides of creation, the present-pane settlement boundary, duplicates, record-write failures, exit, relaunch, teardown, and a missing interpreter.
- `tests/fm-launch-helpers.test.sh` - the supervisor and away-mode launcher against the same fake; the real watcher arm and the real process-event runner in isolated homes, with a record wrapper that proves intent precedes the fork.
- `tests/fm-docs-reader.test.sh` - the reader's intent-before-process observation, identity binding, stop, observed exit, legacy-record adoption, and the recycled-pid guard.
- `tests/fm-launch-record-herdr-live-e2e.test.sh` - the opt-in named-lab check of the native facts the records rely on, recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md#launch-record-native-boundary).
