#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot launch-cleanup)
for scenario in '0 0 0 0' '0 1 0 1' '17 0 0 17' '17 1 0 17' '0 0 1 1' '17 0 1 17'; do
  read -r original teardown cleanup expected <<< "$scenario"
  marker="$TMP_ROOT/case-$original-$teardown-$cleanup"
  bash -s -- "$ROOT" "$original" "$teardown" "$cleanup" "$marker" > "$marker.output" 2>&1 <<'SH'
. "$1/tests/herdr-test-safety.sh"
original=$2 teardown=$3 cleanup=$4 marker=$5
herdr_safe_stop_and_delete() { printf '%s\n' "$1" > "$marker"; return "$teardown"; }
fm_test_cleanup() { printf done > "$marker.cleanup"; return "$cleanup"; }
trap 'herdr_finish_test "$?" fm-lab-cleanup-test' EXIT
exit "$original"
SH
  rc=$?
  expect_code "$expected" "$rc" "cleanup must preserve failures"
  [ "$(cat "$marker")" = fm-lab-cleanup-test ] || fail "cleanup targeted another session"
  [ -f "$marker.cleanup" ] || fail "temporary cleanup was skipped"
done
pass "native test cleanup propagates teardown, tripwire, and original failures"
