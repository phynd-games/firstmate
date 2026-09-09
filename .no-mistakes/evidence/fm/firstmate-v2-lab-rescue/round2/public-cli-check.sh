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
. /Users/criz/.no-mistakes/worktrees/da589fef49ee/01M22KSZYDN9KDENNT227D4QXM/tests/lib.sh

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

# Manual public-entrypoint check using the current test's unchanged fake world.
lab_command() {
  local result=0
  printf '\n$ bin/fm-herdr-lab.sh'
  printf ' %q' "$@"
  printf '\n'
  run_with_fake "$ROOT/bin/fm-herdr-lab.sh" "$@" || result=$?
  printf 'exit=%s\n' "$result"
  return "$result"
}
name="fm-lab-cli-evidence-$$"
lab_command provision "$name" || fail "provision failed"
printf '\nPersisted allocation receipt:\n'
jq . "$(receipt_of "$name")"
printf '\nPersisted default-session tripwire:\n'
jq . "$TRIPWIRES/$name.fleet-state.json"
lab_command run "$name" workspace list || fail "run failed"
status=0
lab_command run "$name" status --session default || status=$?
expect_code 1 "$status" "caller session override must be refused"
lab_command stop "$name" || fail "stop failed"
lab_command teardown "$name" || fail "teardown failed"
assert_absent "$(receipt_of "$name")" "receipt remains after cleanup"
assert_absent "$TRIPWIRES/$name.fleet-state.json" "tripwire remains after cleanup"
printf '\nObserved final fake session state: %s\n' "$(cat "$FAKE_STATE/$name")"
printf 'Observed allocation receipt: absent\nObserved tripwire: absent\n'
