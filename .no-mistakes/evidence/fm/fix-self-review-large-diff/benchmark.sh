#!/bin/bash
source tests/.nm-self-review-helpers.sh
set -e
dir=$(make_large_diff_case measured-3676 3675)
write_large_diff_surface_report "$dir" "$(large_diff_tests_files "$dir")"
mkdir "$dir/shim"
printf '#!/bin/sh\nprintf x >> "$FM_TEST_OD_COUNT"\nexec /usr/bin/od "$@"\n' > "$dir/shim/od"
chmod +x "$dir/shim/od"
export FM_HOME="$dir/home" FM_TEST_OD_COUNT="$dir/od-count"
export PATH="$dir/shim:/bin:/usr/bin:$PATH"
python3 - "$SELF_REVIEW_CHECK" "$dir" "$EVIDENCE" <<'PY'
import os, subprocess, sys, time
from pathlib import Path
checker,fixture,evidence=sys.argv[1:]
start=time.monotonic()
r=subprocess.run([checker,'task-a','no-mistakes'],capture_output=True,text=True,timeout=420)
elapsed=time.monotonic()-start
count=Path(fixture,'od-count').stat().st_size
report=Path(fixture,'home/data/task-a/pr-self-review.md')
text=f'Command: /bin/bash bin/fm-pr-self-review-check.sh task-a no-mistakes\nShell: macOS /bin/bash 3.2.57\nChanged paths: 3676 (3675 deleted JSON paths plus AGENTS.md)\nReport bytes: {report.stat().st_size}\nElapsed seconds: {elapsed:.3f}\nod invocations: {count}\nExit: {r.returncode}\nstdout:\n{r.stdout}stderr:\n{r.stderr}'
Path(evidence,'large-diff-checker.txt').write_text(text)
print(text,flush=True)
assert r.returncode == 0
assert count <= 3675*6+100
PY
