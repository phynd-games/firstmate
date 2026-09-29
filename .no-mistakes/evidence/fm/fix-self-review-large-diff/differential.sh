#!/bin/bash
source tests/.nm-self-review-helpers.sh
set -e
dir=$(make_large_diff_case differential 3)
write_large_diff_surface_report "$dir" "$(large_diff_tests_files "$dir")"
mkdir "$dir/original"
git show 844e04e:bin/fm-pr-lib.sh > "$dir/original/fm-pr-lib.sh"
cp bin/fm-pr-self-review-check.sh "$dir/original/"
python3 .test-tmp/differential.py "$dir" "$SELF_REVIEW_CHECK" "$EVIDENCE"
