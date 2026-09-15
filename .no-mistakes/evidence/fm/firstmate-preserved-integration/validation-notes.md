# Targeted test evidence

The target was a8b3556ac2a7b6f214388ffde4ec989b5a3f624e, based on c6f2a4d61467071c7668d427c9a63e7935dc5ca9.

## Direct behavior evidence

- `ancestry-and-fast-forward.txt`: all seven required inputs remain ancestors; a disposable primary checkout actually fast-forwarded; the retained CI jobs were checked as parsed YAML.
- `runtime-regressions.txt`: the pre-fix supervisor and cleanup implementations reproduce the erroneous diagnostics; the target emits the attributed stopped-server diagnostic, starts no worker, and skips the cleanup probe when no candidate exists.
- `herdr-lab-behavior.txt`: real fixture-process identities, receipts, bounded refusals, cancellation, and preserved unrelated processes from the executable lab tests with a fake Herdr client.
- `docs-reader.html`: actual HTTP output from the real document reader, with its local styles/fonts/scripts inlined for inspection.
- `reader-navigation.txt`: actual browser navigation from the nested report to the document root.

## Setup and fixture corrections

An initial startup invocation exposed the real Node binary through an unnecessary PATH override; rerunning with the suite default restored its intentional missing-tool scenario.
Placing Nix and configuration-inheritance fixtures inside this Git worktree triggered their real untracked-file safety rules; their retries used the allowed evidence directory as TMPDIR.
The initial startup, cleanup, and handoff runs exposed stale test fixtures.
The test-only changes explicitly authorize each fake legacy-backend fixture, preserve the current read-only legacy-record output contract, provide required native capability/terminal identity data in cleanup mocks, and add focused startup test selection.
The production sources were unchanged.
The originally failing cases were rerun after correction.

The screenshot CLI twice reported an output path without creating a file; actual rendered HTML was retained instead.
One browser navigation attempt followed completion of the command that owned the test server and could not connect; repeating navigation while keeping that command alive succeeded, and the recorded server was then stopped cleanly.
No complete repository suite, linter, static-analysis command, pipeline-control action, push, PR, or CI phase was executed.

Final reconciliation verified a successful recorded outcome for every selected suite and corrected startup case.
No fixture processes remained before removal of the disposable worktree data.
Only tests/fm-session-start.test.sh, tests/fm-herdr-session-cleanup.test.sh, and tests/fm-handoff-confirm.test.sh were changed.
