#!/usr/bin/env bash
# Behavior tests for idempotent, identity-safe dashboard startup
# (bin/fm-dashboard-start.sh).
#
# These drive the REAL startup command, the REAL dashboard server, and REAL
# loopback sockets. Only Herdr is doubled, by tests/assets/fake-herdr.sh, so a
# machine with no Herdr server still proves the ownership, identity, collision,
# readiness, and restart behavior. The guarded real-Herdr proof lives in
# tests/fm-dashboard-herdr-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

START="$ROOT/bin/fm-dashboard-start.sh"
FAKE_HERDR="$ROOT/tests/assets/fake-herdr.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-start)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

# Every server this suite starts is reclaimed on the way out, however the run
# ends, so a failed assertion never leaves a listener behind.
# Walks the fixture root rather than an array: make_home runs inside $( ), whose
# subshell would discard any array this function tried to read.
reap_started() {
  local pidfile pid
  for pidfile in "$TMP_ROOT"/*/herdr/panes/*.pid; do
    [ -e "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'reap_started; fm_test_cleanup' EXIT
trap 'reap_started; fm_test_cleanup; exit 130' INT
trap 'reap_started; fm_test_cleanup; exit 143' TERM

# A plain local web server that is not a dashboard, for the collision cases.
start_foreign_listener() {  # <port> <log>
  python3 -m http.server "$1" --bind 127.0.0.1 > "$2" 2>&1 &
  printf '%s' "$!"
}

wait_for_port() {  # <port>
  local i=0
  while [ "$i" -lt 40 ]; do
    curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$1/" 2>/dev/null && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin" "$home/herdr" "$home/emptybin"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  cp "$FAKE_HERDR" "$home/fakebin/herdr"
  chmod +x "$home/fakebin/herdr"
  printf '%s\n' "$home"
}

start() {  # <home> <port> <args...>
  local home=$1 port=$2
  shift 2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FM_DASHBOARD_PORT="$port" FM_DASHBOARD_READY_TRIES=40 \
    "$START" "$@" 2>&1
}

url_in() {  # <output>
  printf '%s' "$1" | sed -n 's/^FIRSTMATE_DASHBOARD_URL=//p'
}

pane_count() {  # <home> - panes ever created, open or closed
  find "$1/herdr/panes" -name '*.state' -type f 2>/dev/null | wc -l | tr -d ' '
}

test_a_fresh_start_proves_readiness_before_it_prints_a_url() {
  local home port out url health
  home=$(make_home fresh)
  port=$(free_port)
  out=$(start "$home" "$port" ensure) || fail "ensure failed: $out"
  url=$(url_in "$out")
  [ "$url" = "http://127.0.0.1:$port/" ] || fail "the reported URL is wrong: $out"
  assert_contains "$out" "started on 127.0.0.1" "a fresh start did not say it started the dashboard"
  health=$(curl -fsS --max-time 3 "http://127.0.0.1:$port/healthz") \
    || fail "the reported URL does not actually answer"
  curl -fsS --max-time 3 "http://127.0.0.1:$port/" >/dev/null \
    || fail "the reported dashboard URL does not serve a page"
  printf '%s' "$health" | jq -e --arg home "$home" '
    .schema == "fm-dashboard-health.v1" and .home == $home and .ready == true' >/dev/null \
    || fail "the served health record does not identify this home: $health"
  [ "$(file_mode "$home/state/.dashboard-owner")" = "600" ] \
    || fail "the owner record is not private"
  pass "a fresh start proves readiness and identity before printing a URL"
}

file_mode() {  # <path>
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null
}

test_a_repeat_start_adopts_the_running_dashboard() {
  local home port first second
  home=$(make_home repeat)
  port=$(free_port)
  first=$(start "$home" "$port" ensure) || fail "the first ensure failed: $first"
  second=$(start "$home" "$port" ensure) || fail "the second ensure failed: $second"
  [ "$(url_in "$first")" = "$(url_in "$second")" ] \
    || fail "a repeat start reported a different URL: $second"
  [ "$(pane_count "$home")" = "1" ] \
    || fail "a repeat start created a second pane ($(pane_count "$home") panes)"
  assert_contains "$second" "already running" "the repeat start did not report a reuse"
  pass "a repeat start adopts the running dashboard instead of starting a second"
}

test_a_nonregular_owner_target_blocks_without_orphaning_the_new_pane() {
  local home port out open_panes
  home=$(make_home nonregular-owner)
  port=$(free_port)
  mkdir "$home/state/.dashboard-owner"
  out=$(start "$home" "$port" ensure 2>&1) && fail "a directory owner target was accepted: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "the non-regular owner target did not block startup"
  [ -d "$home/state/.dashboard-owner" ] || fail "the non-regular owner target was replaced"
  open_panes=$(grep -l '^open$' "$home/herdr/panes"/*.state 2>/dev/null | wc -l | tr -d ' ')
  [ "$open_panes" = "0" ] || fail "a rejected owner target orphaned an open pane"
  pass "a non-regular owner target blocks before publishing or orphaning a pane"
}

test_concurrent_starts_converge_on_one_dashboard() {
  local home port a b out_a out_b
  home=$(make_home concurrent)
  port=$(free_port)
  out_a="$home/a.out"; out_b="$home/b.out"
  start "$home" "$port" ensure > "$out_a" 2>&1 &
  a=$!
  start "$home" "$port" ensure > "$out_b" 2>&1 &
  b=$!
  wait "$a" || true
  wait "$b" || true
  [ "$(pane_count "$home")" = "1" ] \
    || fail "concurrent starts created $(pane_count "$home") panes"
  grep -q "^FIRSTMATE_DASHBOARD_URL=http://127.0.0.1:$port/$" "$out_a" \
    || fail "the first concurrent start did not report the URL: $(cat "$out_a")"
  grep -q "^FIRSTMATE_DASHBOARD_URL=http://127.0.0.1:$port/$" "$out_b" \
    || fail "the second concurrent start did not report the same URL: $(cat "$out_b")"
  pass "concurrent starts converge on one dashboard and report the same URL"
}

test_a_dead_owner_is_replaced_rather_than_reported() {
  local home port first second pane
  home=$(make_home dead-owner)
  port=$(free_port)
  first=$(start "$home" "$port" ensure) || fail "the first ensure failed: $first"
  pane=$(sed -n 's/^pane=//p' "$home/state/.dashboard-owner")
  # Close the pane behind the command's back: the recorded owner is now dead.
  FAKE_HERDR_STATE="$home/herdr" "$home/fakebin/herdr" pane close "$pane" >/dev/null
  second=$(start "$home" "$port" ensure) || fail "the restart failed: $second"
  [ -n "$(url_in "$second")" ] || fail "the restart did not report a URL: $second"
  [ "$(pane_count "$home")" = "2" ] || fail "the restart did not create a replacement pane"
  curl -fsS --max-time 3 "$(url_in "$second")healthz" >/dev/null \
    || fail "the restarted dashboard does not answer"
  grep -q 'stale' "$home/state/.dashboard-start.log" \
    || fail "the stale owner was not recorded in the durable diagnostics"
  pass "a dead owner is replaced, and the replacement is proven before it is reported"
}

test_an_unprovable_owner_is_never_silently_replaced() {
  local home port out pane
  home=$(make_home unprovable)
  port=$(free_port)
  start "$home" "$port" ensure >/dev/null || fail "the first ensure failed"
  pane=$(sed -n 's/^pane=//p' "$home/state/.dashboard-owner")
  # Herdr itself is unreachable: whether that pane still runs is now unknown,
  # and an unknown owner must not be declared dead.
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_DOWN=1 FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) && :
  assert_contains "$out" "DASHBOARD_BLOCKED" "an unreachable Herdr did not block"
  printf '%s' "$out" | grep -q '^FIRSTMATE_DASHBOARD_URL=' \
    && fail "a URL was reported while the owner could not be proven: $out"
  [ -f "$home/state/.dashboard-owner" ] \
    || fail "the owner record was dropped while its pane state was unknown"
  [ "$(sed -n 's/^pane=//p' "$home/state/.dashboard-owner")" = "$pane" ] \
    || fail "the unprovable owner record was replaced"
  pass "an owner that cannot be proven dead is never silently replaced"
}

test_a_health_mismatch_preserves_an_open_owner() {
  local home port first second original
  home=$(make_home health-mismatch)
  port=$(free_port)
  first=$(start "$home" "$port" ensure) || fail "the first ensure failed: $first"
  original=$(sed -n 's/^digest=//p' "$home/state/.dashboard-owner")
  sed -i '' 's/^digest=.*/digest=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$home/state/.dashboard-owner"
  second=$(start "$home" "$port" ensure 2>&1) && fail "a health mismatch was reported as reusable: $second"
  assert_contains "$second" "DASHBOARD_BLOCKED" "a health mismatch did not block startup"
  printf '%s' "$second" | grep -q '^FIRSTMATE_DASHBOARD_URL=' \
    && fail "a health mismatch produced a false URL"
  [ "$(cat "$home/herdr/panes/w1p1.state")" = open ] \
    || fail "a health mismatch closed the still-open owner pane"
  [ "$(sed -n 's/^digest=//p' "$home/state/.dashboard-owner")" != "$original" ] \
    || fail "the health mismatch test did not alter the owner proof"
  [ "$(pane_count "$home")" = "1" ] || fail "a health mismatch created a replacement pane"
  pass "a health mismatch preserves the open owner instead of reclaiming it"
}

