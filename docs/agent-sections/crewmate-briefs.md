# Crewmate briefs


Full detail for [AGENTS.md section 11](../../AGENTS.md#11-crewmate-briefs).
The Rules in that section are the load-bearing subset that stays inline; this document owns the detail and is read on demand.

## Rules

- [Scaffold](#scaffold): `bin/fm-brief.sh` owns the scaffold, and every `{TASK}` placeholder must be replaced before dispatch or seeding.
- [Ship briefs](#ship-briefs): the worktree-isolation assertion stays, and Herdr lifecycle work scaffolds with `--herdr-lab`.
- [Charter briefs and status](#charter-briefs-and-status): load `secondmate-provisioning` before a charter brief, and keep status appends sparse.

## Scaffold

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then replace every `{TASK}` placeholder with a clear task description, acceptance criteria, constraints, and necessary context before dispatch or seeding.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.

## Ship briefs

Every ship brief must retain the worktree-isolation assertion and stop if launched in the primary checkout.
If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.

## Charter briefs and status

Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.
The scaffold is a safety contract, not a suggestion.
