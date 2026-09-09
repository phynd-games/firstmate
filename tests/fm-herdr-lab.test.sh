#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
#
# Every case runs against fake CLI responses and a private state directory.
# The fake server is long-lived like the real one (it execs into sleep after
# recording its own pid), and the fake session stop terminates that recorded
# fixture process unless a case keeps it alive to exercise reconciliation.
# The only real processes are fixture processes whose pids are captured before
# any helper call could signal them (at most four per case): the fake server
# itself, an in-group child, a detached child, and an unrelated process.
# Every fixture is registered with the identity captured when it was actually
# launched (the fake server records its own pid and birth before exec, the
# fake records each child's birth while that child is still its own live,
# unreaped child, and the test records its unrelated process the same way),
# never with a fresh lookup of a historical pid. Every fixture signal
# (cleanup, reaping, and the fake session stop) rechecks that identity first;
# a reused pid is reported and left alone, an unreadable process table is
# unknown and never absence, a failed kill is reported as failed, and an
# attempted signal is never taken as proof of exit. When any fixture ends
# unknown, reused, still live, or unsignaled, the test keeps its private
# fixture directory as evidence instead of deleting it. On Darwin the window
# between the identity read and the signal that follows it is unavoidable.
# Every helper invocation runs with a private HOME, FM_HOME, XDG_*, and TMPDIR
# under the test root in addition to the fake PATH and private state dir.
# A ps shim on the fake PATH passes through untouched unless a case asks it to
# hang or to rewrite one pid's birth time, which is how pid reuse and an
# unreadable process table are simulated without touching any real process.
set -u
umask 077

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
FAKE_TLOG="$TMP_ROOT/herdr-timing.log"
TRIPWIRES="$TMP_ROOT/tripwires"
PS_COUNTER="$TMP_ROOT/ps.counter"
REAL_SLEEP=$(command -v sleep)
REAL_PS=$(command -v ps)
REAL_PYTHON=$(command -v python3)
REAL_MV=$(command -v mv)
FIXTURES=()
PRIVATE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_STATE" "$PRIVATE_HOME/fm-home" "$PRIVATE_HOME/xdg-config" "$PRIVATE_HOME/xdg-state" "$PRIVATE_HOME/xdg-cache" "$PRIVATE_HOME/xdg-data" "$PRIVATE_HOME/xdg-runtime" "$PRIVATE_HOME/tmp"
chmod 700 "$PRIVATE_HOME/xdg-runtime"
printf '%s\n' "$TMP_ROOT/default.sock" > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"
: > "$FAKE_TLOG"
python3 -c 'import os, socket, sys
os.chdir(os.path.dirname(sys.argv[1]))
s = socket.socket(socket.AF_UNIX)
s.bind(os.path.basename(sys.argv[1]))' "$TMP_ROOT/default.sock"

# Mark this run's private fixture directory as evidence that must survive
# cleanup, naming why. Called on every path where a process identity is
# unknown, reused, invalid, unsignaled, or still live, BEFORE the assertion
# that ends the case, so an early failure can never reach cleanup with an
# empty registry and delete what it promised to keep.
EVIDENCE_RETAINED=0
retain_evidence() { # <reason>
  EVIDENCE_RETAINED=1
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$TMP_ROOT/RETAINED"
}

# A fixture identity is a pid of one or more digits (never 0) plus a
# non-empty launch birth; anything else is refused without probing.
fixture_identity_valid() { # <pid> <launch-birth>
  case "${1:-}" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "${2:-}" ]
}

# Normalize one ps lstart line to the dash-joined form the helper records.
birth_normalize() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/-/g'
}

# Exec-stable birth of a pid via the real ps. Exit 0 with the birth on stdout
# when present, 3 when ps positively found nothing (its exit 1 with no
# output), and 1 when the inspection itself failed - unknown, never absence.
fixture_birth() { # <pid>
  local pid=$1 out rc=0 wday mon day clock year state
  case "${pid:-}" in ''|*[!0-9]*|0) return 1 ;; esac
  out=$(LC_ALL=C "$REAL_PS" -p "$pid" -o lstart= -o stat= 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    read -r wday mon day clock year state <<< "$out"
    case "$state" in Z*) return 3 ;; esac
    [ -n "$year" ] && [ -n "$state" ] || return 1
    printf '%s-%s-%s-%s-%s\n' "$wday" "$mon" "$day" "$clock" "$year"
    return 0
  fi
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
    return 3
  fi
  return 1
}

# Register a fixture by the pid AND birth captured at its actual launch (the
# fake server's own record, a child's birth read by its parent while it was
# still that parent's live child, or the receipt the helper authenticated).
# A fresh lookup is never accepted as ownership: it verifies only that the
# launch-time identity is still what is live, and refuses otherwise.
fixture_register() { # <pid> <launch-birth>
  local pid=$1 launch_birth=$2 current rc=0 entry
  fixture_identity_valid "$pid" "$launch_birth" || {
    retain_evidence "registration refused: invalid identity pid='${pid:-}' birth='${launch_birth:-}'"
    fail "fixture identity pid='${pid:-}' birth='${launch_birth:-}' is invalid; refusing to invent ownership"
  }
  current=$(fixture_birth "$pid") || rc=$?
  case "$rc" in
    0)
      [ "$current" = "$launch_birth" ] || {
        retain_evidence "registration refused: pid $pid reused (launch $launch_birth, current $current)"
        fail "fixture pid $pid is now a different process (launch $launch_birth, current $current); refusing to adopt it"
      }
      ;;
    3)
      retain_evidence "registration refused: pid $pid positively absent"
      fail "fixture $pid is positively absent at registration"
      ;;
    *)
      retain_evidence "registration refused: pid $pid unknown (inspection failed)"
      fail "fixture $pid could not be inspected at registration; unknown, not adopted"
      ;;
  esac
  for entry in "${FIXTURES[@]:-}"; do [ "$entry" != "$pid|$launch_birth" ] || return 0; done
  FIXTURES+=("$pid|$launch_birth")
}

# Signal one registered fixture only after its launch-time identity still
# matches. Prints the truthful outcome and exits 0 only when the signal was
# actually delivered or the pid was positively absent; identity change,
# unknown inspection, and a failed kill all exit non-zero. A delivered signal
# is not proof of exit: see fixture_wait_absent.
fixture_signal() { # <pid> <launch-birth> <signal>
  local pid=$1 recorded=$2 signal=$3 current rc=0
  fixture_identity_valid "$pid" "$recorded" || { printf 'invalid fixture identity'; return 1; }
  current=$(fixture_birth "$pid") || rc=$?
  case "$rc" in
    3) printf 'fixture %s positively absent\n' "$pid"; return 0 ;;
    0) ;;
    *) printf 'fixture %s unknown (inspection failed); not signaled\n' "$pid"; return 1 ;;
  esac
  if [ "$current" != "$recorded" ]; then
    printf 'fixture pid %s reused (launch %s, current %s); not signaled\n' "$pid" "$recorded" "$current"
    return 1
  fi
  if kill -"$signal" "$pid" 2>/dev/null; then
    printf 'fixture %s SIG%s delivered\n' "$pid" "$signal"
    return 0
  fi
  printf 'fixture %s SIG%s NOT delivered (kill failed)\n' "$pid" "$signal"
  return 1
}

# Poll for positive absence of a fixture for up to about one second. Exit 0
# only on observed absence, 2 when it is still live, 1 when unknown.
fixture_wait_absent() { # <pid>
  local pid=$1 attempt=0 rc
  while [ "$attempt" -lt 20 ]; do
    rc=0
    fixture_birth "$pid" >/dev/null || rc=$?
    case "$rc" in
      3) return 0 ;;
      0) ;;
      *) return 1 ;;
    esac
    "$REAL_SLEEP" 0.05
    attempt=$((attempt + 1))
  done
  return 2
}

