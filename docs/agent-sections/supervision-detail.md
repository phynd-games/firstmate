# Supervision protocol detail


Full detail for [AGENTS.md section 8](../../AGENTS.md#8-supervision-protocol).
The Rules in that section are the load-bearing subset that stays inline; this document owns the detail and is read on demand.
Fleet supervision is an always-loaded operational contract; the live-cycle, wake-drain, acknowledgement, and watcher-kill rules stay inline in section 8, and this document holds the per-wake handling and the rest of the detail.

## Rules

- [Handling actionable wakes](#handling-actionable-wakes): what to do for each of `signal:`, `stale:`, `check:`, and `heartbeat:`.
- [Repeated no-progress symptoms](#repeated-no-progress-symptoms): separate observation from cause, choose a discriminating check, and escalate a real blocker once.
- [Merges and Relay-linked work](#merges-and-relay-linked-work): refresh the clone after a merged-PR wake, and load `fmx-respond` for Relay-linked milestones.
- [Secondmate idle endpoints and silent waiting](#secondmate-idle-endpoints-and-silent-waiting): a quiet healthy cycle is not captain-facing progress.
- [Guard warnings](#guard-warnings): guards are structural backstops, not a substitute for the contract.

## Handling actionable wakes

Handle actionable wakes as follows:

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, unresponsive, or validation-loop-limited worker; a deep-inspection reason also requires current-state and validation-log inspection, and a validation-loop limit reason is deterministic recovery input, never routine progress to re-absorb.
3. For `check:`, act on the named poll result, including merges, Relay events, process-to-event source results, and captain inbox notes; a handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`, or it stays counted as still waiting for firstmate.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, and never report an unchanged fleet as progress.

## Repeated no-progress symptoms

On repeated no-progress symptoms, separate the observation from its cause: consult existing status, evidence, and pending changes, choose a check that actually discriminates between the live possibilities, and take the concrete recovery action it points to; never repeat an ineffective repair or demand the same restart without a changed prerequisite.
A heartbeat is not live coverage, a queued instruction is not an acknowledgement, a failed parser is not proof a worker died, an open PR is not deployed code, and green CI or a successful build is not a completed restart; reconcile conflicting evidence through the established owners rather than forging closure or discarding native evidence, and verify continuity and resumed work after any restart before claiming it succeeded.
Once a real blocker survives that diagnosis, escalate it once with exact evidence and the action needed, then keep advancing any other independent authorized work rather than idling on the same alert.

## Merges and Relay-linked work

When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up so the link clears even if earlier follow-ups were spent.

## Secondmate idle endpoints and silent waiting

A secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than treating a quiet pane as stale.
Waiting on a healthy supervision cycle is silent; empty polls, elapsed time, and no-change updates are not captain-facing progress.

## Guard warnings

Guard warnings do not replace the contract.
Queued wakes must be presented before other action and acknowledged only after handling, stale liveness must be repaired through the emitted protocol, and the worktree-tangle warning must be resolved without touching unlanded work.
The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable worktree, never the primary checkout.
Harness-aware turn-end guards are structural backstops, not permission to omit the live cycle.
