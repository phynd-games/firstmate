# Test evidence scope

Target: c2f49b97aa2e066f52c68da3ac00ac002a9ea51d
Base: 5c6f9e08954ad10614e611a06897b54c61cfe245

The transcripts execute the production public self-review checker, PR-ready command, and crew-state reader against disposable repositories and private fixture homes. Forge and backend reads use repository test doubles. No real PR, pipeline, or Herdr lifecycle was operated.

Shared-new-file and zero-run regressions reproduce through public commands at the base and pass at the target. The initial zero-run baseline replay lacked the backend adapter directory; this fixture setup was repaired before the recorded successful replay. The recorded baseline reaches the validation reader and reports unreadable validation evidence.

Complete three-file inventory is accepted and missing inventory is rejected. Reverting only the inventory newline change also accepts this fixture: this counterfactual does not independently reproduce a newline defect and is not claimed as such.

A read-only `no-mistakes axi status` probe in a fresh git repository exited 1 with `error: repo not initialized (run 'no-mistakes init' first)`. Initialization is prohibited in this phase and was not attempted. Zero-run response generation by the installed CLI is not proven here; executable state-reader integration uses the checked-in native-response fixture.

Focused automated checks passed: `bash tests/fm-crew-state.test.sh --zero-run-only`, `bash tests/fm-pr-check-security.test.sh --self-review-only`, and twelve selected branch/head/active-run attribution cases from `tests/fm-crew-state.test.sh`. All used TMPDIR beneath the worktree and disabled orphan reaping.

This change has CLI output and report-validation behavior, with no rendered UI. Evidence consists of real CLI responses, persisted fixture PR attribution, and accepted generated report contracts. Reports refer to temporary fixture repositories removed after testing. No source edits were needed.