test_a_lost_tab_creation_response_is_recovered_before_reporting() {
  local home port out
  home=$(make_home lost-tab-response)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_LOST_RESPONSE="tab create" FM_DASHBOARD_PORT="$port" \
    "$START" ensure 2>&1) || fail "a lost tab response was not recovered: $out"
  assert_contains "$out" "FIRSTMATE_DASHBOARD_URL=http://127.0.0.1:$port/" \
    "a recovered tab did not produce a verified URL"
  [ "$(pane_count "$home")" = "1" ] || fail "lost tab response recovery created duplicate panes"
  [ ! -e "$home/state/.dashboard-quarantine" ] || fail "a recoverable tab response was quarantined"
  pass "a lost tab creation response is recovered before the URL is reported"
}

test_a_lost_workspace_creation_response_is_recovered_before_reporting() {
  local home port out
  home=$(make_home lost-workspace-response)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_LOST_RESPONSE="workspace create" FM_DASHBOARD_PORT="$port" \
    "$START" ensure 2>&1) || fail "a lost workspace response was not recovered: $out"
  assert_contains "$out" "FIRSTMATE_DASHBOARD_URL=http://127.0.0.1:$port/" \
    "a recovered workspace did not produce a verified URL"
  [ "$(pane_count "$home")" = "1" ] || fail "lost workspace response recovery created duplicate panes"
  [ ! -e "$home/state/.dashboard-quarantine" ] || fail "a recoverable workspace response was quarantined"
  pass "a lost workspace creation response is recovered before the URL is reported"
}