# owned | absent | reused | unknown | invalid for a launch-time identity,
# read-only; an invalid identity is refused, never probed.
fixture_state() { # <pid> <launch-birth>
  local pid=$1 launch_birth=$2 current rc=0
  fixture_identity_valid "$pid" "$launch_birth" || { printf 'invalid'; return 0; }
  current=$(fixture_birth "$pid") || rc=$?
  case "$rc" in
    3) printf 'absent' ;;
    0) if [ "$current" = "$launch_birth" ]; then printf 'owned'; else printf 'reused'; fi ;;
    *) printf 'unknown' ;;
  esac
}

# Settle a launched-but-unregistered server after an error path: absent is
# the only clean outcome; owned is registered so cleanup owns it and the case
# fails; anything else retains evidence and fails without signaling.
settle_launched() { # <label> <pid> <launch-birth>
  local label=$1 pid=$2 launch_birth=$3 state
  state=$(fixture_state "$pid" "$launch_birth")
  case "$state" in
    absent) return 0 ;;
    owned)
      retain_evidence "$label left server $pid alive"
      fixture_register "$pid" "$launch_birth"
      fail "$label left server $pid alive"
      ;;
    *)
      retain_evidence "$label: server pid='${pid:-}' birth='${launch_birth:-}' is $state; not signaled"
      fail "$label server pid='${pid:-}' is $state; not adopted, evidence retained"
      ;;
  esac
}

