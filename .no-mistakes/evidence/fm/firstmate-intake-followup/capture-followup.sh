#!/usr/bin/env bash
set -euo pipefail
export EVIDENCE_DIR="$(cd "$(dirname "$0")" && pwd)"
export TMPDIR="$PWD/.test-tmp"
export FM_TEST_SKIP_ORPHAN_REAP=1
mkdir -p "$TMPDIR"
manual_followup_evidence() {
  set -e
  local home parent child receipt before old_intake output key rc
  home=$(make_home reviewer-demo)
  parent=fixture-v2-plan
  child=fixture-v2-journal
  setup_parent_receipt "$home" "$parent" >/dev/null
  printf 'MAIN declaration: journal is the exact approved follow-up within the accepted P1-P8 boundary. Fixture only.\n' > "$home/scope.md"
  printf 'MAIN reviewed this child scope against the captured parent approval. No new captain answer.\n' > "$home/approval.md"
  add_task "$home" "$child"
  (cd "$home" && HOME="$home" tasks-axi hold "$child" --kind captain --reason 'Separate fixture decision remains pending' >/dev/null)
  cp "$home/data/backlog.md" "$home/backlog.before"
  printf '\n$ fm-lavish-intake.sh carry-forward %s --parent %s --scope-source <fixture>/scope.md --scope-id journal --approval-source <fixture>/approval.md\n' "$child" "$parent"
  run_intake "$home" carry-forward "$child" --parent "$parent" --scope-source "$home/scope.md" --scope-id journal --approval-source "$home/approval.md"
  receipt="$home/state/$child.lavish-intake"
  cp "$receipt" "$home/child.before"
  cp "$home/state/$parent.lavish-intake" "$home/parent.before"
  printf '\n$ fm-lavish-intake.sh verify %s\n' "$child"
  run_intake "$home" verify "$child"
  printf '\n$ fm-brief.sh %s firstmate --mode no-mistakes --intake <child-receipt> --approved-base-ref main --approved-base-sha <target>\n' "$child"
  run_brief "$home" "$child" firstmate --mode no-mistakes --intake "$receipt"
  cp "$home/data/$child/brief.md" "$EVIDENCE_DIR/child-brief.md"
  cp "$receipt" "$EVIDENCE_DIR/child-receipt.txt"
  python3 - "$home/data/$child/brief.md" <<'PYCHECK'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'starting `git rev-parse HEAD` against the approved base' in text
assert 'Lavish intake parent: fixture-v2-plan' in text
assert 'Lavish intake scope: journal' in text
print('Generated worker instructions retain the literal `git rev-parse HEAD` command and identify the approved parent and child scope.')
PYCHECK
  printf '\n$ fm-lavish-intake.sh check-brief %s <generated-child-brief>\n' "$child"
  run_intake "$home" check-brief "$child" "$home/data/$child/brief.md"
  printf '\n$ repeat identical carry-forward\n'
  run_intake "$home" carry-forward "$child" --parent "$parent" --scope-source "$home/scope.md" --scope-id journal --approval-source "$home/approval.md"
  cmp "$receipt" "$home/child.before"
  cmp "$home/state/$parent.lavish-intake" "$home/parent.before"
  cmp "$home/data/backlog.md" "$home/backlog.before"
  [ ! -e "$home/state/$child.meta" ]
  printf 'Parent and child receipt bytes unchanged; existing captain hold/backlog unchanged; no child endpoint metadata created.\n'
  printf '\n$ retry with changed approval declaration\n'
  cp "$home/approval.md" "$home/approval.saved"
  printf 'Additional unapproved scope\n' >> "$home/approval.md"
  if output=$(run_intake "$home" carry-forward "$child" --parent "$parent" --scope-source "$home/scope.md" --scope-id journal --approval-source "$home/approval.md" 2>&1); then fail 'changed approval accepted'; fi
  printf '%s\n' "$output"
  cmp "$receipt" "$home/child.before"
  cmp "$home/state/$parent.lavish-intake" "$home/parent.before"
  cp "$home/approval.saved" "$home/approval.md"
  printf '\n$ retry with each duplicated carry-forward field\n'
  for key in parent_task_id scope_id scope_source scope_source_sha256 approval_source approval_source_sha256; do
    cp "$home/child.before" "$receipt"
    sed -n "/^$key=/p" "$home/child.before" >> "$receipt"
    cp "$receipt" "$home/duplicate.before"
    if output=$(run_intake "$home" carry-forward "$child" --parent "$parent" --scope-source "$home/scope.md" --scope-id journal --approval-source "$home/approval.md" 2>&1); then fail "duplicate $key accepted"; fi
    printf '%s: %s\n' "$key" "$output"
    cmp "$receipt" "$home/duplicate.before"
  done
  cp "$home/child.before" "$receipt"
  printf '\n$ verify with the base-commit intake owner (regression comparison)\n'
  mkdir -p "$home/base-code"
  cp -R "$ROOT/bin" "$home/base-code/bin"
  git -C "$ROOT" show fe601e80363dca6469775ca98ad0643071fb48f3:bin/fm-lavish-intake.sh > "$home/base-code/bin/fm-lavish-intake.sh"
  old_intake=$INTAKE
  INTAKE="$home/base-code/bin/fm-lavish-intake.sh"
  if output=$(run_intake "$home" verify "$child" 2>&1); then fail 'base unexpectedly accepted carried-forward receipt'; fi
  printf '%s\n' "$output"
  INTAKE=$old_intake
  printf '\n$ fixture-only parent cleanup using existing teardown test helper (external operations stubbed)\n'
  run_fixture_parent_teardown "$home" "$parent"
  [ ! -e "$home/state/$parent.lavish-intake" ]
  [ ! -e "$home/state/$parent.lavish-intake-session" ]
  printf '\n$ fm-lavish-intake.sh verify %s (parent receipt and session removed)\n' "$child"
  run_intake "$home" verify "$child"
  printf '\n$ fm-lavish-intake.sh check-brief %s <generated-child-brief> (after parent cleanup)\n' "$child"
  run_intake "$home" check-brief "$child" "$home/data/$child/brief.md"
}
export -f manual_followup_evidence
FM_TEST_ONLY=manual_followup_evidence bin/fm-test-run.sh tests/fm-lavish-feature-intake.test.sh | tee "$EVIDENCE_DIR/followup-transcript.txt"
