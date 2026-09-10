# Maintained instruction walkthrough

## Result and exact scope

The two permitted documentation checks completed successfully at head `6a73a28a35822c0bffe0ee77b882a3bf2ad1de1f`, against base `fe601e80363dca6469775ca98ad0643071fb48f3`.
Manual reading of the complete changed skills and the base-to-head diff found the requested reporting and retained-work instructions in their designated owners.
The product surface here is agent-loaded Markdown, not a rendered application.
The appendices reproduce the actual instructions read through the supported harness skill bridges, not a proposed replacement or a simulated worker transcript.

## Manual instruction-consumption walkthrough

1. Followed AGENTS.md's communication-discipline trigger to its canonical skill. A routine milestone can remain a compact notification; a substantive failed-check report must include its conclusion, material observations and references, reasoning, counterevidence or uncertainty, verification limitations, open questions, and next action. The receiving firstmate must read the complete report before deciding. This report applies that distinction to the current test phase.
2. Read the reporting evidence distinctions together: a tool returning is not underlying-command completion; process presence is not readiness; an observed failure is not its inferred cause; a file change is not a commit, and publication is not landing. A timed-out check must be stated explicitly. These instructions address the requested misleading-evidence cases without imposing a transcript dump or sentence cap.
3. Followed the retained-work trigger into the recovery skill and walked the stopped-attempt case on paper. Before a fresh worker starts, firstmate must inventory exact retained locations, uncommitted changes and commits, artifacts and session context, actual results and incomplete checks, prior explicit decisions and authority, engineering versus captain-owned questions, and the next executable action. Conflicting claims require reconciliation or a stated uncertainty and discriminating check.
4. Read the fresh-worker boundary with the existing relaunch procedure. An explicit stop does not authorize revival. An authorized fresh worker receives a distinct isolated task identity and reviewed durable handoff, verifies starting artifacts, and acknowledges the handoff with observable work before transfer is reported. Prior work and its navigation remain preserved. Relaunch of the recorded identity separately requires continuing authorization.
5. Read the retirement limitation as a limitation: the instructions explicitly say no ordinary-task command currently removes monitoring while preserving an unlanded worktree. They require preserving discoverability and recording the tooling gap, rather than claiming retirement occurred.
6. Reviewed the full diff and retained commit history. AGENTS.md adds trigger pointers; the two changed skills own the new substance. No test file changes are present. The three authorized CI exclusions and the lint/config comment corrections remain committed and untouched. The existing Test coverage guard and Repo invariants job definitions remain in the workflow. Earlier documentation-alignment commits remain in this head.

## Executed checks

- `bin/fm-doc-audience-check.sh` completed with exit 0 and `fm-doc-audience-check: ok surfaces=117 local_links=335`.
- `bin/fm-instruction-sources-check.sh` completed with exit 0 and `fm-instruction-sources-check: ok canonical=.agents/skills claude=pointer grok=attachment-adapter`.
- `git diff fe601e80363dca6469775ca98ad0643071fb48f3 6a73a28a35822c0bffe0ee77b882a3bf2ad1de1f` and the bounded commit log were read to assess accepted scope and preservation.
- `git rev-parse HEAD` confirmed the tested target. Initial and final `git status --short --untracked-files=all` were empty.

## Limits and next action

These checks establish documentation structure, link reachability, audience classification, and canonical harness bridges. The manual walkthrough assesses the written contract; it does not prove future model compliance or executable recovery behavior.
No live worker was stopped, relaunched, retired, or transferred. A native Herdr lifecycle experiment and new source-string tests are explicitly excluded by the acceptance criteria.
No baseline test execution was supplied or performed; the baseline comparison was a read-only Git diff. No tests failed, were skipped internally, or timed out in this phase.
No lint, formatter, broader regression suite, hosted CI, attestation investigation, push, PR, or merge operation was run. The excluded hosted behavior shards/timing aggregate, hosted Lint, and automatic attestation check are not claimed as passing. Hosted coverage guard and Repo invariants execution remain with the outer executor.
No screenshot was captured because the changed instructions are consumed as Markdown by agents and there is no changed UI surface.
No source or test files were modified and no worktree artifacts required cleanup. The next action is for the outer executor to continue its remaining authorized phases.

## Actual reporting instructions through the Claude skill bridge

Read path: `.claude/skills/communication-discipline/SKILL.md`