# Cleanup: signal every registered fixture after its identity recheck and
# wait for observed absence. If any fixture is unknown, reused, unsignaled, or
# still live afterwards, the private fixture directory is RETAINED as evidence
# and the test exits non-zero instead of claiming a clean run.
fm_lab_test_cleanup() {
  local initial_status=$? entry pid retained=0 outcome record launch_birth found
  [ "$initial_status" -eq 0 ] || retain_evidence "test exited $initial_status; launch records retained"
  for record in "$FAKE_STATE"/*.launched "$FAKE_STATE"/*.child "$FAKE_STATE"/*.detached "$FAKE_STATE"/*.delay; do
    [ -f "$record" ] || continue
    pid= launch_birth=
    read -r pid launch_birth < "$record" || true
    if fixture_identity_valid "$pid" "$launch_birth"; then
      found=0
      for entry in "${FIXTURES[@]:-}"; do [ "$entry" != "$pid|$launch_birth" ] || found=1; done
      [ "$found" -eq 1 ] || FIXTURES+=("$pid|$launch_birth")
    else
      retain_evidence "invalid launch record $record"
    fi
  done
  for record in "$TRIPWIRES"/*.allocation.json "$TRIPWIRES"/*.allocation.json.pending; do
    [ -f "$record" ] || continue
    pid=$(jq -r '.pid // .rejected_observation.pid // empty' "$record") || pid=
    if [ -z "$pid" ] || [ ! -s "$FAKE_STATE/$pid.launched" ]; then
      retain_evidence "allocation lacks an accountable fixture launch: $record pid=$pid"
    fi
  done
  for entry in "${FIXTURES[@]:-}"; do
    [ -n "$entry" ] || continue
    pid=${entry%%|*}
    if ! outcome=$(fixture_signal "$pid" "${entry#*|}" KILL); then
      printf 'cleanup: %s\n' "$outcome" >&2
      retained=1
      continue
    fi
    printf 'cleanup: %s\n' "$outcome" >&2
    case "$(fixture_wait_absent "$pid"; printf '%s' "$?")" in
      0) printf 'cleanup: fixture %s observed absent\n' "$pid" >&2 ;;
      2) printf 'cleanup: fixture %s STILL LIVE after SIGKILL\n' "$pid" >&2; retained=1 ;;
      *) printf 'cleanup: fixture %s unknown after signal\n' "$pid" >&2; retained=1 ;;
    esac
  done
  if [ "$retained" -eq 1 ]; then
    retain_evidence "cleanup: a registered fixture was unknown, reused, unsignaled, or still live"
  fi
  if [ "$EVIDENCE_RETAINED" -eq 1 ] || [ -e "$TMP_ROOT/RETAINED" ]; then
    printf 'cleanup: evidence RETAINED in %s (%s)\n' "$TMP_ROOT" "$(tr '\n' ';' < "$TMP_ROOT/RETAINED" 2>/dev/null)" >&2
    exit 1
  fi
  if compgen -G "$TRIPWIRES/*.fleet-state.json" >/dev/null; then
    printf 'evidence: failed lifecycle records preserved in %s\n' "$TMP_ROOT" >&2
    return 0
  fi
  fm_test_cleanup
}
trap fm_lab_test_cleanup EXIT
trap 'fm_lab_test_cleanup; exit 130' INT
trap 'fm_lab_test_cleanup; exit 143' TERM

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
printf '%s %s\n' "$(date +%s)" "$*" >> "$FM_FAKE_HERDR_TLOG"
state=$FM_FAKE_HERDR_STATE
record_birth() {
  local pid=$1 out rc=0
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  out=$(LC_ALL=C "$FM_FAKE_PS_REAL" -p "$pid" -o lstart= 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/-/g'
}
record_launch() {
  local pid=$1 path=$2 birth
  if ! birth=$(record_birth "$pid"); then
    printf 'launch identity unknown pid %s\n' "$pid" >> "$FM_FAKE_ROOT/RETAINED"
    return 1
  fi
  printf '%s %s\n' "$pid" "$birth" > "$path"
  printf '%s %s\n' "$pid" "$birth" > "$state/$pid.launched"
}
last=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
session=$last
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")
if [ -n "${FM_FAKE_HERDR_HANG:-}" ] && [ "$FM_FAKE_HERDR_HANG" = "$1 ${2:-}" ]; then
  "$FM_FAKE_HERDR_REAL_SLEEP" 300
fi

case "$1 ${2:-}" in
  "session list")
    if [ "${FM_FAKE_HERDR_SERVER_LINGER:-1}" != 0 ] && [ -f "$state/$session.server" ]; then
      read -r pid birth < "$state/$session.server"
      case "$pid" in ''|0|*[!0-9]*) exit 95 ;; esac
      [ -n "$birth" ] || exit 95
      rc=0
      out=$(LC_ALL=C "$FM_FAKE_PS_REAL" -p "$pid" -o stat= 2>/dev/null) || rc=$?
      if { [ "$rc" -eq 1 ] && [ -z "$out" ]; } || [[ "$out" =~ ^[[:space:]]*Z ]]; then
        if [ "$lab_state" = running ]; then lab_state=stopped; fi
      fi
    fi
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg socket "$default_socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "server --session")
    record_launch "$$" "$state/$session.launched"
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY" &
      delay=$!
      record_launch "$delay" "$state/$session.delay"
      wait "$delay"
    fi
    cp "$state/$session.launched" "$state/$session.server"
    if [ "${FM_FAKE_HERDR_SERVER_CHILDREN:-}" = 1 ]; then
      # Each child's birth is read by this parent while the child is its own
      # live, unreaped child, so the pid cannot have been reused yet.
      "$FM_FAKE_HERDR_REAL_SLEEP" 300 &
      child=$!
      record_launch "$child" "$state/$session.child"
      python3 -c 'import os, sys
os.setsid()
with open(sys.argv[1] + ".pid", "w") as handle:
    handle.write(str(os.getpid()))
os.execvp(sys.argv[2], sys.argv[2:])' "$state/$session.detached" "$FM_FAKE_HERDR_REAL_SLEEP" 300 &
      detached=$!
      record_launch "$detached" "$state/$session.detached"
      while [ ! -s "$state/$session.detached.pid" ]; do "$FM_FAKE_HERDR_REAL_SLEEP" 0.05; done
      [ "$(cat "$state/$session.detached.pid")" = "$detached" ] || exit 94
    fi
    printf '%s\n' running > "$state/$session"
    if [ "${FM_FAKE_HERDR_SERVER_IGNORE_TERM:-}" = 1 ]; then
      exec python3 -c 'import os, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: open(sys.argv[1], "w").close())
open(sys.argv[2], "w").close()
time.sleep(300)' "$state/$session.term" "$state/$session.term-ready"
    fi
    if [ "${FM_FAKE_HERDR_SERVER_LINGER:-1}" = 1 ]; then
      exec "$FM_FAKE_HERDR_REAL_SLEEP" 300
    fi
    ;;
  "status --json")
    if [ "${FM_FAKE_HERDR_SERVER_LINGER:-1}" = 0 ]; then
      read -r pid birth < "$state/$session.launched"
      case "$pid" in ''|0|*[!0-9]*) exit 95 ;; esac
      [ -n "$birth" ] || exit 95
      for ((i=0; i<40; i++)); do
        rc=0
        out=$(LC_ALL=C "$FM_FAKE_PS_REAL" -p "$pid" -o stat= 2>/dev/null) || rc=$?
        if { [ "$rc" -eq 1 ] && [ -z "$out" ]; } || [[ "$out" =~ ^[[:space:]]*Z ]]; then
          break
        fi
        "$FM_FAKE_HERDR_REAL_SLEEP" 0.01
      done
    fi
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    : > "$state/$session.stopped"
    # The fake stops only the exact server it started: same pid AND same birth.
    if [ "${FM_FAKE_HERDR_STOP_KEEPS_SERVER:-}" != 1 ] && [ -s "$state/$session.server" ]; then
      read -r server_pid server_birth < "$state/$session.server"
      case "$server_pid" in ''|0|*[!0-9]*) printf 'invalid stop identity\n' >> "$FM_FAKE_ROOT/RETAINED"; exit 95 ;; esac
      [ -n "$server_birth" ] || { printf 'empty stop birth\n' >> "$FM_FAKE_ROOT/RETAINED"; exit 95; }
      rc=0
      raw=$(LC_ALL=C "$FM_FAKE_PS_REAL" -p "$server_pid" -o lstart= 2>/dev/null) || rc=$?
      if [ "$rc" -eq 1 ] && [ -z "$raw" ]; then
        printf 'absent\n' > "$state/$session.stop"
      else
        current_birth=$(printf '%s\n' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/-/g')
        if [ "$rc" -ne 0 ] || [ "$current_birth" != "$server_birth" ]; then
          printf 'not-signaled\n' > "$state/$session.stop"
          printf 'stop pid %s unknown or reused\n' "$server_pid" >> "$FM_FAKE_ROOT/RETAINED"
          exit 95
        fi
        if ! kill -TERM "$server_pid" 2>/dev/null; then
          printf 'kill-failed\n' > "$state/$session.stop"
          printf 'stop signal not delivered pid %s\n' "$server_pid" >> "$FM_FAKE_ROOT/RETAINED"
          exit 95
        fi
        printf 'delivered\n' > "$state/$session.stop"
        gone=0
        for ((i=0; i<40; i++)); do
          rc=0
          out=$(LC_ALL=C "$FM_FAKE_PS_REAL" -p "$server_pid" -o stat= 2>/dev/null) || rc=$?
          if { [ "$rc" -eq 1 ] && [ -z "$out" ]; } || [[ "$out" =~ ^[[:space:]]*Z ]]; then gone=1; break; fi
          [ "$rc" -eq 0 ] || break
          "$FM_FAKE_HERDR_REAL_SLEEP" 0.01
        done
        if [ "$gone" -ne 1 ]; then
          printf 'stop exit unproved pid %s\n' "$server_pid" >> "$FM_FAKE_ROOT/RETAINED"
          exit 95
        fi
      fi
    fi
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
set -eu
if [[ "${3:-}" = *.allocation.setsid ]]; then
  raw=$(LC_ALL=C "$FM_FAKE_PS_REAL" -p "$$" -o lstart=) || {
    printf 'launcher identity unknown pid %s\n' "$$" >> "$FM_FAKE_ROOT/RETAINED"
    exit 95
  }
  birth=$(printf '%s\n' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/-/g')
  [ -n "$birth" ] || { printf 'empty launcher birth\n' >> "$FM_FAKE_ROOT/RETAINED"; exit 95; }
  printf '%s %s\n' "$$" "$birth" > "$FM_FAKE_HERDR_STATE/$$.launched"
  if [ -n "${FM_FAKE_LAUNCH_RECORD:-}" ]; then
    printf '%s %s\n' "$$" "$birth" > "$FM_FAKE_LAUNCH_RECORD"
  fi
fi
exec "$FM_FAKE_PYTHON_REAL" "$@"
SH
chmod +x "$FAKEBIN/python3"

cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_PUBLISH_FAIL:-}" = 1 ] && [[ "${2:-}" = *.allocation.json.pending ]]; then
  printf '%s\n' "$*" >> "$FM_FAKE_HERDR_STATE/publication-attempts"
  exit 96
fi
exec "$FM_FAKE_MV_REAL" "$@"
SH
chmod +x "$FAKEBIN/mv"

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
# Pass-through ps shim. FM_FAKE_PS_HANG=1 hangs every call; FM_FAKE_PS_MUTATE_PID
# rewrites the birth year of that pid's identity queries once more than
# FM_FAKE_PS_MUTATE_AFTER of them have been answered truthfully.
if [ "${FM_FAKE_PS_HANG:-}" = 1 ]; then
  "$FM_FAKE_HERDR_REAL_SLEEP" 300
fi
if [ "${FM_FAKE_PS_PARTIAL:-}" = 1 ]; then printf 'partial observation\n'; exit 1; fi
rc=0
out=$("$FM_FAKE_PS_REAL" "$@") || rc=$?
if [ -n "${FM_FAKE_REJECT_LAUNCH:-}" ] && [ -s "$FM_FAKE_LAUNCH_RECORD" ]; then
  read -r launcher birth < "$FM_FAKE_LAUNCH_RECORD"
  if [ "${1:-}" = -p ] && [ "${2:-}" = "$launcher" ]; then
    printf '%s\n' "$launcher" >> "$FM_FAKE_LAUNCH_RECORD.probes"
    if [ "$FM_FAKE_REJECT_LAUNCH" = parent ]; then
      out=$(printf '%s\n' "$out" | awk '{$6=1; print}')
    else
      out=$(printf '%s\n' "$out" | awk '{$5=1999; $6=1; print}')
    fi
  fi
fi
if [ -n "${FM_FAKE_PS_MUTATE_PID:-}" ]; then
  target=0
  previous=
  for arg in "$@"; do
    [ "$previous" = -p ] && [ "$arg" = "$FM_FAKE_PS_MUTATE_PID" ] && target=1
    previous=$arg
  done
  if [ "$target" -eq 1 ]; then
    count=$(cat "$FM_FAKE_PS_COUNTER" 2>/dev/null || printf 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_PS_COUNTER"
    if [ "$count" -gt "${FM_FAKE_PS_MUTATE_AFTER:-0}" ] && { [ -z "${FM_FAKE_PS_AFTER_TERM:-}" ] || [ -e "$FM_FAKE_PS_AFTER_TERM" ]; }; then
      out=$(printf '%s\n' "$out" | sed -E 's/([0-9]{2}:[0-9]{2}:[0-9]{2}) [0-9]{4}/\1 1999/')
    fi
  fi
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "$rc"
SH
chmod +x "$FAKEBIN/ps"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  local result=0
  HOME="$PRIVATE_HOME" \
    FM_HOME="$PRIVATE_HOME/fm-home" \
    XDG_CONFIG_HOME="$PRIVATE_HOME/xdg-config" \
    XDG_STATE_HOME="$PRIVATE_HOME/xdg-state" \
    XDG_CACHE_HOME="$PRIVATE_HOME/xdg-cache" \
    XDG_DATA_HOME="$PRIVATE_HOME/xdg-data" \
    XDG_RUNTIME_DIR="$PRIVATE_HOME/xdg-runtime" \
    TMPDIR="$PRIVATE_HOME/tmp" \
    PATH="$FAKEBIN:$PATH" \
    FM_FAKE_ROOT="$TMP_ROOT" \
    FM_FAKE_PYTHON_REAL="$REAL_PYTHON" \
    FM_FAKE_MV_REAL="$REAL_MV" \
    FM_FAKE_LAUNCH_RECORD="${FM_FAKE_LAUNCH_RECORD:-}" \
    FM_FAKE_REJECT_LAUNCH="${FM_FAKE_REJECT_LAUNCH:-}" \
    FM_FAKE_PUBLISH_FAIL="${FM_FAKE_PUBLISH_FAIL:-}" \
    FM_FAKE_PS_PARTIAL="${FM_FAKE_PS_PARTIAL:-}" \
    FM_FAKE_PS_AFTER_TERM="${FM_FAKE_PS_AFTER_TERM:-}" \
    FM_FAKE_HERDR_SERVER_IGNORE_TERM="${FM_FAKE_HERDR_SERVER_IGNORE_TERM:-}" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_TLOG="$FAKE_TLOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_SERVER_LINGER="${FM_FAKE_HERDR_SERVER_LINGER:-1}" \
    FM_FAKE_HERDR_STOP_KEEPS_SERVER="${FM_FAKE_HERDR_STOP_KEEPS_SERVER:-}" \
    FM_FAKE_HERDR_SERVER_CHILDREN="${FM_FAKE_HERDR_SERVER_CHILDREN:-}" \
    FM_FAKE_HERDR_HANG="${FM_FAKE_HERDR_HANG:-}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_FAKE_PS_REAL="$REAL_PS" \
    FM_FAKE_PS_COUNTER="$PS_COUNTER" \
    FM_FAKE_PS_HANG="${FM_FAKE_PS_HANG:-}" \
    FM_FAKE_PS_MUTATE_PID="${FM_FAKE_PS_MUTATE_PID:-}" \
    FM_FAKE_PS_MUTATE_AFTER="${FM_FAKE_PS_MUTATE_AFTER:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@" || result=$?
  account_launches || return 1
  return "$result"
}

account_launches() {
  local record pid birth entry found
  for record in "$FAKE_STATE"/*.launched "$FAKE_STATE"/*.child "$FAKE_STATE"/*.detached "$FAKE_STATE"/*.delay; do
    [ -f "$record" ] || continue
    pid= birth=
    read -r pid birth < "$record" || true
    fixture_identity_valid "$pid" "$birth" || { retain_evidence "invalid launch record $record"; return 1; }
    found=0
    for entry in "${FIXTURES[@]:-}"; do [ "$entry" != "$pid|$birth" ] || found=1; done
    [ "$found" -eq 0 ] || continue
    FIXTURES+=("$pid|$birth")
  done
}

evidence() {
  printf 'evidence: %s\n' "$*"
}

receipt_of() { # <session>
  printf '%s/%s.allocation.json' "$TRIPWIRES" "$1"
}

receipt_field() { # <session> <jq>
  jq -r "$2" "$(receipt_of "$1")"
}

pid_present() { # <pid>
  fixture_birth "$1" >/dev/null 2>&1
}

pid_birth() { # <pid>
  fixture_birth "$1"
}

pid_command() { # <pid>
  "$REAL_PS" -p "$1" -o command= | sed 's/^[[:space:]]*//'
}

