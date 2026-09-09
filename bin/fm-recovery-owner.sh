#!/usr/bin/env bash
# fm-recovery-owner.sh - one OS-managed, unprivileged recovery owner per
# Firstmate home, independent of both Pi's and Herdr's own lifetime.
#
# WHY THIS EXISTS. Continuity establishment (bin/fm-herdr-supervisor.sh
# `ensure`) previously depended on being called by something that itself
# might not outlive a session: the Pi extension, or a manually re-armed
# watcher. This script is a small, always-restartable caller of that same
# `ensure` command, registered with the host OS's own service manager
# (launchd on macOS, a systemd user unit on Linux) so its own lifetime does
# not depend on Pi or on any one harness session. It never becomes a second
# implementation of continuity establishment: `ensure` remains the sole
# owner of that decision (idempotent, safe to repeat, already hardened
# against a false claim-acquisition alarm - see bin/fm-herdr-supervisor.sh).
# Herdr remains the sole worker-execution backend; this changes only where
# the periodic call to `ensure` originates, never what runs tasks.
#
# LEGACY BOUNDARY. Every process already running when this owner is first
# installed - Pi's own session-start supervisor, a manually armed watcher,
# an existing Herdr-hosted supervision loop - is legacy relative to this
# owner. This script never inspects, adopts, or terminates any of them; it
# only manages the identity of its own `run` process. `ensure` is already
# idempotent, so a legacy caller and this owner calling it concurrently is
# safe by construction, not something this script needs to coordinate.
#
# LAUNCH-INTENT RECORD. Before the `run` loop does anything else it writes
# state/.recovery-owner-intent (created_at, generation, home) BEFORE binding
# its own actual pid/identity, so a crash between intent and binding leaves
# an explicit, inspectable partial-launch record rather than silence. Once
# the loop is actually running it writes state/.recovery-owner (pid, a
# process-identity string immune to plain PID reuse, the same generation,
# started_at) - the durable claim to being *this* home's current owner.
# Unknown/partial state is never promoted to "confirmed running."
#
# TERMINATION CONTRACT. `run` installs a real SIGTERM/SIGINT trap that exits
# the loop promptly and clears its own record, so `stop` (SIGTERM, bounded
# wait, SIGKILL escalation only if still alive after that bound) always has
# a live process to signal rather than one that ignores termination and
# depends solely on an external escalation path. `stop` never signals an
# unowned or identity-mismatched pid.
#
# SCOPE. This is the smallest coherent owner: it starts, stops, reports its
# own status, and calls `ensure` on a bounded interval when Herdr looks
# available. It does not restart the shared Herdr server, does not install
# or activate itself in the primary home from this task's own testing, and
# defers the full fault-injection resilience proof to the plan's final
# milestone - this increment proves basic start/stop/status/reconciliation,
# not exhaustive crash-matrix survival.
#
# Usage: fm-recovery-owner.sh install|uninstall|start|stop|status|run

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE" 2>/dev/null || true

RECORD="$STATE/.recovery-owner"
INTENT="$STATE/.recovery-owner-intent"
LOG="$STATE/.recovery-owner.log"

RECOVERY_OWNER_INTERVAL_DEFAULT=60
RECOVERY_OWNER_INTERVAL=${FM_RECOVERY_OWNER_INTERVAL:-$RECOVERY_OWNER_INTERVAL_DEFAULT}
case "$RECOVERY_OWNER_INTERVAL" in
  ''|*[!0-9]*|0) RECOVERY_OWNER_INTERVAL=$RECOVERY_OWNER_INTERVAL_DEFAULT ;;
esac

RECOVERY_OWNER_STOP_TIMEOUT_DEFAULT=10
RECOVERY_OWNER_STOP_TIMEOUT=${FM_RECOVERY_OWNER_STOP_TIMEOUT:-$RECOVERY_OWNER_STOP_TIMEOUT_DEFAULT}
case "$RECOVERY_OWNER_STOP_TIMEOUT" in
  ''|*[!0-9]*|0) RECOVERY_OWNER_STOP_TIMEOUT=$RECOVERY_OWNER_STOP_TIMEOUT_DEFAULT ;;
