#!/usr/bin/env bash
# Real-Herdr smoke for dashboard startup (bin/fm-dashboard-start.sh).
#
# The deterministic suite (tests/fm-dashboard-start.test.sh) doubles Herdr, so
# it proves the ownership logic but cannot prove the Herdr calls themselves are
# the right calls. This one runs the real CLI: a real tab, a real `pane run`, a
# real server answering a real loopback port, and a real `pane close` that
# reclaims it.
#
# ISOLATION IS MANDATORY. The captain's fleet lives in the `default` session, so
# every Herdr call here is routed through bin/fm-herdr-lab.sh into a
# `fm-lab-*` session, and teardown is armed BEFORE anything is provisioned. The
# helper re-checks refuse-default immediately before each destructive call and
# verifies the live default session is untouched afterwards. Nothing in this
# file ever calls `herdr` directly.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

START="$ROOT/bin/fm-dashboard-start.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
LAB="$ROOT/bin/fm-herdr-lab.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-herdr-smoke)

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

# The real server refuses to bind unless its bounded build containment is
# available.  GitHub's Linux runner can provide `unshare` while denying the
# namespace operation, so check the capability rather than treating the
# server's deliberate fail-closed response as a Herdr lifecycle failure.
containment_available() {
  case "$(uname -s)" in
    Linux)
      command -v unshare >/dev/null 2>&1 || return 1
      unshare --pid --fork --mount-proc --kill-child=9 true >/dev/null 2>&1
      ;;
    Darwin)
      command -v sandbox-exec >/dev/null 2>&1 || return 1
      if sandbox-exec -p '(version 1) (allow default) (deny network-inbound)' \
        python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0))' \
        >/dev/null 2>&1; then
        return 1
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}

containment_available || {
  echo "skip: dashboard Herdr smoke requires available process containment"
  exit 0
}

LAB_SESSION=$("$LAB" name fm-dash-smoke) || { echo "skip: could not name a lab session"; exit 0; }

lab_teardown() {
  [ -n "${LAB_PROVISIONED:-}" ] || return 0
  "$LAB" teardown "$LAB_SESSION" >/dev/null 2>&1 \
    || echo "warning: the lab session $LAB_SESSION could not be torn down" >&2
}
# Armed before provisioning, so an interrupted run still reclaims the session.
trap 'lab_teardown; fm_test_cleanup' EXIT
trap 'lab_teardown; fm_test_cleanup; exit 130' INT
trap 'lab_teardown; fm_test_cleanup; exit 143' TERM

"$LAB" provision "$LAB_SESSION" >/dev/null 2>&1 || {
  echo "skip: could not provision the isolated lab session $LAB_SESSION"
  exit 0
}
LAB_PROVISIONED=1

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
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# FM_DASHBOARD_HERDR_CLI is the seam that keeps this smoke inside the lab: every
# Herdr call the command makes is prefixed with the guarded helper, which
# appends the trailing --session itself and refuses anything destructive or
# default-scoped.
start() {  # <home> <port> <args...>
  local home=$1 port=$2
  shift 2
  FM_HOME="$home" FM_DASHBOARD_PORT="$port" \
    FM_DASHBOARD_HERDR_CLI="$LAB run $LAB_SESSION" \
    "$START" "$@" 2>&1
}

test_a_real_herdr_pane_serves_the_dashboard_and_reports_its_url() {
  local home port out url health pane
  home=$(make_home real)
  port=$(free_port)

  out=$(start "$home" "$port" ensure) || fail "ensure failed against real herdr: $out"
  url=$(printf '%s' "$out" | sed -n 's/^FIRSTMATE_DASHBOARD_URL=//p')
  [ "$url" = "http://127.0.0.1:$port/" ] \
    || fail "the reported URL is wrong: $out"

  health=$(curl -fsS --max-time 5 "${url}healthz") \
    || fail "the URL reported from a real herdr pane does not answer"
  printf '%s' "$health" | jq -e --arg home "$home" '
    .schema == "fm-dashboard-health.v1" and .home == $home and .ready == true' >/dev/null \
    || fail "the real pane is not serving this home's dashboard: $health"

  curl -fsS --max-time 10 "$url" | grep -q 'fm-dashboard-data' \
    || fail "the served page does not carry the dashboard payload"

  pane=$(sed -n 's/^pane=//p' "$home/state/.dashboard-owner")
  [ -n "$pane" ] || fail "no pane was recorded"
  "$LAB" run "$LAB_SESSION" pane get "$pane" >/dev/null 2>&1 \
    || fail "the recorded pane does not exist in the lab session"

  # Idempotence against the real CLI, not just against the double.
  out=$(start "$home" "$port" ensure) || fail "the repeat ensure failed: $out"
  printf '%s' "$out" | grep -q "^FIRSTMATE_DASHBOARD_URL=$url$" \
    || fail "the repeat ensure reported a different URL: $out"
  assert_contains "$out" "already running" "the repeat ensure did not adopt the running pane"

  out=$(start "$home" "$port" stop) || fail "stop failed: $out"
  sleep 1
  curl -fsS --max-time 3 "${url}healthz" >/dev/null 2>&1 \
    && fail "closing the real pane did not reclaim the dashboard"
  pass "a real herdr pane serves the dashboard, adopts on repeat, and is reclaimed by stop"
}

test_real_herdr_session_start_reports_and_reclaims_the_dashboard() {
  local home port out url health pane
  home=$(make_home session-start)
  port=$(free_port)

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_PORT="$port" \
    FM_DASHBOARD_HERDR_CLI="$LAB run $LAB_SESSION" \
    "$SESSION_START" --source startup 2>&1) \
    || fail "session start failed against real herdr: $out"
  url=$(printf '%s' "$out" | sed -n 's/^FIRSTMATE_DASHBOARD_URL=//p')
  [ "$url" = "http://127.0.0.1:$port/" ] \
    || fail "session start did not print the proven URL: $out"
  health=$(curl -fsS --max-time 5 "${url}healthz") \
    || fail "the session-start URL does not answer"
  printf '%s' "$health" | jq -e --arg home "$home" '.home == $home and .ready == true' >/dev/null \
    || fail "session start reported the wrong dashboard: $health"
  pane=$(sed -n 's/^pane=//p' "$home/state/.dashboard-owner")
  [ -n "$pane" ] || fail "session start did not record a dashboard pane"
  "$LAB" run "$LAB_SESSION" pane get "$pane" >/dev/null 2>&1 \
    || fail "the session-start dashboard pane is not in the lab"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DASHBOARD_HERDR_CLI="$LAB run $LAB_SESSION" \
    "$START" stop >/dev/null 2>&1 \
    || fail "stopping the session-start dashboard failed"
  sleep 1
  curl -fsS --max-time 3 "${url}healthz" >/dev/null 2>&1 \
    && fail "session-start dashboard cleanup left the server running"
  "$LAB" run "$LAB_SESSION" pane get "$pane" >/dev/null 2>&1 \
    && fail "session-start dashboard cleanup left the Herdr pane open"
  pass "real Herdr session start reports a ready URL and fully cleans it up"
}

test_a_real_herdr_pane_serves_the_dashboard_and_reports_its_url
test_real_herdr_session_start_reports_and_reclaims_the_dashboard
