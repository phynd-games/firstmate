# Maintained instruction contract: manual walkthrough

Reviewed target: `e89867b83003a847d05be829dacdbb25420016da`.
Compared base: `fe601e80363dca6469775ca98ad0643071fb48f3`.

This is evidence of the actual maintained agent-facing Markdown and a manual reading of its complete reporting-to-handoff path. It is not a live-worker transcript or proof that a model will always obey the instructions. No lifecycle experiment, source-string test, new framework, linter, or broad regression suite was run. No browser UI changed; the maintained Markdown is the relevant delivered surface.

## Supported executable checks

Both commands ran from the target worktree and completed with exit code 0:

- `bin/fm-doc-audience-check.sh`: `fm-doc-audience-check: ok surfaces=117 local_links=335`
- `bin/fm-instruction-sources-check.sh`: `fm-instruction-sources-check: ok canonical=.agents/skills claude=pointer grok=attachment-adapter`

These establish documentation inventory/link integrity and canonical harness instruction bridges, respectively. They do not establish model interpretation.

## Manual walkthrough of the delivered contract

1. **Enter through AGENTS.md.** Section 9 loads communication-discipline before output, instructions, updates, or results. The added dispatch pointer loads stuck-crewmate-recovery before a fresh retained-work handoff; the skill catalog carries the matching trigger. The new policy substance remains in the two skills, rather than being copied into AGENTS.md.
2. **Report an investigation with incomplete checks.** The communication owner distinguishes a sparse notification from a substantive answer, requires a conclusion, material observations, causal reasoning, counterevidence/uncertainty, references that determine truth, open questions, and next action. Failed, skipped, timed-out, and unperformed checks must be explicit. The complete durable report is read before firstmate decides or writes a brief captain summary. Evidence detail has no captain-facing sentence cap and need not become a transcript dump.
3. **Challenge misleading success signals.** The same instruction explicitly separates a tool return from command completion, process presence from readiness, observed failure from inferred cause, file changes from commits, and publication from landing. Under this contract a timeout alone cannot establish root cause, and a file alone cannot establish committed or deployed state. This is a manual interpretation of the instruction, not an executed failure-injection test.
4. **Receive preserved work from a stopped attempt.** The recovery owner requires firstmate to inventory exact retained paths, branches, commits, dirty work, artifacts/session context, last verified results and incomplete checks, prior decisions and authority, unresolved engineering/captain questions, reuse limits, and next executable action in a durable handoff. Contradictory claims must be resolved or retained as uncertainty with a discriminating check. An explicit stop is authoritative despite old runtime events or an open PR.
5. **Transfer to an authorized fresh worker.** The reviewed handoff carries artifact pointers and authority into a new isolated task identity. Old process identities and blindly replayed instructions are forbidden. The receiving worker verifies artifacts/starting state and acknowledges the handoff; confirmed-handoff remains the owner of observable-start confirmation. Old work/navigation survives until authorized landing and cleanup. The separate same-attempt relaunch route now explicitly requires continuing authorization.
6. **Encounter unsupported retirement.** The recovery owner states there is no supported ordinary-task command to remove monitoring while preserving an unlanded worktree. It requires recording that gap and retaining discoverability, forbids metadata stripping or fabricated completion, and does not claim a new runtime capability exists.

No unresolved acceptance question or content defect was found in this walkthrough.

## Authorized scope and provenance inspection

`git diff` across the exact base/target was manually reviewed. No test file changed. The workflow removes only the authorized hosted Lint job, two parallel behavior jobs, four-way serial matrix, and dependent aggregate, with their enabling setup. Test coverage guard and Repo invariants retain their executable definitions. Excluded jobs are not counted as passing; the Lint comment describes cancellation before decisive ShellCheck output, not a code-content failure.

`git diff --exit-code 002a300 e89867b83003a847d05be829dacdbb25420016da -- .github/workflows/ci.yml` completed with exit code 0: the committed exclusions remain unchanged after the second exclusion commit.

`git diff --exit-code fe601e80363dca6469775ca98ad0643071fb48f3 e89867b83003a847d05be829dacdbb25420016da -- tests` completed with exit code 0.

The full diff for `bin/fm-lint.sh` and `.no-mistakes.yaml` was read: only header/comments changed, and `commands.lint` remains `bin/fm-lint.sh`. Their corrected comments refer hosted execution policy to `.github/workflows/ci.yml`. The two prior documentation-alignment commits remain in the target ancestry. No source changes or transient worktree files were created by this test phase.

## Actual delivered Markdown excerpts

The following are verbatim excerpts from the inspected target, included so a reviewer can assess the delivered instruction surface directly.

### .agents/skills/communication-discipline/SKILL.md

```markdown
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
```

### .agents/skills/stuck-crewmate-recovery/SKILL.md

```markdown
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
```
