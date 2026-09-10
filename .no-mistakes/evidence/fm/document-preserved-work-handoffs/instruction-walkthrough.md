# Manual instruction application evidence

Subject: Firstmate maintained worker-reporting and preserved-work instructions.
Base: `fe601e80363dca6469775ca98ad0643071fb48f3`.
Examined HEAD: `002a30000b4699ee64bf39a3e35d8f10db87255f`.
Working directory: `/Users/criz/.no-mistakes/worktrees/da589fef49ee/01M24WMT2XEQWVS3AS18S28GYW`.

This is a manual application exercise by the test-phase agent, not an automated behavioral regression or a live worker lifecycle experiment. The two supported checks validate documentation structure and instruction routing; they cannot establish how every future model will follow prose.

## Exercise 1: substantive worker answer using this phase's actual results

**Conclusion:** The two requested documentation checks completed successfully at the examined HEAD. Manual reading supports the intended distinction between sparse notifications and independently assessable reports, and between recovery of an authorized attempt and a reviewed fresh handoff.

**Observed evidence:** `bin/fm-doc-audience-check.sh` returned exit 0 with `fm-doc-audience-check: ok surfaces=117 local_links=334`. `bin/fm-instruction-sources-check.sh` returned exit 0 with `fm-instruction-sources-check: ok canonical=.agents/skills claude=pointer grok=attachment-adapter`. Both tool calls returned completed process results, not running session identifiers. `git rev-parse HEAD` returned the examined commit above. `git status --porcelain=v1` was empty before evidence creation.

**Reasoning:** The first command exercises the maintained audience inventory and local documentation links. The second exercises the canonical instruction source and harness bridges. Reading the complete communication and recovery skills establishes the reviewed policy: substantive answers include material evidence and reasoning; firstmate must read those answers before summarizing; retained work must be reconciled before a fresh worker starts. AGENTS.md adds trigger pointers rather than copying the new substance.

**Limitations and counterevidence:** These commands do not prove model compliance, worker readiness, runtime retirement, deployment, or merge. No live runtime commands, broad behavior suite, lint, formatter, CI job, push, or merge ran in this phase. No failed or timed-out targeted check occurred. Hosted behavior and Lint jobs are excluded, not passing; the supplied intent identifies the latter as runner cancellation, not a ShellCheck finding. No remote CI status was independently queried.

**Open decisions and next action:** No new captain-owned question arose from this bounded test exercise. Return the test result and this evidence to the outer executor; it alone owns later phases.

A suitable sparse notification for that detailed answer is: “Targeted documentation checks completed; the full evidence and limitations are in instruction-walkthrough.md.” That notification would not suffice as the substantive answer.

## Exercise 2: challenge misleading evidence claims

The following inputs are hypothetical adversarial examples, not observed failures in this repository. I applied the loaded communication instructions to each and produced these conclusions:

| Input offered by a worker | Assessment and next action |
| --- | --- |
| Tool call yields a running session, but an annotation says success | Command completion remains unverified. Obtain the underlying command's terminal outcome before claiming its check passed. |
| A worker process exists, but no readiness evidence exists | Presence alone does not establish readiness. Obtain the supported readiness evidence before declaring it usable. |
| A check times out and the worker blames Herdr | Report the timeout as observed and Herdr causation as unproven. Record a discriminating check instead of asserting the root cause. |
| A file contains a fix, therefore the worker says it is deployed | Establish commit identity, publication/landing state, and deployment evidence separately. File contents establish none of those later states. |
| One check passes, one fails, one is skipped, one times out, one is unperformed | Report all five outcomes explicitly; do not compress them into a success summary. Include the failure evidence, uncertainty, and next action. |

Result: the manual interpretations preserve the intended evidence boundaries and allow enough internal detail without imposing a sentence cap or requiring whole transcripts.

## Exercise 3: fresh handoff with contradictory retained context

Hypothetical input: an explicitly stopped attempt retains a dirty worktree, commits, an old report claiming completion, a timed-out validation, stale runtime metadata, an open engineering question, and a separate unanswered captain decision. The captain authorizes a fresh worker to continue the preserved work but does not authorize discarding it or merging.

Manual application, in order:

1. Inventory the exact retained worktree and artifact paths, branch/head identities, dirty changes, useful session context, and the source of the stop and fresh-work authorization. Do not infer current truth from the old metadata.
2. Reconcile the old completion claim against the actual head and validation result. Record the timeout and incomplete validation; if causation remains unknown, include the discriminating check rather than promoting the old report to fact.
3. Resolve the engineering question within existing authority. Preserve the separate captain question through the existing captain-hold owner; the fresh authorization is not an answer to that question or permission to merge.
4. Write one durable handoff in the retained work item's data directory: goal, constraints, authority, exact artifacts and source identities, results and limitations, settled decisions and their sources, unresolved questions, next executable action, and what may be reused or changed.
5. Give the authorized fresh worker a separate isolated task identity. Keep old work and navigation intact. Require artifact/start-state verification, acknowledgement, and observable work through confirmed-handoff before claiming transfer succeeded.
6. Do not revive the stopped attempt or copy its runtime identities. If removing it from monitoring would require bypassing the unlanded-work guard, report the documented tooling gap and leave work discoverable.

Result: this walkthrough reaches a reviewed handoff contract without inventing a completed transfer. No worker was actually started, acknowledged, retired, or removed during this exercise. No hypothetical paths or decisions were written into runtime records.

## Scope and preservation observations

Read-only base-to-target history and diff inspection identified the original three-file instruction commit, the retirement/authority clarification, the first CI exclusion, its documentation alignment, and the final hosted Lint exclusion. The CI diff removes only Lint, the two portable-parallel jobs, the four-way portable-serial matrix, and their timing aggregate. The Test coverage guard and Repo invariants job definitions remain unchanged. The final commit changes only the Lint job and its disclosure; it retains the earlier exclusion and documentation commit. No bin script, test, extension, launcher, or config change was observed in the delta. This phase changed no source or test files.

No visual evidence was captured because the changed product surface is agent-loaded Markdown instructions and workflow policy, not a rendered UI. The evidence here is the actual substantive report plus explicitly labeled manual scenario applications.