```markdown
---
name: communication-discipline
description: >-
  Concise communication policy for the captain session and workers. Load before
  composing a user-facing response, worker instructions, progress update, or review result.
user-invocable: false
metadata:
  internal: true
---

# Communication discipline

Optimize for signal, not ceremony.
Keep internal reasoning and tool work as thorough as needed, but keep visible prose to the minimum that preserves correctness, decisions, evidence, and next actions.

Answer the question or state the result first.
Do not add greetings, praise, preambles, repeated context, or a conclusion that merely restates the answer.
Do not recap work the reader just watched.
Do not provide status inventories, implementation tours, file-by-file summaries, or unsolicited menus unless requested or required for a decision.
Use bullets or a short paragraph when that is clearer than prose.

Ask only questions that block correct progress.
Combine related questions into one message and include the recommended default when a choice is needed.
Do not ask a question whose answer can be established from the repository, an executable check, or an authoritative tool.
Prefer one bounded request for missing information over repeated back-and-forth.

Worker instructions should contain the objective, acceptance criteria, constraints, relevant context, and return format once.
Workers should work independently, avoid narrating routine steps, and send sparse status notifications for milestones, blockers, decision requests, or final results.
A short status notification is not a substitute for a substantive answer.
Captain-facing brevity does not impose a sentence limit on worker-to-firstmate findings, concrete answers, failed-check explanations, decision requests, or handoffs.

## Substantive worker answers

Give firstmate enough detail to assess the conclusion without reconstructing missing reasoning or guessing what happened.
Use a concise conclusion followed by the material observations, artifact and source references, reasoning, counterevidence or uncertainty, verification results and limitations, unresolved questions, and recommended next action.
Include exact commands, exit results, source or commit identities, and artifact locations when they determine whether the claim is true.
Distinguish file changes from commits, publication from landing, a tool's return from the underlying command's completion, process presence from readiness, and observed failure from an inferred cause.
State failed, skipped, timed-out, and unperformed checks explicitly; do not bury them under a success summary.
Scale detail to the question rather than requiring transcript dumps or repeated narration.
Put substantial evidence in a durable report and use a compact status pointer to notify firstmate.
Firstmate reads the relevant complete answer or report before deciding, steering, or composing the shorter captain-facing summary; the pointer or status line alone is not the answer.
For transferring retained work to a fresh worker, follow the reconciliation and handoff procedure in `../stuck-crewmate-recovery/SKILL.md` rather than treating an old conversation or runtime record as a verified handoff.

When the pointer is a Markdown document under this home's `data/`, run `bin/fm-docs-reader.sh url <path>[#anchor]` and give the captain the URL it prints, which is the local document reader's verified address for that exact page.
When the command fails, give the file path instead and say in one clause that the reader is unavailable; never compose a `localhost` or `127.0.0.1` address yourself, and never send a reader URL to Relay or any other remote reader, because the address exists only on the captain's machine.

Self-review visible output before sending:

- Is the result or requested decision in the first sentence?
- Can any sentence be removed without losing correctness or actionability?
- Did I repeat something already visible or established?
- Did I distinguish observed evidence from inference?
- Did I include only the next action or decision that matters?

Short output must never omit a failure, uncertainty, safety constraint, validation result, or captain decision.
Conciseness controls presentation and coordination overhead; it never lowers verification depth or engineering quality.

```

## Actual recovery instructions through the Grok skill bridge

Read path: `.grok/skills/stuck-crewmate-recovery/SKILL.md`

```markdown
---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, a failed steer, or a validation-loop limit stop.
  Also use before handing retained work from a stopped or failed attempt to an authorized fresh worker.
  Reconciles recorded work before a reviewed fresh handoff or escalation through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, stopped by a validation-loop limit, or when a steer failed to land.
Also use it before transferring retained work from a stopped or failed attempt to an authorized fresh worker.

Interrupt, stop, and relaunch a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane covers workers running in this home; a remotely placed secondmate is refused by name and reconciled through `secondmate-provisioning` instead.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

For a REMOTE secondmate, `fm-crew-state` and `fm-peek` read the actual remote endpoint over `fm-on.sh`, and `fm-send` reports a delivered-with-pending-confirmation steer as delivered (their headers own the contracts); an `unknown-remote` read or unreachable-host failure means the remote state could not be read, never that the mate is dead or the send failed.
Recover a genuinely stuck remote mate only through `bin/fm-spawn.sh <id> --secondmate`, never raw herdr pane close/kill surgery, which strands the endpoint binding.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use the Herdr-owned endpoint and worktree checks through `bin/fm-crew-state.sh` and the exact task metadata.
Herdr is the sole supported runtime; legacy tmux, zellij, cmux, and Orca records are read-only and must not be operated or probed through their retained adapters.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, confirm that the attempt remains authorized to run, prove that no live agent still owns the recorded task, and verify that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Preserved-work reconciliation before a fresh handoff

An explicit stop is authoritative: retained files, an open PR, a stale working event, or a missing agent never authorize reviving that attempt.
Separate retiring an obsolete monitoring identity from deleting the work it once tracked.
Task retirement remains with [`bin/fm-teardown.sh`](../../../bin/fm-teardown.sh) and its [`record-transition owner`](../../../bin/fm-backlog-transition-lib.sh); do not strip live metadata, bypass the unlanded-work guard, fabricate completion, or erase an unresolved captain decision to quiet notifications.
There is currently no supported ordinary-task command to remove monitoring while preserving an unlanded worktree; record that tooling gap and leave the work discoverable rather than claiming retirement is complete.

Before an authorized fresh worker starts, firstmate performs a reconciliation pass over the retained artifacts and the actual current state.
Write one durable handoff under the work item's retained data directory that records:

- The approved goal, acceptance criteria, constraints, and current implementation, delivery, and merge authority.
- Exact retained work and artifact locations, branch and commit identities, uncommitted changes, and useful session context that is not already captured by the artifacts.
- The last verified result, supporting evidence, failed or incomplete checks, and distinctions between implemented, committed, published, landed, and verified behavior.
- Decisions already made, their authoritative source, unresolved engineering questions, genuine captain-owned questions, and the next executable action.
- Which prior attempt is stopped, which work is authoritative, and what the new worker may reuse or change without discarding other retained work.

Resolve contradictions before treating the handoff as authoritative; when the evidence cannot settle a point, record the uncertainty and the discriminating check instead of copying both claims as facts.
Answer engineering questions within existing authority and carry genuine captain calls through `../captain-hold-lifecycle/SKILL.md`; a handoff does not invent an answer or expand scope.
Keep detail sufficient for independent assessment under `../communication-discipline/SKILL.md`, not constrained by captain-facing chat brevity.

Give an authorized fresh worker its own isolated task identity and the reviewed handoff with exact artifact pointers.
Do not copy old process identities, blindly replay old instructions, or assume every retained change belongs in the new deliverable.
Have the new worker verify the relevant artifacts and starting state, acknowledge the handoff, and confirm observable work through the existing confirmed-handoff owner before reporting a successful transfer.
Preserve the old work and its durable navigation until the selected landing and cleanup owners authorize removal.

## Validation-loop limit stop

A wake or crew-state detail naming a validation loop limit means the deterministic bounds in `bin/fm-validation-loop-lib.sh` stopped absorbing a crew that still reads as working: repetitive fix rounds or findings, a stalled active run, or stale pipeline evidence.
The stop changed nothing but the durable journal (`state/<id>.validation-loop`, whose recorded reason is the finding), so the worker, branch, worktree, and run custody are all exactly where they were.
Recover in the same copy only:

1. Read `bin/fm-crew-state.sh <id>` and the journal's recorded reason; do not re-absorb the crew as working on the run-step or pane state alone - the breach is the evidence that proof has gone stale.
2. For a repetitive or stalled run, steer or interrupt the same worker through the ordinary escalation ladder below; if the run itself must end, only the worker uses no-mistakes' own supported abort and custody sequence per `AGENTS.md` section 7, preserving every existing pipeline fix commit.
3. Never spawn a duplicate worker, never discard changes, and never approve or skip a failing check to clear the stop.
4. A replacement run on the same branch and copy resets the journal's counters automatically; when the captain explicitly authorizes continuing the stopped loop as-is, remove `state/<id>.validation-loop` to reset the bounds from fresh evidence.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane, and check the task's steering inbox (`state/<id>.inbox/`) for unhandled `*.msg` records - a stale wake naming an unread firstmate instruction means the worker never acknowledged a durable steer, and the record itself shows exactly what was intended.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.

```

## Retained commit inventory

```text
6a73a28 Exclude the hosted PR-provenance attestation check
e89867b Correct stale hosted-CI lint claims after the Lint job exclusion
defc08b no-mistakes(document): Align lint documentation with hosted CI exclusions
002a300 Exclude the hosted Lint job after a runner-cancellation failure
c90f026 no-mistakes(document): Align documentation with hosted behavior CI exclusions
47fe028 Exclude failing hosted Linux behavior CI jobs for this PR
81efe46 no-mistakes(document): Clarify preserved-work retirement limits and relaunch authority
101f433 Require detail-sufficient worker reports and pre-handoff reconciliation
```
