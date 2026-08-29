---
name: firstmate-pr-self-review
description: >-
  Agent-only findings-first self-review for every ship branch before validation, PR creation, or local landing.
  It reviews exact target base/head evidence and separately reviews Firstmate substrate changes without adding delivery or merge authority.
user-invocable: false
metadata:
  internal: true
---

# Firstmate PR self-review

Load this skill before any ship branch is reported ready for validation, PR creation, or local landing.
The generated ship brief supplies the durable report path, task identity, Firstmate substrate root, and substrate launch SHA.

## Authority boundary

This is implementation self-review, not an independent reviewer, delivery path, approval, or merge authority.
No-mistakes remains sole delivery authority and owns delivery review, fixes, tests, documentation, lint, push, PR, and CI when that path is selected.
A structurally valid file, schema, prompt envelope, digest match, or clean self-review never grants authorization and never proves artifact or instruction provenance.

## Exact diff evidence

Resolve target base independently for this task.
Use the exact captain-approved or task-approved base when instructions name one, and otherwise use the freshly fetched remote default branch for a remote-backed project or the current local default branch for local-only work.
Never replace an explicitly named base with an untouched default branch or an inferred merge base.
Record target repository, base ref, full base SHA, full head SHA, full merge-base SHA, and whether tracked or untracked changes remain.
Use `bin/fm-review-diff.sh` from the Firstmate substrate root when its recorded task route represents the accepted target base.
Its output identifies exact base, head, and merge-base SHAs and presents the complete target diff.
When task instructions name another base, fetch and pin that ref before editing, then review the complete diff from that pinned SHA through current head.
Inspect every changed file, not only latest commit or files mentioned in task instructions.
Repeat complete review after every self-review fix and record final head SHA.

## Separate Firstmate substrate review

Always include a separate `Firstmate substrate diff` section in report because Firstmate substrate drives delivery.
When target repository is Firstmate, use target base and head as substrate base and head, then review complete diff again through substrate and control-plane lens.
When target is another project, use substrate launch SHA from generated brief as substrate base and current exact substrate SHA as substrate head.
If those substrate SHAs are equal or their diff is empty, record exact evidence and `no substrate diff` rather than omitting section.
If they differ, inspect complete substrate diff separately from target-project diff.
Do not treat target-project review as substitute for substrate review, even when both sections use same commits.

## Required review surfaces

Review acceptance intent and every changed file first.
Review authority boundaries, security and trust claims, malformed or adversarial inputs, provenance claims, credential and secret handling, and any path, symlink, quoting, or environment boundary.
Review failure behavior, deterministic output, bounded input, retries, idempotency, rollback, compatibility, and every existing lifecycle, queue, acknowledgement, validation, and merge owner touched by change.
Review schema and runtime agreement, callers and consumers, generated artifacts, tests through public behavior, negative cases, documentation owners, and actual delivery configuration.
For Phynd Cloud target work, also load `phynd-governance` and `phynd-engineering`, plus `phynd-design` for design or architecture work.

## Findings-first durable report

Write report to exact path in generated brief.
Create parent directory if needed, but write no other file outside task worktree.
Use this section order:

The report is a private mode-0600 Markdown artifact whose first two lines are exactly `Self-review report: firstmate-pr-self-review.v1` and `Task id: <task-id>`.
The required headings below must appear exactly once and in the listed order, with non-empty content in every section.
The target-project section must contain a canonical `Target repository:` worktree path, non-empty `Base ref:` and `Tree status: clean` fields, full lowercase-hex `Base SHA:`, `Head SHA:`, and `Merge-base SHA:` fields, and a 64-character lowercase-hex `Changed files:` digest of the exact name-status inventory.
The substrate section must contain full lowercase-hex `Substrate base SHA:` and `Substrate head SHA:` fields plus a 64-character lowercase-hex `Substrate changed files:` digest of the exact name-status inventory.
The surface section must contain non-empty `Authority:`, `Security:`, `Path:`, `Failure:`, `Tests:`, `Documentation:`, and `Delivery:` fields.
The verification section must contain at least one non-empty `Command:` field and one non-empty `Result:` field.

1. `Findings` with severity, `path:line`, evidence, consequence, and required fix for each issue.
2. `Target-project diff evidence` with exact base/head refs, base/head/merge-base SHAs, changed-file inventory, and clean-tree status.
3. `Firstmate substrate diff evidence` with exact base/head SHAs, changed-file inventory, or explicit no-diff evidence.
4. `Surface review` covering every required review surface and naming inspected files and consumers.
5. `Verification` with exact commands and results.
6. `Residual risks` with unresolved uncertainty or `None`.

This report is evidence of the worker's self-review only; it never authorizes delivery, approval, merge, or routing.

Put `None` under `Findings` only after completing both diff reviews and every required surface.
Fix every in-scope unambiguous finding before readiness, retain finding and resolution in report, then repeat review against original accepted base and new head.
Escalate findings that require product choice, destructive action, or broader authority instead of deciding them locally.
Do not start no-mistakes until this self-review and report are complete.
Do not run a second reviewer or hold work for another clean verdict after report; selected delivery path remains authoritative.
