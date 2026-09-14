#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-procevent-review)
python3 - "$ROOT" "$TMP_ROOT" "$(command -v python3)" "$(command -v ps)" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root, temp, python, real_ps = sys.argv[1:]
base = Path(temp)
owner = str(Path(root) / "bin/fm-launch-record.py")
entry = str(Path(root) / "bin/fm-procevent.sh")
children = []
homes = []


def wait_for(predicate, message):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(message)


def fixture(name):
    home = base / name
    homes.append(home)
    for dirname in ("state", "claims", "fakebin", "no-proc"):
        (home / dirname).mkdir(parents=True, mode=0o700)
    (home / "fakebin/ps").write_text('''#!/usr/bin/env bash
if [ -f "$FM_TEST_HOME/fail-pid" ] && [ "$*" = "-p $(cat "$FM_TEST_HOME/fail-pid") -o lstart= -o command=" ]; then
  printf 'identity-read-refused\\n' >> "$FM_TEST_HOME/faults"
  exit 1
fi
exec "$FM_TEST_REAL_PS" "$@"
''')
    (home / "fakebin/python-record").write_text('''#!/usr/bin/env bash
if [ -f "$FM_TEST_HOME/fail-hash" ] && [ "${1:-}" = -c ]; then
  printf 'digest-refused\\n' >> "$FM_TEST_HOME/faults"
  exit 1
fi
for arg in "$@"; do
  if [ "$arg" = created ] && [ -f "$FM_TEST_HOME/fail-created" ]; then
    printf 'created-refused\\n' >> "$FM_TEST_HOME/faults"
    exit 1
  fi
done
exec "$FM_TEST_REAL_PYTHON" "$@"
''')
    for script in ("ps", "python-record"):
        (home / "fakebin" / script).chmod(0o700)
    (home / "poll.py").write_text('''import pathlib, sys, time
home = pathlib.Path(sys.argv[1])
with (home / "polls").open("a") as out:
    out.write("started\\n")
while not (home / "release").exists():
    time.sleep(0.05)
print("fixture payload")
''')
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=root,
               FM_STATE_OVERRIDE=str(home / "state"), FM_PROCEVENT_CLAIM_ROOT=str(home / "claims"),
               FM_PROC_ROOT_OVERRIDE=str(home / "no-proc"), FM_TEST_HOME=str(home),
               FM_TEST_REAL_PS=real_ps, FM_TEST_REAL_PYTHON=python,
               FM_LAUNCH_RECORD_PYTHON=str(home / "fakebin/python-record"),
               PATH=str(home / "fakebin") + os.pathsep + os.environ["PATH"])
    result = invoke(env, "register", "lavish", name, "--", python, str(home / "poll.py"), str(home))
    assert result.returncode == 0, result.stderr
    return home, env


def invoke(env, *args):
    return subprocess.run([entry, *args], env=env, text=True, capture_output=True, timeout=15)


def record_path(home):
    paths = list((home / "state").glob(".launch-procevent-*"))
    paths = [p for p in paths if not p.name.endswith(".lock")]
    assert len(paths) == 1, paths
    return paths[0]


def launch(home):
    return json.loads(record_path(home).read_text())["launch"]


def start(home, env, name):
    stream = (home / "start-output").open("w")
    process = subprocess.Popen([entry, "start", name], env=env, stdout=stream, stderr=stream)
    stream.close()
    children.append(process)
    return process


try:
    home, env = fixture("live-reader-fault")
    process = start(home, env, "live-reader-fault")
    wait_for(lambda: (home / "polls").exists(), "first runner did not begin polling")
    original = launch(home)
    assert original["phase"] == "ready", original
    pid = original["identity"]["pid"]
    claim = home / "claims/live-reader-fault.claim"
    before_record = record_path(home).read_bytes()
    before_claim = claim.read_bytes()
    for failure in ("fail-pid", "fail-hash"):
        (home / failure).write_text(str(pid))
        result = invoke(env, "start", "live-reader-fault")
        assert result.returncode != 0, result
        assert "identity" in result.stderr, result.stderr
        assert record_path(home).read_bytes() == before_record, launch(home)
        assert claim.read_bytes() == before_claim
        assert process.poll() is None, process.returncode
        assert (home / "polls").read_text().splitlines() == ["started"]
        (home / failure).unlink()
    assert (home / "faults").read_text().splitlines() == ["identity-read-refused", "digest-refused"]
    result = invoke(env, "start", "live-reader-fault")
    assert result.returncode == 0 and "already owned" in result.stdout, result
    (home / "release").touch()
    process.wait(timeout=15)
    print("ok - live runner identity read and digest failures preserve its launch and claim")

    name = "missing-recorded-digest"
    home, env = fixture(name)
    sleeper = subprocess.Popen(["sleep", "300"])
    children.append(sleeper)
    checksum = subprocess.run(["cksum"], input=name, text=True, capture_output=True, check=True).stdout.split()[0]
    subject = "procevent-" + name + "-" + checksum
    common = [python, owner, "--state", str(home / "state")]
    result = subprocess.run(common + ["intend", "--helper", subject, "--owner", "fm-procevent.sh", "--origin", "wait"],
                            text=True, capture_output=True, check=True)
    old = result.stdout.strip().split("launch=")[1]
    subprocess.run(common + ["created", "--helper", subject, "--launch", old, "--identity-source", "process",
                             "--identity", "pid=" + str(sleeper.pid)], check=True, capture_output=True)
    before_record = record_path(home).read_bytes()
    result = invoke(env, "start", name)
    assert result.returncode != 0 and "incomplete process identity" in result.stderr, result
    assert record_path(home).read_bytes() == before_record
    assert not (home / "polls").exists()
    assert sleeper.poll() is None
    sleeper.terminate()
    sleeper.wait(timeout=15)
    print("ok - a recorded PID without its start digest remains an unresolved predecessor")

    for failure in ("fail-hash", "fail-created"):
        name = "new-" + failure
        home, env = fixture(name)
        (home / failure).touch()
        process = start(home, env, name)
        wait_for(lambda: process.poll() is not None or (home / "polls").exists(),
                 "identity publication failure neither refused nor started")
        assert not (home / "polls").exists(), "source polled without durable complete identity"
        assert process.wait(timeout=15) != 0
        current = launch(home)
        assert current["phase"] == "failed", current
        assert current["outcome"]["effect"] == "none", current
        assert not current.get("identity"), current
        assert not current.get("readiness"), current
        assert not (home / "claims" / (name + ".claim")).exists()
        assert "refusing to poll" in (home / "start-output").read_text()
        assert (home / "faults").read_text().strip()
        (home / failure).unlink()
        process = start(home, env, name)
        wait_for(lambda: (home / "polls").exists(), "source did not recover after identity publication fault")
        claim_identity = (home / "claims" / (name + ".claim")).read_text().splitlines()[3]
        assert launch(home)["identity"]["pid_identity_sha256"] == hashlib.sha256(claim_identity.encode()).hexdigest()
        (home / "release").touch()
        process.wait(timeout=15)
    print("ok - missing digest or refused identity publication releases only the new claim and prevents polling")
finally:
    for home in homes:
        (home / "release").touch()
    for process in children:
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=15)
PY