esac

RECOVERY_OWNER_START_WAIT_DEFAULT=5
RECOVERY_OWNER_START_WAIT=${FM_RECOVERY_OWNER_START_WAIT:-$RECOVERY_OWNER_START_WAIT_DEFAULT}
case "$RECOVERY_OWNER_START_WAIT" in
  ''|*[!0-9]*|0) RECOVERY_OWNER_START_WAIT=$RECOVERY_OWNER_START_WAIT_DEFAULT ;;
esac

# Test-only seam: never used for anything but pointing at a fixture stand-in
# for bin/fm-herdr-supervisor.sh itself. Production always resolves the real
# sibling script.
HERDR_SUPERVISOR_BIN=${FM_HERDR_SUPERVISOR_BIN:-$SCRIPT_DIR/fm-herdr-supervisor.sh}

usage() {
  cat <<'EOF'
Usage: fm-recovery-owner.sh <command>

Commands:
  install    Generate the launchd (macOS) or systemd user (Linux) unit for
             this exact home and load/enable it through the host service
             manager. Never touches any other process.
  uninstall  Unload/disable and remove the installed unit. Does not stop a
             separately started `run` process; use `stop` first.
  start      Start the owner directly (bypassing the OS service manager),
             for local testing. Idempotent: reports already-running when a
             live, identity-verified owner is already recorded.
  stop       Stop the recorded owner: SIGTERM, bounded wait, SIGKILL
             escalation only if still alive after the bound, then clear the
             record. Idempotent; reports not-running when nothing is owned.
  status     Read-only report of the recorded owner's identity and
             liveness. Never signals anything.
  run        The supervised loop. Launched by `start`/the OS service
             manager; safe to invoke directly for a bounded local test, but
             it blocks until stopped.

Environment (all optional, all bounded):
  FM_RECOVERY_OWNER_INTERVAL       seconds between ensure calls (default 60)
  FM_RECOVERY_OWNER_STOP_TIMEOUT   seconds to wait for SIGTERM before
                                   escalating to SIGKILL (default 10)
  FM_RECOVERY_OWNER_START_WAIT     seconds `start` waits for the new process
                                   to bind its own record (default 5)

Exit codes:
  0  success, or already in the requested state
  1  failed or ambiguous
  2  usage error
EOF
}

_now() { date +%s; }

_new_generation() {
  local rand
  rand=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$rand" ] || rand=$(fm_current_pid)
  printf '%s.%s' "$(_now)" "$rand"
}

