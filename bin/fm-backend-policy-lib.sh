# shellcheck shell=bash
# fm-backend-policy-lib.sh - the single owner of Firstmate's Herdr-only runtime
# invariant (AGENTS.md hard rule 6).
#
# Captain directive, 2026-08-29: Herdr is the sole supported runtime/session
# backend for the primary session, secondmates, crewmates, scouts, task
# endpoints, supervision, send/read/state/control/recovery, and lab operations.
# Nothing selects, detects, defaults to, or retries on tmux, zellij, orca, cmux,
# or any future backend. A missing, malformed, or non-Herdr backend identity
# refuses with one diagnostic that names Herdr and the exact remediation, and a
# Herdr runtime is proven by the adapter's own native checks
# (bin/backends/herdr.sh: fm_backend_herdr_tool_check, _version_check,
# _server_ensure, _launcher_identity, and the per-operation pane reads), never
# by a label or an ambient marker.
#
# This file owns:
#   FM_BACKEND_ACTIVE               the one selectable backend name
#   FM_BACKEND_RETAINED_LEGACY      adapters whose bin/backends/<name>.sh files
#                                   stay on disk but are unreachable for the
#                                   active runtime (removal plan:
#                                   docs/architecture.md "Runtime session backends")
#   fm_backend_policy_legacy_lane   whether this process is the repository's own
#                                   retained-adapter regression lane
#   fm_backend_policy_permits       whether <name> may be dispatched here
#   fm_backend_policy_is_retained   whether <name> is a retained legacy adapter
#   fm_backend_policy_refuse        the one refusal diagnostic
#   fm_backend_policy_config_remediation, fm_backend_policy_legacy_record_remediation,
#   fm_backend_policy_marker_note   remediation and marker text used by every boundary
#
# Legacy test lane. The retained adapters are admitted only from a repository
# test process with the harness marker and root identity.
# Ordinary Firstmate processes cannot enable this lane by setting backend
# variables; the lane is removed together with the retained adapters.
#
# Sourced by bin/fm-backend.sh and bin/fm-supervisor-target-lib.sh. It sets no
# FM_ROOT/FM_HOME globals and runs no commands at source time.

if [ -n "${_FM_BACKEND_POLICY_LIB_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_FM_BACKEND_POLICY_LIB_SOURCED=1

FM_BACKEND_ACTIVE="herdr"
FM_BACKEND_RETAINED_LEGACY="tmux zellij orca cmux"

fm_backend_policy_pid_identity() {
  local pid=$1 proc_root stat_line starttime cmdline_hex out identity_key
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  proc_root=/proc
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$(uname 2>/dev/null || true)" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_backend_policy_pid_is_current_or_ancestor() {
  local wanted=$1 pid=${BASHPID:-$$} parent hops=0
  case "$wanted" in ''|*[!0-9]*) return 1 ;; esac
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$hops" -lt 64 ]; do
    [ "$pid" = "$wanted" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null || true)
    parent=${parent//[[:space:]]/}
    [ -n "$parent" ] && [ "$parent" != "$pid" ] || break
    pid=$parent
    hops=$((hops + 1))
  done
  return 1
}

fm_backend_policy_fd_target() {
  local pid=$1 fd=$2 target
  case "$pid:$fd" in *[!0-9:]*|*:0) return 1 ;; esac
  if [ -r "/proc/$pid/fd/$fd" ]; then
    target=$(readlink "/proc/$pid/fd/$fd" 2>/dev/null) || return 1
  else
    target=$(lsof -Fn -a -p "$pid" -d "$fd" 2>/dev/null | sed -n 's/^n//p' | tail -1) || return 1
  fi
  [ -n "$target" ] || return 1
  printf '%s\n' "$target"
}

fm_backend_policy_test_capability() {
  local owner_pid=${FM_BACKEND_TEST_OWNER_PID:-} fd=${FM_BACKEND_TEST_CAPABILITY_FD:-}
  local owner_target current_target
  case "$fd" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$owner_pid" ] || return 1
  [ -f "/dev/fd/$fd" ] || return 1
  owner_target=$(fm_backend_policy_fd_target "$owner_pid" "$fd") || return 1
  current_target=$(fm_backend_policy_fd_target "${BASHPID:-$$}" "$fd") || return 1
  [ "$owner_target" = "$current_target" ] || return 1
}

