#!/usr/bin/env bash
set -eu
EVIDENCE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$EVIDENCE/pr-fixture-functions.sh"
check_report() {
  local label=$1 checker=$2 expected=$3 actual=0
  printf '\n%s\n$ %s task-a no-mistakes\n' "$label" "$checker"
  FM_HOME="$dir/home" "$checker" task-a no-mistakes || actual=$?
  printf 'exit: %s\n' "$actual"
  [ "$actual" -eq "$expected" ] || fail "$label: unexpected exit $actual"
}
dir=$(make_case evidence-single-new-file)
git -C "$dir/wt" reset --hard -q main
printf '%s\n' fixture '# shared authority and delivery instructions' > "$dir/wt/AGENTS.md"
git -C "$dir/wt" add AGENTS.md
git -C "$dir/wt" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm one-new-file
write_one_new_file_surface_report "$dir"
printf 'ISOLATED FIXTURE: one new AGENTS.md file, one hunk; independent authority/documentation/delivery proofs. No live home or forge is used.\n'
check_report 'Base commit: valid shared evidence rejected (reproduced defect)' "$ROOT/.test-phase-tmp/base/bin/fm-pr-self-review-check.sh" 1
check_report 'Target commit: the identical report is accepted' "$SELF_REVIEW_CHECK" 0
cp "$dir/home/data/task-a/pr-self-review.md" "$EVIDENCE/accepted-single-file-review.md"
printf '\nPublic PR-ready command with isolated forge fixture:\n'
run_check_entry "$dir" task-a https://github.com/o/r/pull/119
printf '\nPersisted PR attribution:\n'
cat "$dir/home/state/task-a.pr-poll"
dir=$(make_case evidence-inventory)
git -C "$dir/wt" reset --hard -q main
mkdir -p "$dir/wt/docs"
for file in AGENTS.md README.md docs/setup.md; do printf '%s\n' fixture "new $file contract" > "$dir/wt/$file"; done
git -C "$dir/wt" add AGENTS.md README.md docs/setup.md
git -C "$dir/wt" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm overlapping-owners
write_one_new_file_surface_report "$dir" README.md AGENTS.md,README.md,docs/setup.md
printf '\nISOLATED FIXTURE: three changed paths; authority/delivery share AGENTS.md, documentation cites README.md; complete three-file inventory.\n'
check_report 'Newline-only counterfactual also accepts this fixture; no independent baseline failure claimed' "$ROOT/.test-phase-tmp/newline-regression/bin/fm-pr-self-review-check.sh" 0
check_report 'Target commit: complete inventory and feasible distinct-file coverage accepted' "$SELF_REVIEW_CHECK" 0
cp "$dir/home/data/task-a/pr-self-review.md" "$EVIDENCE/accepted-overlapping-review.md"
python3 - "$dir/home/data/task-a/pr-self-review.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace(',docs/setup.md',''))
PY
check_report 'Negative control: missing docs/setup.md inventory is rejected' "$SELF_REVIEW_CHECK" 1
