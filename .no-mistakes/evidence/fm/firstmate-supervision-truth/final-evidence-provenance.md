# Final test-phase evidence and provenance

This record supersedes the prior test phase's unresolved `test-live-evidence` disposition under MAIN's supplied captured-input replay adjudication.
It establishes final-head fixture behavior; it does not claim candidate installation or final live success.

## Historical production diagnosis

The supplied historical self-review described base `unknown / unreadable validation run evidence` and candidate `working / harness busy` observations for firstmate-v2-plan.
Those calls predate final head and did not freeze their external inputs, so they are historical observations rather than a controlled causal experiment.
The exact earlier report is outside this worktree and was neither read nor edited here.
Its statement that the “exact real-world incident ... is resolved” is overbroad and must be replaced in final delivery with: “The historical grammar failure is reproduced and repaired in final-head frozen-input replay; post-install production verification remains owed.”

The historical daemon sample from no-mistakes v1.49.0-4-gfeb8cdf is retained without changing its task/run attribution in `frozen-findings-inputs/historical-capture.toon`.
It names run 01M1SKRKCG5BVV9H1CYRR3HW4S, branch fm/remove-firstmate-dashboard, head f89f5d62, cancelled outcome, and `findings: 4 info`; it is not a firstmate-v2-plan run or a fresh capture.
Its source in this phase is the existing regression's historical fixture, corroborated by the user-supplied adjudication; this phase did not independently query the vendor.

## Current unchanged-primary observation supplied by MAIN

MAIN supplied an observation captured at 2026-09-09T09:05:00Z through the primary operational owner.
Primary code remained fe601e80363dca6469775ca98ad0643071fb48f3, without candidate installation, and `fm-crew-state.sh firstmate-v2-plan` reported `state: working · source: pane · harness busy (pi-ext)`.
This does not reproduce the earlier live failure and must not be paired with a later synthetic call as a live before/after experiment.
The supplied primary hashes for fm-crew-state.sh, fm-validation-loop-lib.sh and fm-nm-run-lib.sh match the approved base hashes recorded in `final-head-provenance.json`.
The companion CLI observation named run 01M22KSZYDN9KDENNT227D4QXM, branch fm/firstmate-v2-lab-rescue, running, head d45c5479, `findings: 3 awaiting`, review fixing.
That run is not P1's run and is not known to be the raw input consumed by the separate crew-state call; it proves neither P1 validation activity nor causal ordering.
Only MAIN's embedded observation was available here; the referenced original main-production-observation.txt was not present in this phase's evidence directory, and no other checkout was read.

## Final-head frozen-input proof

Approved base: fe601e80363dca6469775ca98ad0643071fb48f3.
Implementation under test: 751ccb65bf1bf3d4c62daa2eb126de77cdb69b8f, plus test-only edits.
`final-head-provenance.json` records SHA256s from base, original implementation 5cf0782b57e32264388c64acd4a07581113b0f7e, final head and working tree.
The parser, crew-state reader and run-attribution library are byte-identical to the original implementation, proving relevant function and call-site parity without inferring whole-head equality.
The supervisor differs from that earlier implementation; the prior phase's actual final-head checks below cover its changed behavior.
No production file was changed in this phase.

Reproduction first: source base bin/fm-validation-loop-lib.sh and call fm_vloop_evidence_valid with the unchanged historical capture; exit 1 reproduces the refusal.
The same command against head exits 0.
`frozen-parser-replay.json` records all 21 corpus inputs, SHA256s, observed base/head return codes and expected head results.
Both versions consumed each identical frozen file through the actual fm_vloop_evidence_valid parser, including historical severity output, the synthetic awaiting envelope, every existing valid severity mixture, malformed/unknown/order/zero-count inputs, duplicate scalars and added duplicate-severity/zero-component negatives.
All head results match expectations.
The comparison also shows base accepted `0 awaiting` while head rejects it; the initial replay harness incorrectly expected every malformed input to fail at base, and that assertion was corrected to retain the actual historical difference.
Tests now label synthetic envelopes accurately and avoid claiming all current negatives were historically rejected.
Final focused verification `bash tests/fm-validation-loop.test.sh --findings-only` passed; see `final-findings-focused.txt`.

