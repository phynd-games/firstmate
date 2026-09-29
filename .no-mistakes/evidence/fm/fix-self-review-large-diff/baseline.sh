#!/bin/bash
source tests/.nm-self-review-helpers.sh
set -e
dir=$(make_large_diff_case baseline 30)
write_large_diff_surface_report "$dir" "$(large_diff_tests_files "$dir")"
mkdir "$dir/original" "$dir/shim"
git show 844e04e:bin/fm-pr-lib.sh > "$dir/original/fm-pr-lib.sh"
cp bin/fm-pr-self-review-check.sh "$dir/original/"
printf '#!/bin/sh\nprintf x >> "$FM_TEST_OD_COUNT"\nexec /usr/bin/od "$@"\n' > "$dir/shim/od"
chmod +x "$dir/shim/od"
export FM_HOME="$dir/home" PATH="$dir/shim:/bin:/usr/bin:$PATH"
python3 - "$dir" "$SELF_REVIEW_CHECK" "$EVIDENCE" <<'PY'
import os,pathlib,subprocess,sys,time
D,C,E=map(pathlib.Path,sys.argv[1:])
lines=['31 changed paths; linear regression budget: 30 * 6 + 100 = 280 od invocations.']
counts=[]
for name,checker in [('original',D/'original/fm-pr-self-review-check.sh'),('optimized',C)]:
    counter=D/(name+'-od-count')
    start=time.monotonic()
    r=subprocess.run(['/bin/bash',str(checker),'task-a','no-mistakes'],env=dict(os.environ,FM_TEST_OD_COUNT=str(counter)),text=True,capture_output=True,timeout=180)
    calls=counter.stat().st_size
    counts.append(calls)
    lines.append(f'{name}: exit={r.returncode}; elapsed={time.monotonic()-start:.3f}s; od calls={calls}; output={r.stdout.strip() or r.stderr.strip()}')
    assert r.returncode==0
assert counts[0]>280 and counts[1]<=280,counts
(E/'baseline-performance.txt').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))
PY
