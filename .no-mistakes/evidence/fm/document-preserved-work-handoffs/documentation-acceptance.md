# Documentation acceptance walkthrough

Reviewed target: `101f433b798db98e72303f98ebaf1139397fe5e9`

Direct parent and requested base: `fe601e80363dca6469775ca98ad0643071fb48f3`

## Result and evidence boundary

The maintained instruction contract satisfies the requested reporting and preserved-work handoff requirements on manual review. Both authorized documentation checks completed successfully. This is documentation validation, not an experiment showing that a future worker will obey natural-language instructions. No worker was spawned, stopped, retired, or handed live work; no pipeline or delivery action was performed.

## Actual reader path reviewed

Read the complete communication-discipline and stuck-crewmate-recovery skills, the changed AGENTS.md dispatch context, and the referenced confirmed-handoff and captain-hold-lifecycle owners. Reviewed the full base-to-target diff and target parentage.

The AGENTS.md dispatch trigger sends firstmate to the recovery skill before a fresh worker receives retained work. Its skill index also exposes that trigger. Communication discipline separately points retained-work transfers to that same recovery owner. The new substantive requirements reside in the two skills; AGENTS.md adds trigger pointers only.

## Manual scenario walkthroughs

These are interpretations of the maintained instructions, not executed runtime tests or fabricated task records.

### A failed check arrives with a compact status notice

A status pointer is insufficient for a decision. The communication skill requires firstmate to read the complete report. The report must state its conclusion and material observations, exact commands/results and source/artifact identities where truth depends on them, reasoning, counterevidence or uncertainty, verification limitations, unresolved questions, and next action. Failed, skipped, timed-out and unperformed checks remain explicit. Detail scales to the question, while captain chat stays concise.

For ambiguous evidence, the reader is directed to distinguish the tool returning from the underlying command completing, a present process from a ready service, and observed failure from inferred cause. Thus a timeout cannot establish root cause by itself. File changes, commits, publication and landing are distinct; the recovery handoff further distinguishes implemented, committed, published, landed and verified behavior. File contents alone cannot establish delivery state.

### A stopped attempt leaves changes, commits and conflicting claims

The explicit stop remains authoritative despite retained files, an open PR, stale working events or a missing worker. Before a separately authorized fresh worker starts, firstmate inventories exact work/artifact locations, branch and commit identities, uncommitted changes, useful session context, actual verified results and incomplete checks. Prior decisions retain authoritative sources; engineering questions and captain-owned questions are separated. The handoff includes goal, acceptance, constraints, implementation/delivery/merge authority and next executable action.

Conflicting claims cannot both be copied as settled facts. Firstmate resolves them or records uncertainty and the discriminating check. The fresh worker receives its own isolated task identity and a durable reviewed handoff, verifies the artifacts and starting state, and must acknowledge and observably start through the confirmed-handoff owner. Prior work and durable navigation remain preserved; old process identities and stale instructions are not automatically inherited.

### Retirement is unavailable or unsafe

The new section distinguishes removing obsolete tracking from deleting retained work. It forbids stripping live metadata, forcing teardown of unlanded work or erasing unresolved captain decisions. If a supported preservation-safe retirement path is unavailable, the instruction is to record the tooling gap and leave work discoverable, not assert that retirement succeeded. Captain-owned questions route to the existing captain-hold-lifecycle owner. The documentation does not implement or promise a new retirement command.

The older same-task recovery paragraphs concern ordinary dead-worker recovery. The new explicit-stop and authorized-fresh-handoff section provides the constraint for the stopped-attempt scenario; it does not treat endpoint absence as authorization to revive stopped work.

## Executed checks

- `bin/fm-doc-audience-check.sh` — completed, exit 0; documentation audience inventory and local links accepted.
- `bin/fm-instruction-sources-check.sh` — completed, exit 0; canonical instruction source and harness bridges accepted.
- `git rev-parse HEAD` and `git log --format='%H %P %s' fe601e80363dca6469775ca98ad0643071fb48f3..101f433b798db98e72303f98ebaf1139397fe5e9` — target is checked out and is one commit directly on the requested base.
- `git diff --name-status fe601e80363dca6469775ca98ad0643071fb48f3 101f433b798db98e72303f98ebaf1139397fe5e9` and full `git diff` for those endpoints — only AGENTS.md and the two requested skill Markdown files changed; no unrelated integration history, scripts, tests, settings, CI or runtime records were imported.

No baseline test execution was supplied or performed; initial baseline inspection was repository status, target scope and full diff. No new source-string tests, lint, formatters, broad suite, native lifecycle experiment or other pipeline phases were run. This agent-facing Markdown change has no UI or copy-placement change, so no browser screenshot was needed. The original local draft is not present in this worktree; provenance review establishes the supplied base, target and three-file delta, rather than byte equality to an unavailable draft.

No source or test fixes were needed. This report is the sole created evidence file and is outside the worktree in the explicitly authorized evidence directory.
