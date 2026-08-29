#!/usr/bin/env bash
# A deterministic stand-in for the Herdr CLI, covering exactly the surface
# bin/fm-dashboard-start.sh uses: workspace list/create, tab create, and pane
# run/get/close. It answers the same JSON shapes the real CLI answers, verified
# against Herdr 0.8.2 in an isolated lab session.
#
# It is a TEST DOUBLE for a process supervisor. It backgrounds the command it is
# asked to run because that is what the real Herdr server does on the other side
# of its socket; the product code under test never backgrounds anything itself,
# it only ever asks a supervisor to run something.
#
# FAKE_HERDR_STATE selects its state directory.
# FAKE_HERDR_FAIL names a subcommand pair that must fail ("tab create",
# "pane run", "workspace list") so a test can drive a Herdr-side failure.
# FAKE_HERDR_DOWN makes every call fail, modelling an unreachable Herdr server.
set -u

STATE=${FAKE_HERDR_STATE:?fake-herdr needs FAKE_HERDR_STATE}
mkdir -p "$STATE/panes"

# FAKE_HERDR_DOWN models an unreachable Herdr server: every call fails, which
# is what makes a pane's state genuinely UNKNOWN rather than merely absent.
if [ -n "${FAKE_HERDR_DOWN:-}" ]; then
  echo "fake-herdr: server unreachable" >&2
  exit 1
fi

fail_if_requested() {  # <subcommand-pair>
  [ "${FAKE_HERDR_FAIL:-}" = "$1" ] || return 0
  echo "fake-herdr: forced failure for $1" >&2
  exit 1
}

# Drop the flags the caller passes; capture only the values this double needs.
WORKSPACE=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session|--workspace|--cwd|--label)
      [ "$1" = --workspace ] && WORKSPACE=${2:-}
      shift 2 || shift
      ;;
    --focus|--no-focus) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- ${args+"${args[@]}"}

next_id() {  # <counter-name>
  local file="$STATE/$1.seq" n
  n=$(cat "$file" 2>/dev/null || echo 0)
  n=$((n + 1))
  printf '%s\n' "$n" > "$file"
  printf '%s' "$n"
}

case "${1:-}:${2:-}" in
  workspace:list)
    fail_if_requested "workspace list"
    if [ -f "$STATE/workspace" ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"%s"}]}}\n' "$(cat "$STATE/workspace")"
    else
      printf '{"result":{"workspaces":[]}}\n'
    fi
    ;;
  workspace:create)
    fail_if_requested "workspace create"
    printf 'w1\n' > "$STATE/workspace"
    printf '{"result":{"workspace":{"workspace_id":"w1"}}}\n'
    ;;
  tab:create)
    fail_if_requested "tab create"
    n=$(next_id tab)
    [ -n "$WORKSPACE" ] || WORKSPACE=w1
    printf 'open\n' > "$STATE/panes/${WORKSPACE}p${n}.state"
    printf '{"result":{"tab":{"tab_id":"%s:t%s"},"root_pane":{"pane_id":"%sp%s"}}}\n' \
      "$WORKSPACE" "$n" "$WORKSPACE" "$n"
    ;;
  pane:get)
    pane=${3:-}
    if [ "$(cat "$STATE/panes/$pane.state" 2>/dev/null)" = open ]; then
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
    else
      echo "fake-herdr: no such pane: $pane" >&2
      exit 1
    fi
    ;;
  pane:run)
    fail_if_requested "pane run"
    pane=${3:-}
    [ "$(cat "$STATE/panes/$pane.state" 2>/dev/null)" = open ] || {
      echo "fake-herdr: no such pane: $pane" >&2; exit 1; }
    shift 3
    # Own a process group so closing the pane reclaims the whole tree, exactly
    # as closing a real pane reclaims everything running in it.
    perl -e 'setpgrp(0,0); exec @ARGV or exit 127' -- "$@" \
      >> "$STATE/panes/$pane.out" 2>&1 &
    printf '%s\n' "$!" > "$STATE/panes/$pane.pid"
    printf '{"result":{"type":"ok"}}\n'
    ;;
  pane:close)
    pane=${3:-}
    pid=$(cat "$STATE/panes/$pane.pid" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    printf 'closed\n' > "$STATE/panes/$pane.state"
    printf '{"result":{"type":"ok"}}\n'
    ;;
  *)
    echo "fake-herdr: unsupported command: $*" >&2
    exit 2
    ;;
esac
