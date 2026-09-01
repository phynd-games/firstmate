---
name: confirmed-handoff
description: >-
  Agent-only procedure for proving a worker actually took up an instruction.
  Use before reporting any actionable steer dispatched, before ending a turn that sent one, and before relaying a parked validation finding again.
  A queued record and a delivered doorbell are not delivery; only the worker's acknowledgement of that exact record plus an observable start counts.
user-invocable: false
metadata:
  internal: true
---

# confirmed-handoff

This skill is the single owner of the confirmed-handoff procedure.
`AGENTS.md` section 7 points here and does not restate it.
`bin/fm-handoff-confirm.sh` is the executable that performs it; its header owns the exact record format, flags, and exit codes.

## The rule

An instruction is handed off when BOTH of these are proven, and not before:

1. **Acknowledgement** - the worker moved THAT EXACT inbox record into `handled/`, matched by name and by the record's own bytes.
2. **Start** - the work that instruction asked for is observably under way on the same task, run, and finding set.

Until both hold you may not:

- report the instruction dispatched, sent, delivered, or handled;
- end the handling turn;
- relay the same parked finding, decision, or blocker again.

A queued record is durable storage, not delivery.
A doorbell that reached a terminal is a notification, not delivery.
Neither proves a worker read anything, and a worker that is wedged, exited, or looping produces both without doing any work.

## Procedure

Every actionable local steer registers its obligation automatically as `bin/fm-send.sh` writes the record; the send prints the exact confirm command as an `FM_HANDOFF_CONFIRM_REQUIRED` line.
Run that command before you treat the steer as taken up.

```
bin/fm-handoff-confirm.sh confirm --task <id> --record <path>
```

Exit 0 means acknowledged and started; that is the only outcome that lets you move on.
Exit 3 means it was not proven: the command has already queued the actionable failure and named the reason, so load `stuck-crewmate-recovery` and recover the worker.
Do not re-send the instruction first - a second copy of an instruction the worker never took up is how one wedge becomes two.

### A no-mistakes finding response

This is the case the rule exists for, because a gate response that lands in an inbox and changes nothing leaves the run parked at the same gate with the same findings, and a supervisor reading only the status log sees a decision it believes it already sent.

Register it as a finding response so an unchanged parked run is a failure rather than a pass, and state what you believe you are answering:

```
bin/fm-handoff-confirm.sh register --task <id> --record <path> \
  --kind finding-response --expect-gate <gate> --expect-findings <n>
```

An `--expect-*` value that is not true right now is refused before the obligation exists (exit 4).
That is deliberate: a decision aimed at a gate, finding set, or head the worker is not actually on is wrong at the moment you send it, and confirming it later against whatever the worker did instead would hide that.
Add `--expect-head <sha>` when the decision is only valid against a specific commit.

### Scope

The obligation covers the local steering plane.
A remote secondmate's acknowledgement lives in its own home, and its correlated reply (`bin/fm-pending-reply-lib.sh`) is that plane's confirmation path.
An explicit fire-and-forget record opts out by definition and registers nothing.

## Open obligations

`bin/fm-handoff-confirm.sh list` prints every instruction nobody has proven was taken up, oldest age first in the row.
An open obligation is unfinished supervision work, not a record to tidy away.
Reconcile it by confirming it, or by recovering the worker and re-sending once the worker is healthy.

## Repeated outcomes never reach the captain twice

The same outcome reported again is not news; it is evidence that nothing was done about it the first time.
`bin/fm-branch-outcome.sh` detects an outcome whose task, verdict, and summary repeat the previous row, records the repeat count, and tells the caller.
The supervision branch routes a repeated captain outcome to MAIN to act on autonomously instead of opening a second captain turn.

So when you find yourself about to relay the same finding, blocker, or decision a second time: that is the signal to confirm the handoff and recover the worker, not to tell the captain again.

## What this never does

It claims no lease, performs no teardown, and steers nothing beyond one re-ring of the exact record it is confirming.
Recovery belongs to `stuck-crewmate-recovery`, lifecycle to `bin/fm-control.sh`, and current state to `bin/fm-crew-state.sh`.
