#!/bin/bash
source tests/.nm-self-review-helpers.sh
set -e
test_pr_ready_large_diff_is_linear_and_keeps_refusals
test_pr_ready_refuses_path_whose_encoding_od_squeezes
{
  printf 'Public checker command: bin/fm-pr-self-review-check.sh task-a no-mistakes\n101 changed paths; od invocations: '
  wc -c < "$TMP_ROOT/large-diff/od-count"
  for variant in valid omitted-path unchanged-file-listed malformed-hex head-forged; do
    printf '\nScenario: %s\n' "$variant"
    cat "$TMP_ROOT/large-diff/$variant.out" "$TMP_ROOT/large-diff/$variant.err"
  done
  printf '\nScenario: squeezed od path (refused)\n'
  cat "$TMP_ROOT/squeezed-path/squeeze.out" "$TMP_ROOT/squeezed-path/squeeze.err"
} > "$EVIDENCE/refusal-checker.txt"
