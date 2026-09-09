# Current-head test evidence

Tested head: 9d11f78251df91699aacb594a34e9834af8dab12.
Approved base: fe601e80363dca6469775ca98ad0643071fb48f3.

## Result

The assigned test phase passes under MAIN's captured-input replay adjudication.
No source or test edits were necessary in this round.
The entire production bin tree is unchanged from previously tested 751ccb65bf1bf3d4c62daa2eb126de77cdb69b8f; only tests changed between those heads.
`current-head-parity.json` records exact relevant file SHA256s.
This establishes executable parity for retained prior evidence, not whole-head equality or deployment.

## Commands executed this round

Each test used HOME=$PWD/.test-phase-current/home, FM_HOME=$PWD/.test-phase-current/home, TMPDIR=$PWD/.test-phase-current/tmp, and FM_TEST_SKIP_ORPHAN_REAP=1.
Supervisor helpers further set per-case synthetic HOME/FM_HOME and a stateful fake Herdr CLI.

- `bash tests/fm-validation-loop.test.sh --findings-only`: passed.
- `bash tests/fm-validation-loop.test.sh --watcher-limits-only`: passed, including intentional queue-write and marker-write failure injections; their directory errors are expected negative-path output.
- `bash tests/fm-crew-state.test.sh --terminal-severity-only`: passed; actual CLI output is in `current-crew-terminal.txt`.
- `bash tests/fm-herdr-supervisor.test.sh --claim-alarms-only`: passed; `current-claim-episodes.txt` contains actual deferral output and persisted alarm queue rows, including one unresolved episode and a later episode after recovery. It also exercises main-loop owner arrival, concurrency, delivery retry, identity replacement, and recovery under observation-lock contention.
- Python-orchestrated identical frozen-input comparison invokes `bash -c '. "$1" || exit 2; fm_vloop_evidence_valid "$(cat "$2")"' _ LIB FIXTURE` for each corpus entry at base and head, checking input SHA256, expected return code, and absence of setup errors. `current-parser-replay.json` records the results.
- Read-only `git diff 751ccb65bf1bf3d4c62daa2eb126de77cdb69b8f HEAD -- bin` and file SHA256 comparison establish parity to prior behavioral proof.

The initial parser replay exported only its primary library and failed because fm-nm-run-lib.sh was missing from the private base fixture.
After exporting the approved base's sibling library, all frozen input comparisons passed with no stderr.
This was a resolved test setup error.

## Retained behavioral evidence

`frozen-crew-replay.txt` and `crew-replay-driver.sh` remain the paired actual reader replay over identical inputs: historical foreign-branch capture yields unknown at base and working/pane at candidate without exporting a foreign run as the task's evidence; explicitly synthetic attributed passed/failed envelopes yield done/failed at candidate; malformed evidence, unknown semantic state, unread pane, and old progress negatives remain unknown.
`mutation-before-after.txt` retains intended base failures for parser, terminal crew-state, healthy-owner ensure, and main-loop owner-arrival regressions.
The current production tree's byte parity and rerun focused tests bind that evidence to this head.
`focused-check-logs.txt` retains prior executed repetition/fix-round budgets, stale/unknown evidence, scope/head bounds, and recovery preserving run custody.
Its baseline watcher fixture failures were resolved by private test policy markers; this round independently reran those watcher tests successfully.
`test-execution-notes.txt` and `final-evidence-provenance.md` retain all earlier baseline commands, fixture authoring corrections, provenance and limitations; references to 751ccb65 there name the prior tested head, superseded for current-head attribution by this addendum.

## Production provenance and delivery boundary

Historical production observations described unknown/unreadable evidence at base and working/harness busy at an earlier candidate, without freezing external inputs.
They are historical observations, not a controlled final-head live experiment.
The historical v1.49.0-4-gfeb8cdf capture with `findings: 4 info` names run 01M1SKRKCG5BVV9H1CYRR3HW4S, branch fm/remove-firstmate-dashboard, head f89f5d62; it is not a firstmate-v2-plan run.

MAIN's supplied current observation at 2026-09-09T09:05:00Z reports firstmate-v2-plan working/pane/harness busy (pi-ext) while the primary remains at the approved base, without candidate installation.
This observation does not reproduce the earlier failure.
The companion run 01M22KSZYDN9KDENNT227D4QXM belongs to fm/firstmate-v2-lab-rescue at d45c5479 and is not established as the input consumed by that crew-state call.
The original main-production-observation.txt is absent here; only MAIN's explicitly supplied embedded observation was used.

The accurate delivery claim is: historical grammar failure reproduced and repaired in frozen-input replay against the current head; live read-only verification after installation remains owed to the operational owner.
Do not reuse the earlier overbroad claim that the exact real-world incident is resolved.
No new production capture, primary-state access, candidate installation, native Herdr lifecycle, or credential operation occurred in this phase.
The adjudication supplies the authorized bounded resolution of test-live-evidence; no additional user decision is needed in this phase.

## Cleanup and scope

All synthetic test HOME/FM_HOME, temporary library exports and fixture directories under .test-phase-current were removed after tests exited.
Evidence remains only in the dedicated authorized directory.
No UI-facing change exists; CLI transcripts and persisted alarm rows are the relevant end-user surfaces, so screenshots are not applicable.
No lint, formatter, static analysis, complete repository suite, pipeline-control, push, PR, or CI command was run.
