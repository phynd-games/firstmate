import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path.cwd()
evidence = Path(__file__).resolve().parent
lines = [
    'Public interface: bin/fm-harness.sh',
    'Target: 71118e32513760209cc8f9be2e7a987053331db7',
    'Purpose: verify the existing two-tier detection described by the edited instructions.',
    'Controlled process fixtures below replace ps only; the real detector is executed.',
    'These checks do not establish agent interpretation, publication, merge, or end-to-end goal completion.',
]
markers = ['CURSOR_AGENT', 'CURSOR_INVOKED_AS', 'CLAUDECODE', 'PI_CODING_AGENT', 'FM_PI_HARNESS', 'GROK_AGENT']
with tempfile.TemporaryDirectory(prefix='detection-fixture-', dir=evidence) as temporary:
    fixture = Path(temporary)
    ps = fixture / 'ps'
    ps.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$DETECTION_PS_LOG"
case "$*" in
  *comm=*)
    case "$*" in
      *424242*) printf '%s\\n' "$DETECTION_PARENT" ;;
      *) printf '%s\\n' bash ;;
    esac ;;
  *ppid=*)
    case "$*" in
      *424242*) printf '%s\\n' 1 ;;
      *) printf '%s\\n' 424242 ;;
    esac ;;
  *) exit 1 ;;
esac
''')
    ps.chmod(0o700)
    cases = [
        ('verified environment marker bypasses ancestry', {'CLAUDECODE': '1'}, 'codex', 'claude', False),
        ('Cursor marker outranks inherited Claude marker', {'CURSOR_AGENT': '1', 'CLAUDECODE': '1'}, 'bash', 'cursor', False),
        ('without markers, verified parent identifies Codex', {}, 'codex', 'codex', True),
        ('without markers or verified ancestry, return unknown', {}, 'bash', 'unknown', True),
        ('unrecognized marker does not establish identity', {'CURSOR_INVOKED_AS': 'unverified-runtime'}, 'bash', 'unknown', True),
    ]
    for name, values, parent, expected, ancestry in cases:
        env = {k:v for k,v in os.environ.items() if k not in markers}
        log = fixture / 'ps.log'
        log.write_text('')
        env.update(PATH=str(fixture) + ':/usr/bin:/bin:/usr/sbin:/sbin',
                   DETECTION_PS_LOG=str(log), DETECTION_PARENT=parent,
                   FM_PROC_ROOT_OVERRIDE=str(fixture / 'absent-proc'))
        env.update(values)
        result = subprocess.run(['bash', 'bin/fm-harness.sh'], cwd=root, env=env, text=True, capture_output=True, timeout=10)
        calls = log.read_text().splitlines()
        lines.extend(['', name, 'Input markers: ' + json.dumps(values), 'Parent fixture: ' + parent,
                      '$ bash bin/fm-harness.sh', result.stdout.strip(),
                      'Exit: ' + str(result.returncode), 'Ancestry observations: ' + json.dumps(calls)])
        assert result.returncode == 0 and result.stdout.strip() == expected, result
        assert bool(calls) == ancestry, calls
        if ancestry:
            assert any('424242' in call and 'comm=' in call for call in calls), calls
    actual = subprocess.run(['bash', 'bin/fm-harness.sh'], cwd=root, text=True, capture_output=True, timeout=10)
    lines.extend(['', 'Ambient session, real environment and real ps:', '$ bash bin/fm-harness.sh', actual.stdout.strip(), 'Exit: ' + str(actual.returncode)])
    assert actual.returncode == 0
output = '\n'.join(lines) + '\n'
(evidence / 'detection-transcript.txt').write_text(output)
print(output)