# Kill one registered fixture after its identity recheck and forget it only
# once its absence is actually observed; anything else fails with the fixture
# still registered so cleanup retains the evidence.
reap_fixture() { # <pid>
  local pid=$1 remaining=() entry found=0 outcome
  for entry in "${FIXTURES[@]:-}"; do
    [ -n "$entry" ] || continue
    if [ "${entry%%|*}" = "$pid" ]; then
      found=1
      outcome=$(fixture_signal "$pid" "${entry#*|}" KILL) || {
        retain_evidence "reap refused: $outcome"
        fail "fixture $pid not reaped: $outcome"
      }
    else
      remaining+=("$entry")
    fi
  done
  [ "$found" -eq 1 ] || fail "fixture $pid was never registered"
  fixture_wait_absent "$pid" || {
    retain_evidence "reap unproved: fixture $pid not observed absent after SIGKILL (status $?)"
    fail "fixture $pid not observed absent after SIGKILL"
  }
  FIXTURES=("${remaining[@]:-}")
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line output allocated deadline
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"
  assert_present "$(receipt_of "$name")" "provision did not record an allocation receipt"
  allocated=$(receipt_field "$name" '.allocated_epoch')
  deadline=$(receipt_field "$name" '.deadline_epoch')
  evidence "case=provision receipt=$(jq -c . "$(receipt_of "$name")")"
  [ "$((deadline - allocated))" -le 20 ] || fail "allocation deadline is not the 20-second aggregate budget"
  [ "$(receipt_field "$name" '.own_group')" = true ] || fail "allocation did not prove the server's own process group"
  [ "$(receipt_field "$name" '.native.socket_path')" = "/tmp/$name.sock" ] || fail "provision did not bind the native socket_path Herdr reported"
  [ "$(receipt_field "$name" '.native.running')" = true ] || fail "provision did not bind the native running flag"
  grep -q "server_generation.*unsupported-by-cli" "$TRIPWIRES/$name.fleet-state.json" \
    || fail "tripwire does not state the server-generation capability gap"

  output=$(run_with_fake fm_herdr_lab_cli "$name" workspace list) || fail "safe run command failed"
  [ "$output" = '{"ok":true}' ] || fail "run did not pass the native JSON through unchanged: $output"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  [ "$(cat "$FAKE_STATE/$name.stop")" = delivered ] || fail "fake stop did not confirm delivery"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"
  assert_absent "$(receipt_of "$name")" "successful teardown left its allocation receipt behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_private_state_and_required_socket_identity() {
  local name="fm-lab-private-state-$$" status=0
  (umask 022; run_with_fake fm_herdr_lab_provision "$name") || fail "private state provision failed"
  account_launches || fail "private-state launch accountability failed"
  python3 -c 'import os, stat, sys
for p in sys.argv[1:]:
    s = os.lstat(p)
    assert s.st_uid == os.getuid() and not s.st_mode & 0o077' "$TRIPWIRES" "$(receipt_of "$name")" || fail "helper created public state"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "private state cleanup failed"
  chmod 755 "$TRIPWIRES"
  run_with_fake fm_herdr_lab_provision "fm-lab-unsafe-state-$$" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "unsafe existing state must be refused"
  chmod 700 "$TRIPWIRES"
  printf '%s\n' "$TMP_ROOT/missing.sock" > "$FAKE_STATE/default-socket"
  status=0
  run_with_fake fm_herdr_lab_prepare "fm-lab-no-socket-$$" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing required socket identity must be refused"
  printf '%s\n' "$TMP_ROOT/default.sock" > "$FAKE_STATE/default-socket"
  pass "fm-herdr-lab: state is private and a real socket identity is required"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' "$TMP_ROOT/default.sock" > "$FAKE_STATE/default-socket"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$" child='' birth='' detached='' detached_birth=''
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_SERVER_CHILDREN=1 run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  read -r child birth < "$FAKE_STATE/$name.child"
  read -r detached detached_birth < "$FAKE_STATE/$name.detached"
  fixture_register "$child" "$birth"
  fixture_register "$detached" "$detached_birth"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  # The first server exited on its own, so its receipt records a positively
  # absent pid; that is the one state that may clear before re-provision.
  assert_present "$(receipt_of "$name")" "stop removed the allocation receipt"
  pid_present "$child" || fail "fixture stop did not leave its group child"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  pid_present "$child" && fail "re-provision discarded outstanding group custody"
  pid_present "$detached" || fail "re-provision signaled a detached process"
  assert_present "$(receipt_of "$name")" "re-provision did not record a fresh allocation receipt"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  reap_fixture "$child"
  reap_fixture "$detached"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0 started ended launched='' launched_birth='' delay='' delay_birth=''
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  started=$(date +%s)
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  ended=$(date +%s)
  read -r launched launched_birth < "$FAKE_STATE/$name.launched" || true
  read -r delay delay_birth < "$FAKE_STATE/$name.delay" || true
  settle_launched "cancelled late-launch delay" "$delay" "$delay_birth"
  evidence "case=late-launch-delay pid=$delay state=$(fixture_state "$delay" "$delay_birth")"
  evidence "case=late-launch status=$status elapsed=$((ended - started))s polls=$(grep -c "^status --json" "$FAKE_LOG") launched_pid=${launched:-none} launched_state=$(fixture_state "$launched" "$launched_birth")"
  expect_code 1 "$status" "timed-out provision must fail"
  settle_launched "cancelled late launch" "$launched" "$launched_birth"
  [ "$((ended - started))" -le 20 ] || fail "timed-out provision overran its aggregate budget"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  assert_absent "$(receipt_of "$name")" "a fully cancelled launch must not retain an allocation receipt"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

# Provision a lingering fake server and print its pid, which the fake wrote
# itself before exec and which must equal the receipt's bound pid. Callers
# register the pid as a fixture (this runs in a command substitution).
# Provision a lingering fake server and print "pid birth" from the fake's own
# launch-time record, which must agree with the helper's authenticated receipt.
# Callers register with exactly that identity (this runs in a command
# substitution).
# Provision a lingering fake server IN THE CALLER'S SHELL (never a command
# substitution, so registration reaches the registry cleanup reads), register
# it by the identity the fake recorded at launch cross-checked against the
# helper's authenticated receipt, and leave its pid in LINGER_PID. Any
# unproven identity retains evidence before failing.
LINGER_PID=
provision_lingering() { # <session>
  local name=$1 pid birth launch_pid='' launch_birth=''
  LINGER_PID=
  run_with_fake fm_herdr_lab_provision "$name" || {
    retain_evidence "lingering provision of $name failed; receipt/tripwire kept"
    fail "lingering provision of $name failed"
  }
  pid=$(receipt_field "$name" '.pid')
  birth=$(receipt_field "$name" '.birth')
  read -r launch_pid launch_birth < "$FAKE_STATE/$name.server" || true
  fixture_identity_valid "$launch_pid" "$launch_birth" || {
    retain_evidence "$name: no valid launch record (pid='${launch_pid:-}' birth='${launch_birth:-}'); receipt pid='${pid:-}'"
    fail "the fake server for $name recorded no valid launch identity"
  }
  [ "$pid" = "$launch_pid" ] && [ "$birth" = "$launch_birth" ] || {
    retain_evidence "$name: receipt ($pid $birth) disagrees with launch record ($launch_pid $launch_birth)"
    fail "receipt identity $pid/$birth disagrees with the server's own launch record $launch_pid/$launch_birth"
  }
  fixture_register "$launch_pid" "$launch_birth"
  LINGER_PID=$launch_pid
}

test_exec_transition_keeps_identity_and_teardown_terminates_server() {
  local name="fm-lab-exec-identity-$$" pid birth
  : > "$FAKE_LOG"
  provision_lingering "$name"
  pid=$LINGER_PID
  birth=$(receipt_field "$name" '.birth')
  evidence "case=exec-transition pid=$pid recorded_birth=$birth live_birth=$(pid_birth "$pid") live_command=$(pid_command "$pid") described=$(receipt_field "$name" '.command_description')"
  [ "$birth" = "$(pid_birth "$pid")" ] || fail "recorded birth does not match the live process birth"
  case "$(pid_command "$pid")" in
    *sleep*) : ;;
    *) fail "fixture did not exec into a different command image" ;;
  esac
  [ "$(receipt_field "$name" '.pgid')" = "$pid" ] || fail "server is not its own process-group leader"
  FM_FAKE_HERDR_STOP_KEEPS_SERVER=1 run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown of the lingering server failed"
  if pid_present "$pid"; then
    fail "teardown left the exec-transitioned server $pid running"
  fi
  reap_fixture "$pid"
  assert_absent "$(receipt_of "$name")" "teardown did not clear the receipt after proving the server gone"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "teardown left the tripwire behind"
  pass "fm-herdr-lab: identity survives the exec transition and cleanup terminates the exact server"
}

