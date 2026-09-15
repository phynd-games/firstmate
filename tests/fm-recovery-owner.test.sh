#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-recovery-owner)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import configparser
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import time

root, tmp = map(Path, sys.argv[1:])
checkout = tmp / 'checkout & space % $d "quoted"'
script_dir = checkout / 'bin'
script_dir.mkdir(parents=True)
for name in ('fm-recovery-owner.sh', 'fm-wake-lib.sh', 'fm-session-lock-lib.sh', 'fm-cursor-lib.sh', 'fm-harness.sh'):
    shutil.copy2(root / 'bin' / name, script_dir / name)
script = script_dir / 'fm-recovery-owner.sh'
fakebin = tmp / 'fakebin'
fakebin.mkdir()
user_home = tmp / 'user'
user_home.mkdir()
home = tmp / 'home & space % $d "quoted"'
home.mkdir()
env = dict(os.environ, HOME=str(user_home), FM_HOME=str(home),
           PATH=str(fakebin) + ':' + os.environ['PATH'], FM_RECOVERY_OWNER_INTERVAL='1',
           FM_RECOVERY_OWNER_STOP_TIMEOUT='3', FM_STATE_OVERRIDE=str(home / 'state'))
for key in ('FM_ROOT_OVERRIDE', 'FM_WAKE_QUEUE', 'FM_WAKE_QUEUE_LOCK', 'FM_SUPERVISION_MODEL',
            'CLAUDECODE', 'CURSOR_AGENT', 'CURSOR_INVOKED_AS', 'GROK_AGENT', 'FM_PI_HARNESS'):
    env.pop(key, None)
env.update(PI_CODING_AGENT='true', HERDR_SESSION='recovery-lab')

def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)

executable(fakebin / 'herdr', '#!/bin/sh\nexit 0\n')
executable(fakebin / 'supervisor', '#!/bin/sh\ncommand -v herdr > "$FM_HOME/ensured"\n')
env['FM_HERDR_SUPERVISOR_BIN'] = str(fakebin / 'supervisor')
executable(fakebin / 'manager', '''#!/bin/sh
printf '%s\\n' "$*" >> "$HOME/manager.log"
case "$*" in
  unload*|*'disable --now'*) [ "${FAIL_UNLOAD:-0}" != 1 ] || exit 7 ;;
esac
''')
env['FM_SYSTEMCTL'] = env['FM_LAUNCHCTL'] = str(fakebin / 'manager')
real_uname = shutil.which('uname')
executable(fakebin / 'uname', f'#!/bin/sh\nif [ "$1" = -s ] && [ -n "$TEST_PLATFORM" ]; then printf "%s\\n" "$TEST_PLATFORM"; else exec {shlex.quote(real_uname)} "$@"; fi\n')

def run(command, overrides=None, check=True):
    result = subprocess.run([str(script), command], env=dict(env, **(overrides or {})),
                            capture_output=True, text=True, timeout=15)
    if check:
        assert result.returncode == 0, result.stderr + result.stdout
    return result

