# Backlog contract


Full detail for [AGENTS.md section 10](../../AGENTS.md#10-backlog-contract).
The Rules in that section are the load-bearing subset that stays inline; this document owns the detail and is read on demand.

## Rules

- [Queue and decisions](#queue-and-decisions): the backlog tracks work items only, and a decision is a task held for the captain.
- [Schema and handoff](#schema-and-handoff): `.tasks.toml`, `docs/configuration.md`, and `tasks-axi --help` own the schema, and cross-home handoff has its own owners.
- [Notes hygiene](#notes-hygiene): keep notes free of rot, and treat implemented, pushed, merged, and verified-after-restart as separate milestones.

## Queue and decisions

`data/backlog.md` is the durable queue.
It tracks work items only, never agents; persistent secondmates never appear as backlog items.
Work routed to a secondmate is recorded in that secondmate home's own backlog, not the main backlog.
A decision is simply a task held for the captain: `tasks-axi hold <id> --reason "<reason>" --kind captain`, with `--until <date>` when the captain defers it.
When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as its own work item and hold it the same way.
Captain calls discovered by investigations or visual reviews follow `captain-hold-lifecycle`, which owns their completion gate and recorded-answer rules.
When the automatic transition gate applies, dispatch and completion move the item themselves - `bin/fm-spawn.sh` and `bin/fm-teardown.sh` own those transitions and refuse rather than report success without them - so what remains yours is filing the item before dispatch, recording decisions, and keeping notes current; `docs/configuration.md` owns gate applicability and the manual-backend exception.
Re-evaluate queued work after every teardown and heartbeat, dispatching items only when dependencies and time gates have cleared.

## Schema and handoff

`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.
Use compatible `tasks-axi` when the configured backend selects it and the documented manual path otherwise; keep only the configured recent Done entries.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.

## Notes hygiene

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, distinguishing implemented, pushed, merged, and verified-after-restart as separate milestones rather than treating one as proof of another, and route reusable knowledge to section 6 rather than scattering it through task notes.