test_same_pid_new_birth_is_refused_and_blocks_reprovision() {
  local name="fm-lab-reused-pid-$$" pid status=0 output
  : > "$FAKE_LOG"
  provision_lingering "$name"
  pid=$LINGER_PID
  rm -f "$PS_COUNTER"
  output=$(FM_FAKE_HERDR_STOP_KEEPS_SERVER=1 FM_FAKE_PS_MUTATE_PID="$pid" FM_FAKE_PS_MUTATE_AFTER=0 run_with_fake fm_herdr_lab_teardown "$name" 2>&1) || status=$?
  evidence "case=reused-pid status=$status alive=$(pid_present "$pid" && printf yes || printf no) output=$(printf '%s' "$output" | tr '\n' '|')"
  expect_code 1 "$status" "a pid whose birth changed must fail teardown"
  assert_contains "$output" "different process" "reused pid was not reported as a different process"
  pid_present "$pid" || fail "reused-pid refusal signaled the process anyway"
  assert_present "$(receipt_of "$name")" "reused-pid refusal dropped the allocation receipt"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "reused-pid refusal dropped the tripwire"
  grep -Eq "^session (stop|delete) $name" "$FAKE_LOG" && fail "reused allocation reached destruction"

  : > "$FAKE_LOG"
  status=0
  output=$(run_with_fake fm_herdr_lab_provision "$name" 2>&1) || status=$?
  expect_code 1 "$status" "a retained allocation must block re-provision"
  assert_contains "$output" "retained allocation receipt" "re-provision did not name the retained receipt"
  grep -q "^server --session $name" "$FAKE_LOG" && fail "blocked re-provision still launched a server"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "reconciling teardown with a truthful process table failed"
  if pid_present "$pid"; then
    fail "reconciling teardown left the server running"
  fi
  reap_fixture "$pid"
  assert_absent "$(receipt_of "$name")" "reconciliation did not clear the receipt"
  pass "fm-herdr-lab: a same-number new-birth pid is refused, retains its receipt, and blocks re-provision"
}

test_identity_is_rechecked_immediately_before_each_signal() {
  local name="fm-lab-recheck-$$" pid status=0 output
  : > "$FAKE_LOG"
  provision_lingering "$name"
  pid=$LINGER_PID
  rm -f "$PS_COUNTER"
  printf 'deleted\n' > "$FAKE_STATE/$name"
  # The first identity read answers truthfully so the allocation classifies as
  # owned; the recheck that guards SIGTERM sees a different birth and must
  # refuse without signaling.
  output=$(FM_FAKE_HERDR_STOP_KEEPS_SERVER=1 FM_FAKE_PS_MUTATE_PID="$pid" FM_FAKE_PS_MUTATE_AFTER=1 run_with_fake fm_herdr_lab_teardown "$name" 2>&1) || status=$?
  evidence "case=signal-recheck status=$status ps_queries=$(cat "$PS_COUNTER" 2>/dev/null) alive=$(pid_present "$pid" && printf yes || printf no)"
  expect_code 1 "$status" "a changed identity at signal time must fail teardown"
  assert_contains "$output" "refusing SIGTERM" "the pre-signal recheck did not refuse SIGTERM"
  pid_present "$pid" || fail "the process was signaled despite the failed recheck"
  assert_present "$(receipt_of "$name")" "failed recheck dropped the allocation receipt"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "truthful teardown after the recheck refusal failed"
  pid_present "$pid" && fail "truthful teardown left the server running"
  reap_fixture "$pid"
  pass "fm-herdr-lab: every signal is preceded by its own identity recheck"
}

test_delete_rechecks_allocation_after_stop() {
  local name="fm-lab-delete-recheck-$$" pid status=0 output
  provision_lingering "$name"
  pid=$LINGER_PID
  : > "$FAKE_LOG"
  output=$(FM_FAKE_HERDR_STOP_KEEPS_SERVER=1 FM_FAKE_PS_MUTATE_PID="$pid" FM_FAKE_PS_MUTATE_AFTER=0 \
    FM_FAKE_PS_AFTER_TERM="$FAKE_STATE/$name.stopped" run_with_fake fm_herdr_lab_teardown "$name" 2>&1) || status=$?
  expect_code 1 "$status" "delete must refuse a replaced allocation after stop"
  grep -q "^session stop $name" "$FAKE_LOG" || fail "case never reached stop"
  grep -q "^session delete $name" "$FAKE_LOG" && fail "delete skipped allocation recheck"
  pid_present "$pid" || fail "replacement refusal signaled server"
  assert_present "$(receipt_of "$name")" "delete refusal lost receipt"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "truthful retry failed"
  reap_fixture "$pid"
  pass "fm-herdr-lab: delete independently rechecks custody after stop"
}