`frozen-crew-replay.txt` records actual base/head fm-crew-state.sh output over the same synthetic metadata, repository HEAD, CLI responses and semantic busy-state record for each paired scenario.
`crew-replay-driver.sh` preserves the executable fixture driver; it uses the existing crew-state test helpers and private base/head bin exports.
The historical foreign-branch capture remains byte-for-byte frozen: base says unknown/unreadable evidence, while head says working/pane from the synthetic claude-hook busy event.
Head does not export that foreign run as evidence belonging to the synthetic task.
The initiating trigger is the severity scalar rejected before branch attribution; a foreign latest run can expose the symptom even though the crew itself is busy.
The semantic busy record is held constant, so the parser change explains the difference without attributing the foreign run to the crew.

Constructed passed/failed variants retain the historical run id and `4 info` scalar but explicitly replace branch, head, status, PR and outcome with synthetic fixture fields.
These variants are not production captures.
Base reports unknown; head reports done/failed from run-step, and its exported evidence exactly matches the frozen attributed input (`crew-export-synthetic-bound-*.toon`).
The synthetic task is `severity`, branch fm/severity-summary; its real throwaway Git HEAD is recorded in the replay log and the frozen variant inputs.
Endpoint identity, Herdr CLI responses, the claude-hook event, and old progress log are synthetic; no P1 metadata was copied.
Malformed findings, explicit unknown semantic state, and an unreadable pane remain unknown on both versions, without recycling the old progress log.
An initial unknown-state setup accidentally used arm's default busy state; it was corrected to `--state unknown`.
An initial unread-pane setup failed the entire native preflight; it was corrected to fail only pane read while retaining valid synthetic capabilities.
Both initial setup failures are retained in `crew-replay-*-fixture-error.txt`; the final focused replay passes every assertion.

## Existing final-head checks retained without unnecessary reruns

`test-execution-notes.txt` binds the previous round's execution to this same final implementation head and private fixtures.
`supervisor-claim-episodes.txt` records the successful --claim-alarms-only and --claim-loop-arrival-only checks, including healthy competing owners, durable failure deduplication, new alarms after recovery, delivery retries, concurrent ensures, monitor handoff, identity replacement and observation-lock contention.
`mutation-before-after.txt` records the base failures at the intended owner and loop-arrival assertions, with successful head outputs.
`focused-check-logs.txt` records unknown/unreadable/dead refusal, stale-evidence and frozen-progress stops, repeated-finding/fix-round bounds, scope/head limits and recovery handoff preserving run/head custody before resetting for a new run.
These are behavior through executable owners and persisted journal/queue contracts, not assertions over implementation source.
That log's initial watcher failure is a fixture setup problem corrected by private legacy-backend policy markers; its focused watcher retry passes.
The scalar grammar does not replace the separate repetition/fix-round budgets; the existing bounded continuation checks remain the relevant over-budget evidence.

## Remaining delivery obligation and isolation

After the outer delivery process installs the validated candidate, the operational owner still owes a live read-only verification against firstmate-v2-plan with contemporaneous task/run/head attribution and the exact input consumed by crew-state.
This test phase neither waives that obligation nor claims the currently unchanged primary is failing.
The supplied adjudication authorizes this captured-input replay as the bounded resolution of the evidence gap during testing.
No additional captain decision or primary-home mutation is needed for this assigned phase.
All new execution used synthetic HOME/FM_HOME/TMPDIR and CLI fixtures under this worktree, with FM_TEST_SKIP_ORPHAN_REAP=1 for test helpers.
Private evidence is retained only in the explicitly authorized evidence directory.
No primary-state reads, native Herdr lifecycle, credentials, pipeline control, lint, formatting, static analysis, complete repository suite, push, PR or CI operations were performed.
The temporary .test-evidence-replay directory, exported bin trees, synthetic repositories, HOME and TMPDIR were removed after all focused commands completed.