test_lost_resource_recovery_is_quarantined_with_the_journaled_identity() {
  local home port out
  home=$(make_home lost-resource-recovery)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_LOST_RESPONSE="tab create,tab list" FM_DASHBOARD_PORT="$port" \
    "$START" ensure 2>&1) && fail "an unidentifiable resource was reported as successful: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "lost resource recovery did not block"
  [ ! -e "$home/state/.dashboard-owner" ] || fail "lost resource recovery published an owner"
  [ -f "$home/state/.dashboard-quarantine" ] || fail "lost resource recovery was not quarantined"
  grep -q '^label=firstmate-dashboard-' "$home/state/.dashboard-quarantine" \
    || fail "the quarantine omitted the journaled resource label"
  grep -q '^workspace=w1$' "$home/state/.dashboard-quarantine" \
    || fail "the quarantine omitted the recovered workspace identity"
  pass "lost resource recovery preserves the journaled identity in quarantine"
}

test_health_remains_responsive_while_a_client_stalls() {
  local home port slow
  home=$(make_home stalled-client)
  port=$(free_port)
  start "$home" "$port" ensure >/dev/null || fail "ensure failed"
  python3 - "$port" <<'PY' >"$home/stalled-client.log" 2>&1 &
import socket
import sys
import time

sock = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
sock.sendall(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n")
time.sleep(8)
PY
  slow=$!
  sleep 0.2
  curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null \
    || fail "a stalled page client prevented a health response"
  kill "$slow" 2>/dev/null || true
  wait "$slow" 2>/dev/null || true
  pass "a stalled client cannot block the dashboard health endpoint"
}

test_health_remains_admissible_behind_incomplete_clients() {
  local home port probe
  home=$(make_home incomplete-clients)
  port=$(free_port)
  start "$home" "$port" ensure >/dev/null || fail "ensure failed"
  probe=$(python3 - "$port" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
slow = []
for _ in range(9):
    sock = socket.create_connection(("127.0.0.1", port))
    slow.append(sock)
probe = socket.create_connection(("127.0.0.1", port))
time.sleep(0.5)
probe.sendall(b"GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
probe.settimeout(2)
response = probe.recv(256)
print(response.decode("latin1"), end="")
probe.close()
for sock in slow:
    sock.close()
PY
) || fail "the health probe could not pass incomplete-client saturation"
  printf '%s' "$probe" | grep -q '200 OK' \
    || fail "an incomplete-client admission race starved health: $probe"
  pass "health remains admissible behind incomplete clients"
}

test_a_drip_request_hits_an_absolute_http_deadline() {
  local home port out
  home=$(make_home drip-request)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FM_DASHBOARD_BUILD_TIMEOUT=2 FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) \
    || fail "ensure failed: $out"
  python3 - "$port" <<'PY'
import socket
import sys
import time

sock = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
sock.settimeout(1)
started = time.monotonic()
closed = False
try:
    for _ in range(20):
        sock.sendall(b"G")
        time.sleep(0.4)
except OSError:
    closed = True
finally:
    sock.close()
if not closed or time.monotonic() - started > 9:
    raise SystemExit(1)
PY
  [ "$?" -eq 0 ] || fail "a drip request was not bounded by an absolute deadline"
  pass "a drip request is closed by the absolute HTTP deadline"
}

test_a_timed_out_build_kills_its_descendant_group() {
  local home port out child code
  home=$(make_home killed-build-group)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FM_DASHBOARD_BUILD_TIMEOUT=1 FM_DASHBOARD_DESCENDANT_MARKER="$home/descendant.pid" \
    FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) \
    || fail "ensure failed: $out"
  cat > "$home/fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -u
marker="${FM_DASHBOARD_DESCENDANT_MARKER:?}"
if [ ! -e "$marker" ]; then
  MARKER="$marker" python3 -c '
import os
import subprocess
import time

child = subprocess.Popen(["sleep", "30"], start_new_session=True)
with open(os.environ["MARKER"], "w", encoding="utf-8") as marker:
    marker.write(str(child.pid) + "\n")
time.sleep(30)
'
fi
sleep 30
SH
  chmod +x "$home/fakebin/jq"
  code=$(curl -sS --max-time 6 -o "$home/timeout-response" \
    -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)
  [ "$code" = "500" ] || fail "a timed-out rebuild returned HTTP $code instead of 500"
  child=
  for _ in $(seq 1 20); do
    if [ -s "$home/descendant.pid" ]; then
      child=$(cat "$home/descendant.pid")
      break
    fi
    sleep 0.1
  done
  [ -n "$child" ] || fail "the timed-out build did not create its descendant marker"
  for _ in $(seq 1 20); do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
    fail "a timed-out build left a descendant process running"
  fi
  pass "a timed-out build kills its complete descendant process group"
}