# Atomic write: never leaves a half-written record for a concurrent reader.
_record_write() {  # <path> <key=value>...
  local path=$1 tmp
  shift
  tmp="$path.tmp.$(fm_current_pid)"
  {
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path" 2>/dev/null
}

_record_get() {  # <path> <key>
  [ -f "$1" ] || return 1
  local line
  line=$(grep -m1 "^$2=" "$1" 2>/dev/null) || return 1
  printf '%s' "${line#*=}"
}

# owner_alive: 0 only when the record names a live pid whose CURRENT identity
# still matches what was recorded - never true from PID presence alone (a
# reused pid must not read as the same owner).
_owner_alive() {
  local pid identity current
  pid=$(_record_get "$RECORD" pid) || return 1
  identity=$(_record_get "$RECORD" identity) || return 1
  [ -n "$pid" ] && [ -n "$identity" ] || return 1
  fm_pid_alive "$pid" || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$identity" ]
}

_log() {  # <line>
  printf '%s\t%s\n' "$(_now)" "$1" >> "$LOG" 2>/dev/null || true
}

# herdr_available: a cheap, read-only check. This owner never attempts to
# start, stop, or otherwise operate the shared Herdr server; if it looks
# unavailable this tick, skip the ensure call rather than error-looping.
_herdr_available() {
  command -v herdr >/dev/null 2>&1
}

cmd_run() {
  local generation pid identity stop=0
  # Never capture our OWN pid through a $(...) command substitution: bash
  # forks a subshell for every command substitution, so fm_current_pid
  # called that way would read back the subshell's pid, not this process's -
  # a real instance of the exact BASHPID-in-subshells subtlety this task's
  # own recovery diagnostic flagged. Read $$/BASHPID inline instead.
  pid=${BASHPID:-$$}
  generation=$(_new_generation)

  # Intent BEFORE any binding: a crash right here leaves an inspectable
  # partial-launch record, never silence.
  _record_write "$INTENT" \
    "created_at=$(_now)" \
    "generation=$generation" \
    "home=$FM_HOME" \
    "intended_pid=$pid" \
    || { _log "failed to persist launch intent"; return 1; }

  identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
    _log "could not compute own process identity; refusing to bind an unverifiable record"
    return 1
  }

  _record_write "$RECORD" \
    "pid=$pid" \
    "identity=$identity" \
    "generation=$generation" \
    "started_at=$(_now)" \
    "home=$FM_HOME" \
    || { _log "failed to bind owner record after intent"; return 1; }

  trap 'stop=1' TERM INT

  _log "started generation=$generation pid=$pid"

  while [ "$stop" -eq 0 ]; do
    if _herdr_available; then
      if "$HERDR_SUPERVISOR_BIN" ensure --reason "os-managed recovery owner tick" >/dev/null 2>&1; then
        _log "ensure ok"
      else
        _log "ensure returned non-zero; will retry next tick"
      fi
    else
      _log "herdr unavailable this tick; skipped ensure, not attempting to operate it"
    fi
    # Sleep in short slices so a signal is honored promptly rather than only
    # after a long single sleep returns.
    local slept=0
    while [ "$stop" -eq 0 ] && [ "$slept" -lt "$RECOVERY_OWNER_INTERVAL" ]; do
      sleep 1 &
      wait $! 2>/dev/null || true
      slept=$((slept + 1))
    done
  done

  _log "stop signal received generation=$generation pid=$pid"
  rm -f "$RECORD" "$INTENT" 2>/dev/null || true
  return 0
}

cmd_start() {
  if _owner_alive; then
    printf 'fm-recovery-owner: already running (pid %s)\n' "$(_record_get "$RECORD" pid)"
    return 0
  fi
  rm -f "$RECORD" "$INTENT" 2>/dev/null || true
  nohup "$SCRIPT_DIR/fm-recovery-owner.sh" run >>"$LOG" 2>&1 &
  disown 2>/dev/null || true

  local waited=0
  while [ "$waited" -lt "$RECOVERY_OWNER_START_WAIT" ]; do
    if _owner_alive; then
      printf 'fm-recovery-owner: started (pid %s)\n' "$(_record_get "$RECORD" pid)"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf 'fm-recovery-owner: did not confirm a bound record within %ss\n' "$RECOVERY_OWNER_START_WAIT" >&2
  return 1
}

cmd_stop() {
  if ! _owner_alive; then
    printf 'fm-recovery-owner: not running\n'
    rm -f "$RECORD" "$INTENT" 2>/dev/null || true
    return 0
  fi
  local pid waited
  pid=$(_record_get "$RECORD" pid)
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt "$RECOVERY_OWNER_STOP_TIMEOUT" ]; do
    _owner_alive || break
    sleep 1
    waited=$((waited + 1))
  done
  if _owner_alive; then
    kill -KILL "$pid" 2>/dev/null || true
    waited=0
    while [ "$waited" -lt "$RECOVERY_OWNER_STOP_TIMEOUT" ] && _owner_alive; do
      sleep 1
      waited=$((waited + 1))
    done
  fi
  if _owner_alive; then
    printf 'fm-recovery-owner: pid %s did not exit after SIGTERM and SIGKILL\n' "$pid" >&2
    return 1
  fi
  rm -f "$RECORD" "$INTENT" 2>/dev/null || true
  printf 'fm-recovery-owner: stopped (was pid %s)\n' "$pid"
  return 0
}