def until(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('timed out waiting for fixture transition')

def record():
    try:
        return dict(line.split('=', 1) for line in (home / 'state/.recovery-owner').read_text().splitlines())
    except FileNotFoundError:
        return {}

def uninstall_with_retry(platform, definition):
    before = definition.read_bytes()
    result = run('uninstall', {'TEST_PLATFORM': platform, 'FAIL_UNLOAD': '1'}, check=False)
    assert result.returncode != 0
    assert definition.read_bytes() == before
    assert 'retained' in result.stderr
    failed_call = (user_home / 'manager.log').read_text().splitlines()[-1]
    run('uninstall', {'TEST_PLATFORM': platform})
    assert not definition.exists()
    calls = (user_home / 'manager.log').read_text().splitlines()
    assert calls.count(failed_call) == 2


def exercise_service_context(argv, variables):
    assert variables['FM_SUPERVISION_MODEL'] == 'extension'
    assert variables['HERDR_SESSION'] == 'recovery-lab'
    config = home / 'config'
    config.mkdir(exist_ok=True)
    (config / 'backend').write_text('herdr\n')
    task = home / 'state/context.meta'
    task.write_text('kind=ship\n')
    alarm = home / 'state/.herdr-supervisor-alarm'
    alarm.unlink(missing_ok=True)
    calls = home / 'herdr-calls'
    calls.unlink(missing_ok=True)
    saved_herdr = (fakebin / 'herdr').read_text()
    executable(fakebin / 'herdr', '''#!/bin/sh
printf '%s\\t%s\\n' "$HERDR_SESSION" "$*" >> "$FM_HOME/herdr-calls"
case "$*" in
  *'status --json'*) printf '%s\\n' '{"client":{"version":"0.8.2","protocol":16},"server":{"running":false,"status":"stopped","compatible":true,"protocol":16}}' ;;
  *) exit 1 ;;
esac
''')
    service_env = dict(HOME=str(user_home), TMPDIR=os.environ.get('TMPDIR', '/tmp'),
                       FM_HERDR_SUPERVISOR_BIN=str(root / 'bin/fm-herdr-supervisor.sh'),
                       FM_RECOVERY_OWNER_INTERVAL='1', FM_RECOVERY_OWNER_STOP_TIMEOUT='5')
    service_env.update(variables)
    service = subprocess.Popen(argv, env=service_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    children.append(service)
    try:
        until(alarm.exists)
        assert "session 'recovery-lab' has no running server" in alarm.read_text(), alarm.read_text()
        run('stop')
        service.wait(timeout=10)
        observed = [line.split('\t', 1) for line in calls.read_text().splitlines()]
        assert observed
        assert all(session == 'recovery-lab' and '--session recovery-lab' in args for session, args in observed), observed
        assert not (home / 'state/.herdr-supervisor').exists()
    finally:
        if service.poll() is None:
            service.kill()
        service.wait(timeout=5)
        task.unlink()
        executable(fakebin / 'herdr', saved_herdr)


children = []
try:
    children = [subprocess.Popen([str(script), 'run'], env=env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL) for _ in range(4)]
    until(lambda: record().get('pid') and (home / 'ensured').exists())
    until(lambda: sum(p.poll() is None for p in children) == 1)
    owner = next(p for p in children if p.poll() is None)
    first = record()
    assert int(first['pid']) == owner.pid
    run('start')
    assert record() == first
    run('run', check=False)
    assert record() == first
    print('ok - concurrent run and start retain one owning generation', flush=True)

    sleep_bin = shutil.which('sleep')
    executable(fakebin / 'sleep', f'''#!/bin/sh
if [ -n "$STOP_PAUSE" ]; then
  touch "$STOP_PAUSE"
  while [ ! -f "$STOP_RELEASE" ]; do {shlex.quote(sleep_bin)} 0.05; done
fi
exec {shlex.quote(sleep_bin)} "$@"
''')
    owner.send_signal(signal.SIGSTOP)
    pause, release = tmp / 'stop-paused', tmp / 'stop-release'
    stopper = subprocess.Popen([str(script), 'stop'], env=dict(env, STOP_PAUSE=str(pause), STOP_RELEASE=str(release)),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    children.append(stopper)
    until(pause.exists)
    owner.kill()
    owner.wait(timeout=5)
    replacement = subprocess.Popen([str(script), 'run'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    children.append(replacement)
    until(lambda: record().get('pid') == str(replacement.pid))
    second = record()
    release.touch()
    assert stopper.wait(timeout=10) == 0
    assert record() == second and replacement.poll() is None
    assert second['generation'] != first['generation']
    run('stop')
    replacement.wait(timeout=5)
    assert not record()
    print('ok - a stale stop preserves the replacement generation', flush=True)

    run('install', {'TEST_PLATFORM': 'Darwin'})
    plist_path, = (user_home / 'Library/LaunchAgents').glob('*.plist')
    plist = plistlib.loads(plist_path.read_bytes())
    assert plist['ProgramArguments'] == [str(script), 'run']
    assert plist['EnvironmentVariables']['FM_HOME'] == str(home)
    assert plist['StandardOutPath'] == str(home / 'state/.recovery-owner.log')
    assert '/opt/homebrew/bin' in plist['EnvironmentVariables']['PATH'].split(':')
    (home / 'ensured').unlink()
    service_env = dict(env, PATH='/usr/bin:/bin')
    service_env.update(plist['EnvironmentVariables'])
    service = subprocess.Popen(plist['ProgramArguments'], env=service_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    children.append(service)
    until(lambda: (home / 'ensured').exists())
    run('stop')
    service.wait(timeout=5)
    exercise_service_context(plist['ProgramArguments'], plist['EnvironmentVariables'])
    uninstall_with_retry('Darwin', plist_path)
    print('ok - launchd plist round-trips special paths and supplies the supervisor PATH', flush=True)

    launch_dir = user_home / 'Library/LaunchAgents'
    collision_homes = [tmp / 'a-b', tmp / 'a/b']
    for collision_home in collision_homes:
        collision_home.mkdir(parents=True)
        run('install', {'TEST_PLATFORM': 'Darwin', 'FM_HOME': str(collision_home),
                        'FM_STATE_OVERRIDE': str(collision_home / 'state')})
    agents = {plistlib.loads(path.read_bytes())['EnvironmentVariables']['FM_HOME']: path
              for path in launch_dir.glob('*.plist')}
    assert set(agents) == {str(path) for path in collision_homes}
    labels = [plistlib.loads(path.read_bytes())['Label'] for path in agents.values()]
    assert len(set(labels)) == 2
    mac_alias = tmp / 'mac-home-alias'
    mac_alias.symlink_to(collision_homes[0])
    run('install', {'TEST_PLATFORM': 'Darwin', 'FM_HOME': str(mac_alias),
                    'FM_STATE_OVERRIDE': str(collision_homes[0] / 'state')})
    assert len(list(launch_dir.glob('*.plist'))) == 2
    run('uninstall', {'TEST_PLATFORM': 'Darwin', 'FM_HOME': str(mac_alias),
                      'FM_STATE_OVERRIDE': str(collision_homes[0] / 'state')})
    remaining_agent, = launch_dir.glob('*.plist')
    assert remaining_agent == agents[str(collision_homes[1])]
    assert 'unload ' + str(agents[str(collision_homes[0])]) in (user_home / 'manager.log').read_text().splitlines()
    print('ok - launchd names isolate formerly colliding homes and canonicalize aliases', flush=True)

    run('install', {'TEST_PLATFORM': 'Linux'})
    unit_dir = user_home / '.config/systemd/user'
    unit, = unit_dir.glob('*.service')
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.read(unit)
    service_lines = unit.read_text().splitlines()
    assignments = [shlex.split(line.split('=', 1)[1])[0].replace('%%', '%')
                   for line in service_lines if line.startswith('Environment=')]
    normalized_env = dict(item.split('=', 1) for item in assignments)
    assert normalized_env['FM_HOME'] == str(home)
    assert str(fakebin) in normalized_env['PATH'].split(':')
    argv = shlex.split(parser['Service']['ExecStart'].replace('%%', '%'))
    assert argv == [str(script), 'run'], argv
    assert parser['Service']['Restart'] == 'on-failure'
    exercise_service_context(argv, normalized_env)
    print('ok - both service environments preserve Pi eligibility and the named Herdr session', flush=True)
    home2 = tmp / 'home-other'
    home2.mkdir()
    run('install', {'TEST_PLATFORM': 'Linux', 'FM_HOME': str(home2), 'FM_STATE_OVERRIDE': str(home2 / 'state')})
    assert len(list(unit_dir.glob('*.service'))) == 2
    alias = tmp / 'home-alias'
    alias.symlink_to(home)
    run('install', {'TEST_PLATFORM': 'Linux', 'FM_HOME': str(alias)})
    assert len(list(unit_dir.glob('*.service'))) == 2
    uninstall_with_retry('Linux', unit)
    print('ok - unload failures retain service definitions and permit retries on both platforms', flush=True)
    remaining, = unit_dir.glob('*.service')
    assert remaining != unit
    manager_calls = (user_home / 'manager.log').read_text().splitlines()
    assert '--user enable --now ' + unit.name in manager_calls
    assert '--user disable --now ' + unit.name in manager_calls
    print('ok - systemd units escape paths and isolate canonical homes', flush=True)
    for platform in ('Darwin', 'Linux'):
        for model in ('autoarm', 'persistent'):
            run('install', {'TEST_PLATFORM': platform, 'FM_SUPERVISION_MODEL': model, 'HERDR_SESSION': ''})
            if platform == 'Darwin':
                definitions = [plistlib.loads(path.read_bytes()) for path in launch_dir.glob('*.plist')]
                variables, = [item['EnvironmentVariables'] for item in definitions
                              if item['EnvironmentVariables']['FM_HOME'] == str(home)]
            else:
                assignments = [shlex.split(line.split('=', 1)[1])[0].replace('%%', '%')
                               for line in unit.read_text().splitlines() if line.startswith('Environment=')]
                variables = dict(item.split('=', 1) for item in assignments)
            assert variables['FM_SUPERVISION_MODEL'] == model
            assert variables['HERDR_SESSION'] == 'default'
            run('uninstall', {'TEST_PLATFORM': platform})
    print('ok - explicit supervision models and default session selection survive installation', flush=True)

finally:
    for child in children:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=5)
PY