test_an_unprovable_build_cleanup_fails_closed() {
  local home port out child code health
  home=$(make_home unprovable-build-cleanup)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FM_DASHBOARD_BUILD_TIMEOUT=1 FM_DASHBOARD_DESCENDANT_MARKER="$home/descendant.pid" \
    FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) \
    || fail "ensure failed: $out"
  cat > "$home/fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -u
marker="${FM_DASHBOARD_DESCENDANT_MARKER:?}"
if [ ! -e "$marker" ]; then
  MARKER="$marker" python3 -c '
import os
import subprocess
import time

child = subprocess.Popen(["sleep", "30"], start_new_session=True)
with open(os.environ["MARKER"], "w", encoding="utf-8") as marker:
    marker.write(str(child.pid) + "\n")
time.sleep(30)
'
fi
sleep 30
SH
  chmod +x "$home/fakebin/jq"
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/ps"
  code=$(curl -sS --max-time 6 -o "$home/timeout-response" \
    -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)
  [ "$code" = "500" ] || fail "an unprovable cleanup returned HTTP $code instead of 500"
  child=
  for _ in $(seq 1 20); do
    if [ -s "$home/descendant.pid" ]; then
      child=$(cat "$home/descendant.pid")
      break
    fi
    sleep 0.1
  done
  [ -n "$child" ] || fail "the unprovable cleanup fixture did not create its descendant marker"
  health=$(curl -sS --max-time 3 "http://127.0.0.1:$port/healthz" 2>/dev/null || true)
  printf '%s' "$health" | jq -e '.ready == false and .reason == "build descendant cleanup could not be proven"' >/dev/null \
    || fail "the dashboard claimed health after cleanup proof failed: $health"
  kill -KILL "$child" 2>/dev/null || true
  pass "an incomplete process snapshot fails dashboard health closed"
}

