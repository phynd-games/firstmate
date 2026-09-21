#!/usr/bin/env bash
set -eu
EVIDENCE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$EVIDENCE/crew-fixture-functions.sh"
reset_fakes
d=$(new_case evidence-zero-run)
make_repo_on_branch "$d/wt" fm/evidence-zero-run
make_fakebin "$d" >/dev/null
write_crew_meta "$d/state/zero-run.meta" "$d/wt" kind=ship harness=claude
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" zero-run)
"$ROOT/bin/fm-busy-event.sh" apply "$d/state" zero-run busy --gen "$gen" --source claude-hook --event user-prompt-submit
FM_FAKE_AXI_STATUS=$(zero_run_status)
printf 'ISOLATED FIXTURE: semantic busy record plus native zero-run CLI response. Backend reads are stubbed; no live Herdr lifecycle or pipeline operations.\nInput:\n%s\n' "$FM_FAKE_AXI_STATUS"
printf '\nBase commit public state reader:\n'
CREW_STATE="$ROOT/.test-phase-tmp/base/bin/fm-crew-state.sh"
out=$(run_crew_state "$d" zero-run); printf '%s\n' "$out"
assert_contains "$out" 'unreadable validation run evidence' 'base reproduces zero-run rejection at validation reader'
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
printf '\nTarget commit public state reader:\n'
out=$(run_crew_state "$d" zero-run); printf '%s\n' "$out"
assert_contains "$out" 'state: working' 'target recognizes busy worker'
assert_contains "$out" 'source: pane' 'target uses ordinary activity source'
printf '\nTarget with idle activity and needs-decision log:\n'
arm_idle_record "$d/state" zero-run
printf 'needs-decision: which database?\n' > "$d/state/zero-run.status"
out=$(run_crew_state "$d" zero-run); printf '%s\n' "$out"
assert_contains "$out" 'state: parked' 'idle worker retains pending decision'
for shape in partial empty extra malformed; do
  case "$shape" in
    partial) FM_FAKE_AXI_STATUS='runs: 0 runs yet in this repository' ;;
    empty) FM_FAKE_AXI_STATUS='' ;;
    extra) FM_FAKE_AXI_STATUS="$(zero_run_status)
run: conflicting" ;;
    malformed) FM_FAKE_AXI_STATUS='runs: 0 runs yet in this repository
help[0]: unsupported' ;;
  esac
  printf '\nTarget with %s response:\n' "$shape"
  out=$(run_crew_state "$d" zero-run); printf '%s\n' "$out"
  assert_contains "$out" 'state: unknown' 'malformed response stays unknown'
  assert_contains "$out" 'source: none' 'malformed response cannot use stale log'
done
cat > "$d/fakebin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'runs: 0 runs yet in this repository' 'help[1]: native help'
exit 7
EOF
printf '\nTarget with otherwise valid zero-run text but command exit 7:\n'
out=$(run_crew_state "$d" zero-run); printf '%s\n' "$out"
assert_contains "$out" 'state: unknown' 'failed query stays unknown'
