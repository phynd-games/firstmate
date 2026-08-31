# Gates: Herdr supervisor CI repair

OWNS: bin/**, tests/**, docs/**, AGENTS.md, .github/workflows/**

Scope: diagnose and repair the reported Herdr supervisor CI failures with deterministic and live evidence.

- [x] G1: the deterministic Herdr supervisor regression suite passes
  CHECK: bash tests/fm-herdr-supervisor.test.sh
  EXPECT: all fm-herdr-supervisor tests passed
  EVIDENCE: passed: bash tests/fm-herdr-supervisor.test.sh -> all fm-herdr-supervisor tests passed

- [x] G2: the guarded real-Herdr supervisor smoke passes or reports its explicit environment gate
  CHECK: bash tests/fm-herdr-supervisor-smoke.test.sh
  EXPECT: /ok - (one establish keeps re-arming the real watcher inside its Herdr pane|the supervisor establishes in a real Herdr session)/
  EVIDENCE: passed: bash tests/fm-herdr-supervisor-smoke.test.sh -> all fm-herdr-supervisor smoke checks passed

- [x] G3: the repository lint owner accepts the changed shell and workflow files
  CHECK: bin/fm-lint.sh
  EXPECT: 3 workflow files valid
  EVIDENCE: passed: bin/fm-lint.sh -> ShellCheck 0.11.0 and actionlint 1.7.12; 3 workflow files valid

- [x] G4: the repository compatibility and personal-path invariants pass
  CHECK: set -eu; test ! -L CLAUDE.md; test "$(readlink .claude/skills)" = "../.agents/skills"; test -z "$(git ls-files -- data state projects .no-mistakes)"; test -z "$(git ls-files -- config | grep -Ev '^(config/backend|config/crew-dispatch\\.json|config/herdr-presentation-spaces)$' || true)"; echo "repo invariants passed"
  EXPECT: repo invariants passed
  EVIDENCE: passed: invariant command -> repo invariants passed
