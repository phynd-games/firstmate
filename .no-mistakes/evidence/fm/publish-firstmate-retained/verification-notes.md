# Test phase outcome

No new regression found in the scoped checks.
The ordinary two-parent merge and unchanged workflow tree were verified by Git object identity.

The candidate and base production code both fail the same adapter assertion (same-labeled workspaces: expected 3, got 2) and pending-reply assertion (unmarked crewmate send: expected 0, got 1).
The adapter baseline fixture received only the four terminal_id fields already disclosed in the intent; baseline production code was unchanged.
These failures were explicitly accepted as out of scope in the author intent, so no corrective source changes were made.
The new environment-isolation and wake-containment cases executed successfully before those failures.

The docs-reader suite initially skipped because fixture homes did not discover a runtime.
A pinned private runtime was installed inside the disposable worktree fixture; the launch-recovery selector then passed with FM_DOCS_READER_PYTHON supplied.
The actual reader served HTTP 200, repeated ensure reused the same URL, Chrome rendered the page, and stop persisted the same launch identity as stopped.
The first screenshot wrapper attempts failed to create evidence; direct headless Chrome produced reader-report.png, which was visually inspected.

The native launch guard passed on Herdr 0.8.2 through fm-herdr-lab.sh, including its default-session tripwire and teardown.
No real coding agent was launched; reported-agent registration is a controlled positive test of Herdr native status.
The timeout-status selector uses a fake ShellCheck to test deadline behavior; no lint, formatting, or static analysis was performed.
Broad CI, publication, PR creation, merge, and adoption were not performed by this test phase.

All temporary worktree fixtures, private runtime, and browser profiles were removed after stopping their processes.
