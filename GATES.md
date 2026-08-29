# Gates: dashboard review hardening

OWNS: bin/fm-fleet-snapshot.sh, bin/fm-dashboard.sh, bin/fm-dashboard-start.sh, assets/dashboard-template.html, tests/fm-dashboard.test.sh, tests/fm-dashboard-start.test.sh

Scope: close the reported local-only, boundedness, path-safety, lifecycle-identity, cleanup, validation, and refresh-concurrency defects.

- [ ] G1: Snapshot and dashboard evidence stay local, bounded, and semantically complete.
  CHECK: bash tests/fm-dashboard.test.sh
  EXPECT: all dashboard tests passed
  EVIDENCE: pending

- [ ] G2: Dashboard startup preserves exact Herdr ownership and remains bounded.
  CHECK: bash tests/fm-dashboard-start.test.sh
  EXPECT: all dashboard startup tests passed
  EVIDENCE: pending

- [ ] G3: Changed shell scripts parse cleanly and the diff has no whitespace errors.
  CHECK: bash -c 'bash -n bin/fm-fleet-snapshot.sh bin/fm-dashboard.sh bin/fm-dashboard-start.sh && git diff --check && echo syntax-and-diff-check-passed'
  EXPECT: syntax-and-diff-check-passed
  EVIDENCE: pending