test_escalation_and_descendant_signal_rechecks() {
  local name="fm-lab-kill-recheck-$$" pid status=0 output child='' birth='' detached='' detached_birth='' attempt
  FM_FAKE_HERDR_SERVER_IGNORE_TERM=1 provision_lingering "$name"
  pid=$LINGER_PID
  for ((attempt=0; attempt<40; attempt++)); do
    [ ! -e "$FAKE_STATE/$name.term-ready" ] || break
    "$REAL_SLEEP" 0.05
  done
  assert_present "$FAKE_STATE/$name.term-ready" "TERM-ignoring fixture did not start"
  printf 'deleted\n' > "$FAKE_STATE/$name"
  output=$(FM_FAKE_PS_MUTATE_PID="$pid" FM_FAKE_PS_MUTATE_AFTER=0 FM_FAKE_PS_AFTER_TERM="$FAKE_STATE/$name.term" \
    run_with_fake fm_herdr_lab_teardown "$name" 2>&1) || status=$?
  expect_code 1 "$status" "changed identity before escalation must refuse KILL"
  assert_present "$FAKE_STATE/$name.term" "escalation case never delivered TERM"
  assert_contains "$output" "refusing SIGKILL" "escalation did not recheck identity"
  pid_present "$pid" || fail "failed KILL recheck still killed server"
  assert_present "$(receipt_of "$name")" "escalation refusal lost custody"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "truthful escalation cleanup failed"
  reap_fixture "$pid"

  name="fm-lab-child-recheck-$$"
  FM_FAKE_HERDR_SERVER_CHILDREN=1 provision_lingering "$name"
  pid=$LINGER_PID
  read -r child birth < "$FAKE_STATE/$name.child"
  read -r detached detached_birth < "$FAKE_STATE/$name.detached"
  fixture_register "$child" "$birth"
  fixture_register "$detached" "$detached_birth"
  printf 'deleted\n' > "$FAKE_STATE/$name"
  rm -f "$PS_COUNTER"
  status=0
  output=$(FM_FAKE_PS_MUTATE_PID="$child" FM_FAKE_PS_MUTATE_AFTER=1 run_with_fake fm_herdr_lab_teardown "$name" 2>&1) || status=$?
  expect_code 1 "$status" "changed descendant identity must refuse TERM"
  assert_contains "$output" "refusing SIGTERM" "descendant did not receive its own signal recheck"
  pid_present "$child" || fail "failed descendant recheck still signaled child"
  assert_present "$(receipt_of "$name")" "descendant refusal lost custody"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "truthful descendant cleanup failed"
  reap_fixture "$pid"
  reap_fixture "$child"
  reap_fixture "$detached"
  pass "fm-herdr-lab: escalation and descendant signals independently recheck identity"
}

test_unknown_process_state_is_refused_not_treated_as_absent() {
  local name="fm-lab-unknown-$$" pid status=0 output started ended
  : > "$FAKE_LOG"
  provision_lingering "$name"
  pid=$LINGER_PID
  started=$(date +%s)
  output=$(FM_FAKE_HERDR_STOP_KEEPS_SERVER=1 FM_FAKE_PS_HANG=1 run_with_fake fm_herdr_lab_teardown "$name" 2>&1) || status=$?
  ended=$(date +%s)
  evidence "case=unknown-state status=$status elapsed=$((ended - started))s alive=$(pid_present "$pid" && printf yes || printf no)"
  expect_code 1 "$status" "an unreadable process table must fail teardown"
  assert_contains "$output" "cannot read the state" "unknown state was not reported as unknown"
  pid_present "$pid" || fail "unknown state was treated as permission to signal"
  assert_present "$(receipt_of "$name")" "unknown state dropped the allocation receipt"
  [ "$((ended - started))" -le 20 ] || fail "unknown-state refusal overran the aggregate budget"
  status=0
  output=$(FM_FAKE_PS_PARTIAL=1 run_with_fake fm_herdr_lab_teardown "$name" 2>&1) || status=$?
  expect_code 1 "$status" "exit 1 with partial ps output must remain unknown"
  pid_present "$pid" || fail "partial ps output authorized signaling"
  assert_present "$(receipt_of "$name")" "partial ps output discarded custody"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after the process table recovered failed"
  pid_present "$pid" && fail "recovered teardown left the server running"
  reap_fixture "$pid"
  pass "fm-herdr-lab: an unreadable process table is unknown, never absent"
}

test_unrelated_and_detached_processes_survive_while_group_children_are_cleaned() {
  local name="fm-lab-descendants-$$" pid unrelated unrelated_birth child child_birth='' detached detached_birth=''
  : > "$FAKE_LOG"
  python3 -c 'import os, sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])' "$REAL_SLEEP" 300 &
  unrelated=$!
  # Our own live, unreaped child: its birth read now is its launch identity.
  unrelated_birth=$(fixture_birth "$unrelated") || {
    retain_evidence "unrelated fixture $unrelated could not be identified at launch (status $?)"
    fail "unrelated fixture $unrelated could not be identified at launch"
  }
  fixture_register "$unrelated" "$unrelated_birth"
  FM_FAKE_HERDR_SERVER_CHILDREN=1 provision_lingering "$name"
  pid=$LINGER_PID
  read -r child child_birth < "$FAKE_STATE/$name.child" || true
  read -r detached detached_birth < "$FAKE_STATE/$name.detached" || true
  fixture_register "$child" "$child_birth"
  fixture_register "$detached" "$detached_birth"
  evidence "case=descendants server=$pid child=$child detached=$detached unrelated=$unrelated child_pgid=$("$REAL_PS" -p "$child" -o pgid= | tr -d ' ') detached_pgid=$("$REAL_PS" -p "$detached" -o pgid= | tr -d ' ')"
  [ "$("$REAL_PS" -p "$child" -o pgid= | tr -d ' ')" = "$pid" ] || fail "fixture child is not in the server's process group"
  [ "$("$REAL_PS" -p "$detached" -o pgid= | tr -d ' ')" = "$detached" ] || fail "fixture detached child did not leave the server's process group"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown with descendants failed"
  pid_present "$pid" && fail "server survived teardown"
  pid_present "$child" && fail "in-group descendant survived teardown"
  pid_present "$detached" || fail "detached descendant outside the proven group was signaled"
  pid_present "$unrelated" || fail "unrelated process was signaled"
  assert_absent "$(receipt_of "$name")" "receipt retained although the proven group was emptied"
  reap_fixture "$pid"
  reap_fixture "$child"
  reap_fixture "$detached"
  reap_fixture "$unrelated"
  pass "fm-herdr-lab: only proven group members are cleaned; detached and unrelated processes are preserved"
}

test_server_that_exits_at_start_is_positively_absent() {
  local name="fm-lab-server-exit-$$" status=0 output
  : > "$FAKE_LOG"
  output=$(FM_FAKE_HERDR_SERVER_LINGER=0 run_with_fake fm_herdr_lab_provision "$name" 2>&1) || status=$?
  account_launches || fail "early-exit launch accountability failed"
  evidence "case=server-exit status=$status output=$(printf '%s' "$output" | tr '\n' '|')"
  expect_code 1 "$status" "a server that exits at start must fail provision"
  assert_present "$(receipt_of "$name")" "failed readiness discarded custody before native teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed provision must keep the tripwire for teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after the server exit failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "teardown after the server exit left the tripwire"
  pass "fm-herdr-lab: a server that exits at start is positively absent and leaves nothing to clean"
}