cmd_status() {
  if _owner_alive; then
    printf 'state: running\n'
    printf 'pid: %s\n' "$(_record_get "$RECORD" pid)"
    printf 'generation: %s\n' "$(_record_get "$RECORD" generation)"
    printf 'started_at: %s\n' "$(_record_get "$RECORD" started_at)"
    return 0
  fi
  if [ -f "$INTENT" ] && [ ! -f "$RECORD" ]; then
    printf 'state: intent-only (partial launch, never bound - inspect and reconcile manually)\n'
    printf 'generation: %s\n' "$(_record_get "$INTENT" generation)"
    return 1
  fi
  printf 'state: not running\n'
  return 1
}

_home_slug() {
  printf '%s' "$FM_HOME" | LC_ALL=C tr -c 'A-Za-z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//'
}

_launchd_label() {
  printf 'com.firstmate.recovery-owner.%s' "$(_home_slug)"
}

_launchd_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' "${HOME:?}" "$(_launchd_label)"
}

_systemd_unit_path() {
  printf '%s/.config/systemd/user/fm-recovery-owner.service' "${HOME:?}"
}

cmd_install() {
  local platform
  platform=$(uname -s 2>/dev/null || printf unknown)
  case "$platform" in
    Darwin)
      local label plist
      label=$(_launchd_label)
      plist=$(_launchd_plist_path)
      mkdir -p "$(dirname "$plist")" 2>/dev/null || { echo "fm-recovery-owner: could not create $(dirname "$plist")" >&2; return 1; }
      cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_DIR/fm-recovery-owner.sh</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$FM_HOME</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
PLIST
      "${FM_LAUNCHCTL:-launchctl}" load -w "$plist" || { echo "fm-recovery-owner: launchctl load failed for $plist" >&2; return 1; }
      printf 'fm-recovery-owner: installed launchd agent %s (%s)\n' "$label" "$plist"
      ;;
    Linux)
      local unit
      unit=$(_systemd_unit_path)
      mkdir -p "$(dirname "$unit")" 2>/dev/null || { echo "fm-recovery-owner: could not create $(dirname "$unit")" >&2; return 1; }
      cat > "$unit" <<UNIT
[Unit]
Description=Firstmate recovery owner ($FM_HOME)

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/fm-recovery-owner.sh run
Environment=FM_HOME=$FM_HOME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
      "${FM_SYSTEMCTL:-systemctl}" --user daemon-reload || true
      "${FM_SYSTEMCTL:-systemctl}" --user enable --now fm-recovery-owner.service \
        || { echo "fm-recovery-owner: systemctl --user enable --now failed for $unit" >&2; return 1; }
      printf 'fm-recovery-owner: installed systemd user unit %s\n' "$unit"
      ;;
    *)
      echo "fm-recovery-owner: unsupported platform '$platform'; only Darwin (launchd) and Linux (systemd user) are implemented" >&2
      return 1
      ;;
  esac
}

cmd_uninstall() {
  local platform
  platform=$(uname -s 2>/dev/null || printf unknown)
  case "$platform" in
    Darwin)
      local label plist
      label=$(_launchd_label)
      plist=$(_launchd_plist_path)
      if [ -f "$plist" ]; then
        "${FM_LAUNCHCTL:-launchctl}" unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        printf 'fm-recovery-owner: uninstalled launchd agent %s\n' "$label"
      else
        printf 'fm-recovery-owner: no launchd agent installed at %s\n' "$plist"
      fi
      ;;
    Linux)
      local unit
      unit=$(_systemd_unit_path)
      if [ -f "$unit" ]; then
        "${FM_SYSTEMCTL:-systemctl}" --user disable --now fm-recovery-owner.service 2>/dev/null || true
        rm -f "$unit"
        "${FM_SYSTEMCTL:-systemctl}" --user daemon-reload 2>/dev/null || true
        printf 'fm-recovery-owner: uninstalled systemd user unit %s\n' "$unit"
      else
        printf 'fm-recovery-owner: no systemd user unit installed at %s\n' "$unit"
      fi
      ;;
    *)
      echo "fm-recovery-owner: unsupported platform '$platform'" >&2
      return 1
      ;;
  esac
}

case "${1:-}" in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  run) cmd_run ;;
  -h|--help|'') usage; [ -n "${1:-}" ] ;;
  *) echo "fm-recovery-owner.sh: unknown command: $1" >&2; usage >&2; exit 2 ;;
esac