test_stop_preserves_an_owner_without_complete_proof() {
  local home port out
  home=$(make_home stop-unproven)
  port=$(free_port)
  start "$home" "$port" ensure >/dev/null || fail "ensure failed"
  sed -i '' 's/^digest=.*/digest=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$home/state/.dashboard-owner"
  out=$(start "$home" "$port" stop 2>&1) && fail "stop accepted an unproven owner: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "stop did not block an unproven owner"
  [ -f "$home/state/.dashboard-owner" ] || fail "stop dropped an unproven owner record"
  [ "$(cat "$home/herdr/panes/w1p1.state")" = open ] \
    || fail "stop closed a pane without complete owner proof"
  pass "stop preserves the pane and record until ownership is fully proven"
}

test_owner_lifecycle_uses_the_recorded_herdr_session() {
  local home port first second
  home=$(make_home recorded-session)
  port=$(free_port)
  first=$(start "$home" "$port" ensure) || fail "the first ensure failed: $first"
  second=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_PANE_GONE_SESSION=other HERDR_SESSION=other \
    FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) \
    || fail "the second ensure failed instead of adopting the recorded session: $second"
  assert_contains "$second" "already running" "the owner was not checked in its recorded session"
  [ "$(pane_count "$home")" = "1" ] || fail "a second pane was created after an ambient session change"
  pass "owner lifecycle checks remain bound to the recorded Herdr session"
}

test_a_mismatched_pane_identity_is_unknown_and_preserved() {
  local home port first second pane
  home=$(make_home wrong-pane)
  port=$(free_port)
  first=$(start "$home" "$port" ensure) || fail "the first ensure failed: $first"
  pane=$(sed -n 's/^pane=//p' "$home/state/.dashboard-owner")
  second=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_RETURN_PANE_ID=w1p99 FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) && \
    fail "a mismatched pane response was accepted: $second"
  assert_contains "$second" "DASHBOARD_BLOCKED" "a mismatched pane response was not treated as unknown"
  [ "$(sed -n 's/^pane=//p' "$home/state/.dashboard-owner")" = "$pane" ] \
    || fail "the owner record was replaced after an identity mismatch"
  [ "$(pane_count "$home")" = "1" ] || fail "a second pane was created after an identity mismatch"
  pass "a mismatched Herdr pane identity is unknown and the owner is preserved"
}

test_a_new_pane_response_is_verified_before_running_the_dashboard() {
  local home port out
  home=$(make_home unverified-pane)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_RETURN_PANE_ID=w1p99 FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) && \
    fail "startup accepted an unverified pane response: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "an unverified pane response did not block startup"
  [ ! -e "$home/herdr/panes/w1p1.pid" ] \
    || fail "startup ran the dashboard before proving the returned pane identity"
  [ ! -e "$home/state/.dashboard-owner" ] \
    || fail "startup published an owner after an unverified pane response"
  pass "startup verifies the exact pane identity before running the dashboard"
}