test_hanging_preflight_is_bounded_and_launches_nothing() {
  local name="fm-lab-preflight-hang-$$" status=0 started ended
  : > "$FAKE_LOG"
  started=$(date +%s)
  FM_FAKE_HERDR_HANG="session list" run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  ended=$(date +%s)
  evidence "case=preflight-hang status=$status elapsed=$((ended - started))s"
  expect_code 1 "$status" "a hanging preflight must fail provision"
  [ "$((ended - started))" -le 5 ] || fail "hanging preflight was not clipped to the per-call bound"
  grep -q "^server --session" "$FAKE_LOG" && fail "hanging preflight still launched a server"
  assert_absent "$(receipt_of "$name")" "hanging preflight left an allocation receipt"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "hanging preflight left a tripwire"
  pass "fm-herdr-lab: a hanging preflight call is bounded and launches nothing"
}

test_hanging_polls_respect_the_aggregate_budget_and_are_clipped() {
  local name="fm-lab-poll-hang-$$" status=0 started ended polls stamp late=0 pid='' pid_birth='' server_state
  : > "$FAKE_LOG"
  : > "$FAKE_TLOG"
  started=$(date +%s)
  FM_FAKE_HERDR_HANG="status --json" \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  ended=$(date +%s)
  polls=$(grep -c "^status --json" "$FAKE_LOG")
  # A poll may start only while more than the 4-second reserve remains, so
  # with one second of clock-alignment slack none may start 17s in or later.
  while read -r stamp _; do
    [ "$((stamp - started))" -lt 17 ] || late=$((late + 1))
  done < <(grep " status --json" "$FAKE_TLOG")
  read -r pid pid_birth < "$FAKE_STATE/$name.server" || true
  server_state=$(fixture_state "$pid" "$pid_birth")
  evidence "case=poll-hang status=$status elapsed=$((ended - started))s polls=$polls polls_started_inside_reserve=$late launched_pid=${pid:-none} launched_state=$server_state"
  expect_code 1 "$status" "hanging polls must fail provision"
  [ "$((ended - started))" -le 20 ] || fail "provision with hanging polls overran its 20-second aggregate budget including cleanup"
  [ "$polls" -ge 5 ] || fail "expected at least five nominal 3-second polls inside the budget, saw $polls"
  [ "$late" -eq 0 ] || fail "$late poll(s) started inside the cleanup reserve"
  settle_launched "hanging-poll cancellation" "$pid" "$pid_birth"
  assert_present "$(receipt_of "$name")" "cancelled allocation discarded the remaining native session custody"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after the hanging-poll failure failed"
  pass "fm-herdr-lab: hanging polls are clipped to the budget and cleanup fits inside the reserve"
}

test_hanging_stop_is_bounded_and_never_reaches_delete() {
  local name="fm-lab-stop-hang-$$" status=0 started ended
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "stop-hang fixture provision failed"
  started=$(date +%s)
  FM_FAKE_HERDR_HANG="session stop" run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  ended=$(date +%s)
  evidence "case=stop-hang status=$status elapsed=$((ended - started))s"
  expect_code 1 "$status" "a hanging stop must fail teardown"
  [ "$((ended - started))" -le 8 ] || fail "hanging stop was not clipped"
  grep -q "^session delete" "$FAKE_LOG" && fail "a failed stop was followed by a delete"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed stop dropped the tripwire"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "fixture expectation: the lab should still be running"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after the stop recovered failed"
  pass "fm-herdr-lab: a hanging stop is bounded and never becomes a delete"
}

test_socket_generation_change_is_the_primary_failure_even_when_cleanup_fails() {
  local name="fm-lab-generation-$$" status=0 output socket="$TMP_ROOT/default-generation.sock" before after
  : > "$FAKE_LOG"
  python3 -c 'import os, socket, sys
os.chdir(os.path.dirname(sys.argv[1]))
s = socket.socket(socket.AF_UNIX)
s.bind(os.path.basename(sys.argv[1]))' "$socket"
  printf '%s\n' "$socket" > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_provision "$name" || fail "generation fixture provision failed"
  before=$(jq -r '.socket_identity' "$TRIPWIRES/$name.fleet-state.json")
  mv "$socket" "$socket.old"
  python3 -c 'import os, socket, sys
os.chdir(os.path.dirname(sys.argv[1]))
s = socket.socket(socket.AF_UNIX)
s.bind(os.path.basename(sys.argv[1]))' "$socket"
  after=$(run_with_fake fm_herdr_lab_fleet_state "$name" | jq -r '.socket_identity')
  evidence "case=generation before=$before after=$after"
  [ "$before" != "$after" ] || fail "fixture expectation: replacing the socket file did not change its identity"
  output=$(FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" 2>&1) || status=$?
  expect_code 1 "$status" "a re-bound default socket must fail teardown"
  assert_contains "$output" "FLEET-STATE TRIPWIRE FAILED" "socket generation change was not reported as a tripwire failure"
  assert_contains "$output" "session delete failed" "the cleanup failure was not reported"
  assert_contains "$output" "also failed" "the tripwire failure was not kept primary over the cleanup failure"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "tripwire failure dropped the evidence"
  printf '%s\n' "$TMP_ROOT/default.sock" > "$FAKE_STATE/default-socket"
  pass "fm-herdr-lab: a re-bound default socket trips even when every CLI field is unchanged, and stays primary"
}

test_run_is_bounded_per_call() {
  local name="fm-lab-run-bound-$$" status=0 started ended
  started=$(date +%s)
  FM_HERDR_LAB_CALL_SECS=1 FM_FAKE_HERDR_HANG="workspace list" run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null 2>&1 || status=$?
  ended=$(date +%s)
  evidence "case=run-bound status=$status elapsed=$((ended - started))s"
  expect_code 124 "$status" "a hanging run call must report the bound as 124"
  [ "$((ended - started))" -le 3 ] || fail "run call was not clipped to FM_HERDR_LAB_CALL_SECS"
  status=0
  FM_HERDR_LAB_CALL_SECS=9 run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an out-of-range call bound must be refused"
  pass "fm-herdr-lab: run keeps its per-call bound and rejects bounds outside 1..3"
}

test_rejected_launcher_never_becomes_cleanup_authority() {
  local mode=${1:-1} name="fm-lab-rejected-launch-${1:-1}-$$" status=0 pid='' birth='' before output
  local FM_FAKE_LAUNCH_RECORD="$FAKE_STATE/rejected-launcher-$mode"
  local FM_FAKE_REJECT_LAUNCH=$mode FM_FAKE_PUBLISH_FAIL=1
  run_with_fake /bin/bash -c 'source "$1"; ( ( fm_herdr_lab_provision "$2"; result=$?; exit "$result" ); result=$?; exit "$result" )' _ "$ROOT/bin/fm-herdr-lab.sh" "$name" > "$TMP_ROOT/rejected-$mode-launch.log" 2>&1 || status=$?
  read -r pid birth < "$FM_FAKE_LAUNCH_RECORD" || true
  fixture_identity_valid "$pid" "$birth" || { retain_evidence "rejected launcher lacks launch identity"; fail "missing launcher identity"; }
  expect_code 1 "$status" "replaced launch observation must be refused"
  jq -e --argjson pid "$pid" '.rejected_observation.pid == $pid and .pid == null' \
    "$(receipt_of "$name").pending" >/dev/null || fail "rejected observation became custody"
  assert_absent "$FAKE_STATE/publication-attempts" "rejected observation reached publication failure cancellation"
  before=$(wc -l < "$FM_FAKE_LAUNCH_RECORD.probes")
  status=0
  run_with_fake /bin/bash -c 'source "$1"; ( ( fm_herdr_lab_teardown "$2"; result=$?; exit "$result" ); result=$?; exit "$result" )' _ "$ROOT/bin/fm-herdr-lab.sh" "$name" > "$TMP_ROOT/rejected-$mode-teardown.log" 2>&1 || status=$?
  expect_code 1 "$status" "rejected evidence must refuse later teardown"
  [ "$(wc -l < "$FM_FAKE_LAUNCH_RECORD.probes")" = "$before" ] || fail "teardown probed rejected custody"
  output=$(cat "$TMP_ROOT/rejected-$mode-teardown.log")
  assert_contains "$output" "no authenticated custody" "teardown accepted rejected observation"
  status=0
  run_with_fake /bin/bash -c 'source "$1"; ( ( fm_herdr_lab_provision "$2"; result=$?; exit "$result" ); result=$?; exit "$result" )' _ "$ROOT/bin/fm-herdr-lab.sh" "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "rejected evidence must block re-provision"
  assert_present "$(receipt_of "$name").pending" "rejected evidence was discarded"
  reap_fixture "$pid"
  settle_launched "rejected launcher fixture" "$pid" "$birth"
  evidence "case=rejected-launch mode=$mode pid=$pid teardown_status=1 rejected_probes=$before later_probes=$(wc -l < "$FM_FAKE_LAUNCH_RECORD.probes") state=absent"
  pass "fm-herdr-lab: rejected launch observations never authorize publication or later cleanup"
}

test_stock_bash_allocates_in_ordinary_and_nested_shells() {
  local mode name status pid='' birth='' recorded
  for mode in ordinary nested; do
    name="fm-lab-stock-bash-$mode-$$"
    status=0
    run_with_fake /bin/bash -c '
      source "$1"
      name=$2
      receipt="$FM_HERDR_LAB_STATE_DIR/$name.allocation.json"
      case "$3" in
        ordinary)
          fm_herdr_lab_provision "$name" || exit 1
          [ "$(jq -r .ppid "$receipt")" = "$$" ] || exit 1
          ;;
        nested)
          (
            (
              fm_herdr_lab_provision "$name" || exit 1
              [ "$(jq -r .ppid "$receipt")" != "$$" ] || exit 1
            )
            result=$?
            exit "$result"
          ) || exit 1
          ;;
      esac
      printf "evidence: case=stock-bash mode=%s version=%s parent=%s outer=%s\n" "$3" "$BASH_VERSION" "$(jq -r .ppid "$receipt")" "$$"
    ' _ "$ROOT/bin/fm-herdr-lab.sh" "$name" "$mode" || status=$?
    expect_code 0 "$status" "stock bash $mode provision must bind its actual allocating parent"
    read -r pid birth < "$FAKE_STATE/$name.server" || true
    fixture_register "$pid" "$birth"
    recorded=$(receipt_field "$name" '.birth')
    [ "$(receipt_field "$name" '.pid')" = "$pid" ] && [ "$recorded" = "$birth" ] || fail "stock bash receipt disagrees with launch identity"
    run_with_fake /bin/bash -c 'source "$1"; fm_herdr_lab_teardown "$2"' _ "$ROOT/bin/fm-herdr-lab.sh" "$name" || fail "stock bash cleanup failed"
    settle_launched "stock bash $mode cleanup" "$pid" "$birth"
  done
  pass "fm-herdr-lab: stock bash binds the actual parent in ordinary and nested shells"
}

