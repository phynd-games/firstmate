# Escalation and captain etiquette detail


Full detail for [AGENTS.md section 9](../../AGENTS.md#9-escalation-and-captain-etiquette).
The Rules in that section are the load-bearing subset that stays inline; this document owns the detail and is read on demand.

## Rules

- [Internal-label rewrites](#internal-label-rewrites): the mapping from internal terms to the captain's nouns, applied before any captain-facing message is sent.
- [Remaining etiquette](#remaining-etiquette): plain chat versus `lavish-axi` for decisions, verified reader links for local Markdown, and cost as a courtesy that never blocks.

## Internal-label rewrites

When evidence uses an internal label, rewrite it before sending:

- worktree, checkout, primary checkout, or local-main -> local copy, isolated copy, or local branch, only if the location matters.
- teardown -> cleanup.
- wake, watcher, heartbeat, stale, signal, or check -> notification, monitoring, waiting too long, or stopped responding.
- hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision, wait, approval, blocker, or external delay.
- done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result, review finding, passing checks, failed check, or stopped validation.
- brief -> instructions.
- crewmate -> worker, only when naming the helper matters.
- harness, backend, runtime, or adapter -> worker runtime or tool, only when the tool choice itself blocks work.
- status file, metadata, state, task id, or raw path -> durable record, local record, or omit it unless the captain needs the file path to act.
- fail-closed, fails closed, fail loudly, or refuses loudly -> stops safely when something goes wrong, refuses rather than proceeding, or reports the concrete missing requirement.
- fail-open, fails open, passive fail-open, or degraded-open -> steps aside and lets work continue when the check cannot complete, or continues without that optional protection.

## Remaining etiquette

Use plain chat for a yes-or-no decision and `lavish-axi` only when several options or a structured report benefit from a visual surface.
When you point the captain at a local Markdown document, give the verified reader link from `bin/fm-docs-reader.sh url <path>`; when that command fails, give the file path and say the reader is unavailable, and never send a loopback URL to Relay or any other remote reader (`communication-discipline` owns the rule).
Mention cost as a courtesy when unusually much work is running, but never block on it.
