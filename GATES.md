# Gates: Herdr-only review fixes

OWNS: bin/fm-backend.sh, bin/fm-crew-state.sh, bin/fm-peek.sh, bin/fm-pending-reply-lib.sh, bin/backends/herdr.sh, bin/fm-test-run.sh, tests/fm-secondmate-liveness.test.sh

Scope: close the reported Herdr capability, endpoint binding, failure propagation, cleanup, and scheduled-test gaps.

- [x] G1: focused Herdr review verification passes
  CHECK: git diff --check && bash -n bin/fm-backend.sh bin/fm-crew-state.sh bin/fm-peek.sh bin/fm-pending-reply-lib.sh bin/backends/herdr.sh bin/fm-test-run.sh tests/fm-secondmate-liveness.test.sh && bash tests/fm-backend-herdr.test.sh && bash tests/fm-bootstrap.test.sh && printf '%s\n' 'Herdr review verification passed'
  EXPECT: Herdr review verification passed
  EVIDENCE: gate-lint, diff-check, shell syntax checks, fm-backend-herdr.test.sh, and fm-bootstrap.test.sh passed.
