# Validation-loop limits

Deterministic rational limits for the automatic continuation of validation and supervision loops.
`bin/fm-validation-loop-lib.sh`'s header is the one owner of the continue/stop contract, the journal format, and the exact thresholds; this page records the architecture around it - why each boundary sits where it does, what a stop means, and how control is re-established.

## The problem this closes

The supervision absorb path (`crew_absorb_class` in `bin/fm-classify-lib.sh`) keeps absorbing wakes while a crew is provably working, and an actively-running no-mistakes step is exactly such proof.
Nothing bounded how long that proof could be recycled: a run looping through fix rounds forever, re-presenting the identical findings after every fix, claiming `running` while its evidence never changed, or hiding behind a busy pane after its run stopped being readable, was absorbed as routine progress indefinitely.
The watcher's wedge timer and busy-turn bound cover idle and hung panes; they cannot see a loop that keeps looking busy.

## The contract

A validation run continues automatically while it has fresh evidence, a coherent head advance, a bounded known change set, and a credible path to completion.
Automatic continuation stops - the wake surfaces instead of being absorbed - when the current state is unknown, unreadable, or dead (never absorbed, with or without a journal), when the loop is repetitive (fix rounds or an identical findings theme past its explicit bound), when an active run's evidence freezes past the stall bound, or when an active run's pipeline evidence goes stale (no readable run evidence within the freshness bound while a pane still reads busy).
Repetition and staleness are decided from a durable per-task journal (`state/<id>.validation-loop`) folded from the run evidence `bin/fm-crew-state.sh` exports at the absorb decision itself, so the decision is pure bash over durable state - no LLM is ever the watcher.

A threshold breach is never rendered as routine progress: the journal records the verdict durably, `fm-crew-state.sh` decorates its working detail with the recorded stop, and the watcher's surfaced wake reason carries the breach text.

## What a stop is - and is not

A stop changes nothing but the durable journal and the absorb verdict.
The worker, its branch, its worktree, and the no-mistakes run's custody are untouched; the same-copy recovery contract in `stuck-crewmate-recovery` (and `AGENTS.md` section 7's supported abort/custody sequence for the run itself) is the only way control is re-established.
A stop never creates a duplicate worker, never discards changes, and never approves or skips a failing check.
A replacement run on the same branch and copy is the recovery handoff: the journal's counters reset on the new run id, so continuation resumes without manual state surgery.
When the captain explicitly authorizes continuing a stopped loop as-is, removing the task's journal is the documented reset; it forces a clean re-fold from fresh evidence.

Away mode is unchanged: while `state/.afk` exists the daemon owns triage with its own escalation ladder, and the journal simply stops accumulating until the always-on watcher resumes.

## Supervision-note coalescing

The same rationality applies to the Pi supervision branch's captain-facing routine notes: a task main already owns must not accumulate repeated no-change notes.
`bin/fm-branch-outcome.sh`'s `note-render` header owns that deterministic per-task novelty gate (captain-relevant status lines, recorded PR identity, recorded validation-loop stop); durable outcomes, the read cursor, leases, and captain-verdict escalation are untouched, and a gate that cannot answer fails toward rendering.

## Regression coverage

`tests/fm-validation-loop.test.sh` pins near-complete continuation, the repeated-finding stop, the unknown-state stop, the stale-pipeline-evidence stop, the recovery handoff, the threshold semantics, and the watcher's decorated limit surface.
`tests/fm-branch-supervision.test.sh` and `tests/fm-pi-branch-extension.test.sh` pin the note-coalescing gate and its extension wiring.

## Closure sequence

Delivery of this contract - and of any change to these supervision surfaces - closes in a fixed order:

1. Every accepted feature and every open PR reaches green validation through its selected delivery path; a red or looping validation is stopped by these limits and recovered, never approved around.
2. Firstmate then runs local Herdr validation from this home - the env-gated live-harness lane (`bin/fm-test-run.sh`, the `live-harness-optin` family) against the installed Herdr, isolated to a named non-default lab session per `bin/fm-herdr-lab.sh` - because standard CI has no Herdr binary and cannot exercise those surfaces.
3. Only after both may a separately authorized direct landing (the captain-approved `local-only` merge path) proceed; landing authority itself stays with `AGENTS.md` section 7 and is never implied by green validation alone.