test_a_malformed_workspace_identity_is_not_used_for_creation() {
  local home port out
  home=$(make_home malformed-workspace)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_MALFORMED_ID=workspace FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) \
    || fail "startup failed while recovering a malformed workspace response: $out"
  [ "$(sed -n 's/^workspace=//p' "$home/state/.dashboard-owner")" = w1 ] \
    || fail "startup published the malformed workspace identity"
  [ ! -e "$home/herdr/tabs/7:t1.label" ] \
    || fail "startup used the malformed workspace identity for tab creation"
  pass "startup rejects malformed Herdr identities before lifecycle use"
}

test_a_foreign_listener_is_a_collision_not_an_adoption() {
  local home port foreign out url
  home=$(make_home collision)
  port=$(free_port)
  foreign=$(start_foreign_listener "$port" "$home/foreign.log")
  wait_for_port "$port" || { kill "$foreign" 2>/dev/null; fail "the foreign listener never came up"; }
  out=$(start "$home" "$port" ensure) || fail "ensure failed beside a foreign listener: $out"
  url=$(url_in "$out")
  [ -n "$url" ] || fail "no URL was reported: $out"
  [ "$url" != "http://127.0.0.1:$port/" ] \
    || fail "the foreign listener's port was claimed as the dashboard: $out"
  curl -fsS --max-time 3 "${url}healthz" | jq -e --arg home "$home" '.home == $home' >/dev/null \
    || fail "the reported URL is not this home's dashboard"
  kill "$foreign" 2>/dev/null || true
  pass "a foreign listener is treated as a port collision, never adopted"
}

test_a_dashboard_for_another_home_is_not_adopted() {
  local other port out url
  other=$(make_home other-home)
  port=$(free_port)
  start "$other" "$port" ensure >/dev/null || fail "the other home's dashboard failed to start"
  local home
  home=$(make_home mine)
  out=$(start "$home" "$port" ensure) || fail "ensure failed: $out"
  url=$(url_in "$out")
  [ "$url" != "http://127.0.0.1:$port/" ] \
    || fail "another home's dashboard was adopted as this home's: $out"
  curl -fsS --max-time 3 "${url}healthz" | jq -e --arg home "$home" '.home == $home' >/dev/null \
    || fail "the reported URL belongs to the wrong home"
  pass "a dashboard serving a different home is not adopted as this one"
}

test_no_url_is_printed_when_readiness_cannot_be_proven() {
  local home port out
  home=$(make_home never-ready)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_FAIL="pane run" FM_DASHBOARD_PORT="$port" \
    FM_DASHBOARD_READY_TRIES=2 FM_DASHBOARD_READY_DELAY_MS=50 \
    "$START" ensure 2>&1) && :
  printf '%s' "$out" | grep -q '^FIRSTMATE_DASHBOARD_URL=' \
    && fail "a URL was printed although the dashboard never started: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "an unstartable dashboard did not report a blocker"
  [ ! -f "$home/state/.dashboard-owner" ] \
    || fail "a failed start left an owner record behind"
  grep -q 'blocked' "$home/state/.dashboard-start.log" \
    || fail "the failure was not written to the durable diagnostics"
  pass "no URL is printed when readiness cannot be proven, and the failure is durable"
}

test_a_missing_runtime_blocks_instead_of_guessing() {
  local home port out
  home=$(make_home no-herdr)
  port=$(free_port)
  out=$(PATH="$home/emptybin:/usr/bin:/bin" FM_HOME="$home" \
    FM_DASHBOARD_PORT="$port" "$START" ensure 2>&1) && :
  printf '%s' "$out" | grep -q '^FIRSTMATE_DASHBOARD_URL=' \
    && fail "a URL was printed with no runtime available: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "a missing runtime did not report a blocker"
  pass "a missing runtime blocks with a named reason instead of guessing"
}

