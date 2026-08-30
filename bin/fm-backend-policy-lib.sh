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
# Legacy test lane. The explicit lane marker is admitted only when descriptor 9
# is inherited from a repository test process in the same checkout.
# Ordinary Firstmate processes cannot enable this lane without that provenance.
#
# Sourced by bin/fm-backend.sh and bin/fm-supervisor-target-lib.sh. It sets no
# FM_ROOT/FM_HOME globals and runs no commands at source time.

if [ -n "${_FM_BACKEND_POLICY_LIB_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_FM_BACKEND_POLICY_LIB_SOURCED=1

FM_BACKEND_ACTIVE="herdr"
FM_BACKEND_RETAINED_LEGACY="tmux zellij orca cmux"

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

fm_backend_policy_test_process() {
  local fd=9 current_pid=${BASHPID:-$$}
  local current_target command comm cwd target parent hops=0 root
  case "$fd" in ''|*[!0-9]*) return 1 ;; esac
  current_target=$(fm_backend_policy_fd_target "$current_pid" "$fd") || return 1
  root=$(cd "${BASH_SOURCE[0]%/*}/.." 2>/dev/null && pwd -P) || return 1
  while [ -n "$current_pid" ] && [ "$current_pid" -gt 1 ] && [ "$hops" -lt 64 ]; do
    target=$(fm_backend_policy_fd_target "$current_pid" "$fd" 2>/dev/null || true)
    if [ "$target" = "$current_target" ]; then
      command=$(ps -p "$current_pid" -o command= 2>/dev/null || true)
      comm=$(ps -p "$current_pid" -o comm= 2>/dev/null || true)
      case "$comm" in
        bash|zsh|sh)
          case "$command" in *"$root/tests/"*.test.sh*|*"tests/"*.test.sh*) ;; *) command= ;; esac
          if [ -n "$command" ]; then
            if [ -r "/proc/$current_pid/cwd" ]; then
              cwd=$(readlink "/proc/$current_pid/cwd" 2>/dev/null || true)
            else
              cwd=$(lsof -Fn -a -p "$current_pid" -d cwd 2>/dev/null | sed -n 's/^n//p' | tail -1 || true)
            fi
            case "$cwd" in "$root"|"$root"/*) return 0 ;; esac
          fi
          ;;
      esac
    fi
    parent=$(ps -o ppid= -p "$current_pid" 2>/dev/null || true)
    parent=${parent//[[:space:]]/}
    [ -n "$parent" ] && [ "$parent" != "$current_pid" ] || break
    current_pid=$parent
    hops=$((hops + 1))
  done
  return 1
}

fm_backend_policy_legacy_lane() {
  [ "${FM_BACKEND_LEGACY_TEST_LANE:-}" = 1 ] || return 1
  fm_backend_policy_test_process
}

fm_backend_policy_test_stub() {
  local name=$1 path stub_dir temp_dir first_line
  path=$(command -v "$name" 2>/dev/null) || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -f "$path" ] && [ -x "$path" ] || return 1
  stub_dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  temp_dir=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || return 1
  case "$stub_dir/" in
    "$temp_dir"/*) ;;
    *) return 1 ;;
  esac
  IFS= read -r first_line < "$path" || return 1
  case "$first_line" in
    '#!'*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_policy_legacy_adapter_allowed() {
  local name=${1-}
  fm_backend_policy_legacy_lane || return 1
  fm_backend_policy_is_retained "$name" || return 1
  fm_backend_policy_test_stub "$name"
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
  fm_backend_policy_legacy_adapter_allowed "${1-}" && return 0
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