fm_backend_policy_test_process() {
  local owner_pid=${FM_BACKEND_TEST_OWNER_PID:-} owner_identity=${FM_BACKEND_TEST_OWNER_IDENTITY:-}
  local owner_script=${FM_BACKEND_TEST_OWNER_SCRIPT:-} current_identity owner_command owner_cwd owner_comm source resolved root
  [ -n "$owner_pid" ] && [ -n "$owner_identity" ] || return 1
  fm_backend_policy_test_capability || return 1
  root=$(cd "${BASH_SOURCE[0]%/*}/.." 2>/dev/null && pwd -P) || return 1
  case "$owner_script" in
    "$root"/tests/*.test.sh) ;;
    *) return 1 ;;
  esac
  owner_command=$(ps -p "$owner_pid" -o command= 2>/dev/null) || return 1
  owner_comm=$(ps -p "$owner_pid" -o comm= 2>/dev/null) || return 1
  case "$owner_comm" in bash|zsh|sh) ;; *) return 1 ;; esac
  case "$owner_command" in *"$root/tests/"*.test.sh*|*"tests/"*.test.sh*) ;; *) return 1 ;; esac
  if [ -r "/proc/$owner_pid/cwd" ]; then
    owner_cwd=$(readlink "/proc/$owner_pid/cwd" 2>/dev/null) || return 1
  else
    owner_cwd=$(lsof -Fn -a -p "$owner_pid" -d cwd 2>/dev/null | sed -n 's/^n//p' | tail -1) || return 1
  fi
  case "$owner_cwd" in "$root"|"$root"/*) ;; *) return 1 ;; esac
  case "$owner_script" in "$root"/tests/*.test.sh) ;; *) return 1 ;; esac
  case "$owner_command" in *"$(basename "$owner_script")"*) ;; *) return 1 ;; esac
  if [ "$owner_pid" = "${BASHPID:-$$}" ]; then
    for source in "${BASH_SOURCE[@]}"; do
      case "$source" in
        /*) resolved=$source ;;
        *) resolved=$(cd "${source%/*}" 2>/dev/null && pwd -P)/${source##*/} || continue ;;
      esac
      case "$resolved" in "$root"/tests/*.test.sh) return 0 ;; esac
    done
    return 1
  fi
  fm_backend_policy_pid_is_current_or_ancestor "$owner_pid" || return 1
  current_identity=$(fm_backend_policy_pid_identity "$owner_pid") || return 1
  [ "$current_identity" = "$owner_identity" ]
}

fm_backend_policy_legacy_lane() {
  [ "${FM_BACKEND_LEGACY_TEST_LANE:-}" = 1 ] || return 1
  [ "${FM_BACKEND_TEST_HARNESS:-}" = 1 ] || return 1
  [ "${FM_BACKEND_TEST_ROOT:-}" = "$(cd "${BASH_SOURCE[0]%/*}/.." 2>/dev/null && pwd -P)" ] || return 1
  fm_backend_policy_test_process
}

fm_backend_policy_is_retained() {  # <name>
  case "${1-}" in
    *[[:space:]]*|'') return 1 ;;
  esac
  case " $FM_BACKEND_RETAINED_LEGACY " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# fm_backend_policy_permits: 0 when <name> may be selected or dispatched in this
# process. Herdr always; a retained legacy adapter only inside the test lane.
fm_backend_policy_permits() {  # <name>
  [ "${1-}" = "$FM_BACKEND_ACTIVE" ] && return 0
  fm_backend_policy_legacy_lane && fm_backend_policy_is_retained "${1-}" && return 0
  return 1
}

# fm_backend_policy_marker_note: the foreign or auto-detect runtime markers
# present in this environment, phrased as "present but never used for
# selection". Empty when none. Runtime markers are evidence for a diagnostic,
# never a selection input.
fm_backend_policy_marker_note() {
  local markers=""
  [ -n "${TMUX:-}" ] && markers="${markers:+$markers, }TMUX"
  [ -n "${TMUX_PANE:-}" ] && markers="${markers:+$markers, }TMUX_PANE"
  [ -n "${CMUX_WORKSPACE_ID:-}" ] && markers="${markers:+$markers, }CMUX_WORKSPACE_ID"
  [ "${HERDR_ENV:-}" = 1 ] && markers="${markers:+$markers, }HERDR_ENV=1"
  [ -n "$markers" ] || return 0
  printf ' Runtime markers present but never used for selection: %s.' "$markers"
}

# fm_backend_policy_config_remediation: how to declare Herdr for a home whose
# selection input (FM_BACKEND, config/backend) is absent or not herdr.
fm_backend_policy_config_remediation() {  # <config-dir>
  printf "Declare Herdr explicitly: write exactly 'herdr' as the first non-empty line of %s/backend (bin/fm-setup-phynd.sh writes it), or export FM_BACKEND=herdr for one launch, then prove the runtime with 'herdr status --json'.%s" \
    "${1:-config}" "$(fm_backend_policy_marker_note)"
}

# fm_backend_policy_legacy_record_remediation: what a pre-invariant task record
# means and where its retirement path is documented.
fm_backend_policy_legacy_record_remediation() {
  printf 'This pre-invariant task record is read-only here: Firstmate will not operate, relaunch, steer, or clean up its endpoint. Retire it through the captain-authorized path in docs/configuration.md "Legacy task records".'
}

# fm_backend_policy_refuse: print the one refusal line to stderr and return 1.
# <origin> names the selection input or record being judged, <value> is the
# backend it resolves to (empty for an absent identity), <remediation> is the
# exact next action. Never prints to stdout, so a caller capturing a backend
# name can never receive a usable non-Herdr value.
fm_backend_policy_refuse() {  # <origin> <value> <remediation>
  local origin=$1 value=$2 remediation=$3 verdict safe_origin safe_value safe_remediation
  safe_origin=$(printf '%s' "$origin" | LC_ALL=C tr '\001-\037\177' ' ')
  safe_value=$(printf '%s' "$value" | LC_ALL=C tr '\001-\037\177' ' ')
  safe_remediation=$(printf '%s' "$remediation" | LC_ALL=C tr '\001-\037\177' ' ')
  if [ -n "$safe_value" ]; then
    verdict="resolves '$safe_value'"
  else
    verdict="declares no backend identity"
  fi
  printf 'REFUSED: %s %s, but Herdr is the sole supported Firstmate runtime backend and no tmux, zellij, orca, cmux, auto-detected, or default fallback exists. %s\n' \
    "$safe_origin" "$verdict" "$safe_remediation" >&2
  return 1
}