test_a_hung_herdr_call_is_bounded_and_blocks() {
  local home port out
  home=$(make_home hung-herdr)
  port=$(free_port)
  printf '#!/usr/bin/env bash\nsleep 10\n' > "$home/fakebin/hanging-herdr"
  chmod +x "$home/fakebin/hanging-herdr"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_DASHBOARD_PORT="$port" FM_DASHBOARD_HERDR_CLI="$home/fakebin/hanging-herdr" \
    FM_DASHBOARD_HERDR_TIMEOUT=1 "$START" ensure 2>&1) && :
  printf '%s' "$out" | grep -q '^FIRSTMATE_DASHBOARD_URL=' \
    && fail "a URL was printed after a Herdr call hung: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "a hung Herdr call did not produce a blocker"
  pass "a hung Herdr call is bounded and produces a durable startup blocker"
}

test_a_symlinked_state_boundary_is_refused_without_outside_writes() {
  local home outside out
  home=$(make_home symlink-state)
  outside="$TMP_ROOT/outside-state"
  mkdir -p "$outside"
  rm -rf "$home/state"
  ln -s "$outside" "$home/state"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FM_DASHBOARD_PORT="$(free_port)" "$START" ensure 2>&1) && \
    fail "a symlinked state directory was accepted: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "the symlinked state refusal was unclear"
  [ ! -e "$outside/.dashboard-owner" ] || fail "the owner record escaped through a state symlink"
  [ ! -e "$outside/.dashboard-start.log" ] || fail "the diagnostics escaped through a state symlink"
  pass "a symlinked startup state boundary is refused before outside writes"
}

test_a_symlinked_start_lock_is_refused() {
  local home target out
  home=$(make_home symlink-lock)
  target="$home/state/lock-target"
  mkdir -p "$target"
  ln -s "$target" "$home/state/.dashboard-start.lock"
  out=$(start "$home" "$(free_port)" ensure 2>&1) && fail "a symlinked startup lock was accepted: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "the symlinked startup lock refusal was unclear"
  [ ! -e "$home/state/.dashboard-owner" ] || fail "a symlinked startup lock allowed owner publication"
  pass "a symlinked startup lock is refused before lifecycle state is written"
}

test_a_torn_lock_with_a_reused_pid_is_recovered() {
  local home port out
  home=$(make_home torn-lock)
  port=$(free_port)
  mkdir -p "$home/state/.dashboard-start.lock"
  printf '%s\n' "$$" > "$home/state/.dashboard-start.lock/pid"
  out=$(start "$home" "$port" ensure) || fail "a torn lock with an unrelated live pid blocked recovery: $out"
  printf '%s' "$out" | grep -q '^FIRSTMATE_DASHBOARD_URL=' \
    || fail "torn lock recovery did not publish a verified URL: $out"
  pass "a torn startup lock with a reused unrelated pid is recovered"
}

test_failed_cleanup_is_quarantined_before_retry() {
  local home port out
  home=$(make_home cleanup-quarantine)
  port=$(free_port)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FAKE_HERDR_FAIL="pane run" FAKE_HERDR_CLOSE_FAIL=1 FM_DASHBOARD_PORT="$port" \
    "$START" ensure 2>&1) && fail "an orphaned launch was reported as successful: $out"
  assert_contains "$out" "DASHBOARD_BLOCKED" "failed cleanup did not block startup"
  [ -f "$home/state/.dashboard-quarantine" ] || fail "failed cleanup was not durably quarantined"
  printf '%s' "$out" | grep -q '^FIRSTMATE_DASHBOARD_URL=' \
    && fail "a URL was printed after cleanup became uncertain"
  pass "uncertain launch cleanup is durably quarantined before another start"
}

test_no_free_port_blocks_without_a_url() {
  local home port out
  home=$(make_home no-port)
  port=$(free_port)
  local foreign
  foreign=$(start_foreign_listener "$port" "$home/foreign.log")
  wait_for_port "$port" || { kill "$foreign" 2>/dev/null; fail "the foreign listener never came up"; }
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_STATE="$home/herdr" \
    FM_DASHBOARD_PORT="$port" FM_DASHBOARD_PORT_TRIES=1 "$START" ensure 2>&1) && :
  kill "$foreign" 2>/dev/null || true
  printf '%s' "$out" | grep -q '^FIRSTMATE_DASHBOARD_URL=' \
    && fail "a URL was printed with no free port: $out"
  assert_contains "$out" "no free port" "the refusal did not name the exhausted port range"
  pass "an exhausted port range blocks without reporting a URL"
}