test_authenticated_publication_failure_cancels_launcher() {
  local name="fm-lab-publish-failure-$$" status=0 pid='' birth=''
  local FM_FAKE_LAUNCH_RECORD="$FAKE_STATE/publish-launcher" FM_FAKE_PUBLISH_FAIL=1
  run_with_fake fm_herdr_lab_provision "$name" > "$TMP_ROOT/publication-failure.log" 2>&1 || status=$?
  read -r pid birth < "$FM_FAKE_LAUNCH_RECORD" || true
  settle_launched "publication failure cancellation" "$pid" "$birth"
  expect_code 1 "$status" "publication failure must fail provision"
  assert_present "$FAKE_STATE/publication-attempts" "publication failure was not exercised"
  assert_absent "$FAKE_STATE/$name.launched" "unpublished allocation was released to start the server"
  assert_absent "$(receipt_of "$name")" "failed publication created a receipt"
  assert_absent "$(receipt_of "$name").pending" "proved cancellation left pending custody"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after publication failure failed"
  evidence "case=publication-failure pid=$pid status=$status state=absent"
  pass "fm-herdr-lab: authenticated publication failure cancels the launcher before server exec"
}

test_large_retained_target_list_stops_at_original_deadline() {
  local name="fm-lab-large-targets-$$" status=0 started ended receipt pid output birth=
  provision_lingering "$name"
  pid=$LINGER_PID
  run_with_fake fm_herdr_lab_stop "$name" || fail "large-target fixture stop failed"
  receipt=$(receipt_of "$name")
  python3 -c 'import json, sys
p = sys.argv[1]
with open(p) as f:
    r = json.load(f)
i = "birth={birth} ppid={ppid} pgid={pgid}".format(**r)
r["targets"] = [{"pid": str(r["pid"]), "identity": i}] * 10000
with open(p, "w") as f:
    json.dump(r, f)' "$receipt"
  started=$(date +%s)
  run_with_fake fm_herdr_lab_teardown "$name" > "$TMP_ROOT/large-targets.log" 2>&1 || status=$?
  ended=$(date +%s)
  output=$(cat "$TMP_ROOT/large-targets.log")
  evidence "case=large-targets pid=$pid status=$status elapsed=$((ended - started))s targets=$(jq '.targets | length' "$receipt")"
  expect_code 1 "$status" "an unprocessed target list must retain custody"
  [ "$((ended - started))" -le 20 ] || fail "large retained list overran original deadline"
  assert_contains "$output" "unprocessed targets retained" "large list did not exercise the target deadline boundary"
  [ "$(jq '.targets | length' "$receipt")" = 10000 ] || fail "unprocessed suffix was discarded"
  read -r pid birth < "$FAKE_STATE/$name.server" || true
  settle_launched "large-target fixture" "$pid" "$birth"
  pass "fm-herdr-lab: large retained target lists stop at the original deadline with custody intact"
}

test_cli_entrypoint_matches_sourced_contract() {
  local name output status=0
  name=$(run_with_fake "$ROOT/bin/fm-herdr-lab.sh" name cli-entry) || fail "CLI name failed"
  fm_herdr_lab_validate_name "$name" || fail "CLI name produced an invalid session name"
  output=$(run_with_fake "$ROOT/bin/fm-herdr-lab.sh" --help) || fail "CLI help failed"
  assert_contains "$output" "fm-herdr-lab.sh teardown <session>" "CLI help lost the teardown usage line"
  run_with_fake "$ROOT/bin/fm-herdr-lab.sh" bogus >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown CLI command must exit 2"
  : > "$FAKE_LOG"
  run_with_fake "$ROOT/bin/fm-herdr-lab.sh" provision "$name" || fail "CLI provision failed"
  output=$(run_with_fake "$ROOT/bin/fm-herdr-lab.sh" run "$name" workspace list) || fail "CLI run failed"
  [ "$output" = '{"ok":true}' ] || fail "CLI run did not pass native JSON through: $output"
  run_with_fake "$ROOT/bin/fm-herdr-lab.sh" stop "$name" >/dev/null || fail "CLI stop failed"
  run_with_fake "$ROOT/bin/fm-herdr-lab.sh" teardown "$name" || fail "CLI teardown failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "CLI teardown left the tripwire"
  assert_absent "$(receipt_of "$name")" "CLI teardown left the receipt"
  pass "fm-herdr-lab: the CLI entrypoint keeps the public command contract"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_private_state_and_required_socket_identity
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
test_exec_transition_keeps_identity_and_teardown_terminates_server
test_same_pid_new_birth_is_refused_and_blocks_reprovision
test_identity_is_rechecked_immediately_before_each_signal
test_delete_rechecks_allocation_after_stop
test_escalation_and_descendant_signal_rechecks
test_unknown_process_state_is_refused_not_treated_as_absent
test_unrelated_and_detached_processes_survive_while_group_children_are_cleaned
test_server_that_exits_at_start_is_positively_absent
test_hanging_preflight_is_bounded_and_launches_nothing
test_hanging_polls_respect_the_aggregate_budget_and_are_clipped
test_hanging_stop_is_bounded_and_never_reaches_delete
test_socket_generation_change_is_the_primary_failure_even_when_cleanup_fails
test_run_is_bounded_per_call
test_stock_bash_allocates_in_ordinary_and_nested_shells
test_rejected_launcher_never_becomes_cleanup_authority
test_rejected_launcher_never_becomes_cleanup_authority parent
test_authenticated_publication_failure_cancels_launcher
test_large_retained_target_list_stops_at_original_deadline
test_cli_entrypoint_matches_sourced_contract