test_status_reports_without_changing_anything() {
  local home port out before after
  home=$(make_home status-readonly)
  port=$(free_port)
  start "$home" "$port" ensure >/dev/null || fail "ensure failed"
  before=$(cat "$home/state/.dashboard-owner")
  out=$(start "$home" "$port" status) || fail "status failed: $out"
  after=$(cat "$home/state/.dashboard-owner")
  [ "$before" = "$after" ] || fail "status modified the owner record"
  [ "$(pane_count "$home")" = "1" ] || fail "status created a pane"
  assert_contains "$out" "live: yes" "status did not report the live owner"
  printf '%s' "$out" | grep -q 'token' \
    && fail "status printed the private owner token"
  pass "status reports the owner without changing anything or leaking the token"
}

test_read_only_status_probe_does_not_write_a_lifecycle_lock() {
  local home port out
  home=$(make_home read-only-status-probe)
  port=$(free_port)
  chmod 0500 "$home/state"
  out=$(start "$home" "$port" status-read-only) || {
    chmod 0700 "$home/state"
    fail "the read-only status probe required writable lifecycle state: $out"
  }
  chmod 0700 "$home/state"
  assert_contains "$out" "no owner recorded" \
    "the read-only status probe did not report the empty owner state"
  [ ! -e "$home/state/.dashboard-start.lock" ] \
    || fail "the read-only status probe created a lifecycle lock"
  pass "the read-only status probe reports state without writing a lifecycle lock"
}

test_stop_closes_the_pane_and_releases_the_port() {
  local home port out
  home=$(make_home stop)
  port=$(free_port)
  start "$home" "$port" ensure >/dev/null || fail "ensure failed"
  out=$(start "$home" "$port" stop) || fail "stop failed: $out"
  assert_contains "$out" "stopped" "stop did not report the closure"
  [ ! -f "$home/state/.dashboard-owner" ] || fail "stop left the owner record behind"
  sleep 1
  curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 \
    && fail "the dashboard is still listening after stop"
  pass "stop closes the pane, releases the port, and drops the record"
}

test_a_fresh_start_proves_readiness_before_it_prints_a_url
test_a_repeat_start_adopts_the_running_dashboard
test_a_nonregular_owner_target_blocks_without_orphaning_the_new_pane
test_concurrent_starts_converge_on_one_dashboard
test_a_dead_owner_is_replaced_rather_than_reported
test_an_unprovable_owner_is_never_silently_replaced
test_a_health_mismatch_preserves_an_open_owner
test_a_lost_tab_creation_response_is_recovered_before_reporting
test_a_lost_workspace_creation_response_is_recovered_before_reporting
test_lost_resource_recovery_is_quarantined_with_the_journaled_identity
test_health_remains_responsive_while_a_client_stalls
test_health_remains_admissible_behind_incomplete_clients
test_a_drip_request_hits_an_absolute_http_deadline
test_a_timed_out_build_kills_its_descendant_group
test_an_unprovable_build_cleanup_fails_closed
test_stop_preserves_an_owner_without_complete_proof
test_owner_lifecycle_uses_the_recorded_herdr_session
test_a_mismatched_pane_identity_is_unknown_and_preserved
test_a_new_pane_response_is_verified_before_running_the_dashboard
test_a_malformed_workspace_identity_is_not_used_for_creation
test_a_foreign_listener_is_a_collision_not_an_adoption
test_a_dashboard_for_another_home_is_not_adopted
test_no_url_is_printed_when_readiness_cannot_be_proven
test_a_missing_runtime_blocks_instead_of_guessing
test_a_hung_herdr_call_is_bounded_and_blocks
test_a_symlinked_state_boundary_is_refused_without_outside_writes
test_a_symlinked_start_lock_is_refused
test_a_torn_lock_with_a_reused_pid_is_recovered
test_failed_cleanup_is_quarantined_before_retry
test_no_free_port_blocks_without_a_url
test_status_reports_without_changing_anything
test_read_only_status_probe_does_not_write_a_lifecycle_lock
test_stop_closes_the_pane_and_releases_the_port
