#!/usr/bin/env bash
# fm-backend.sh - runtime-backend selection, meta helpers, selector resolution,
# and dispatch for firstmate's session-provider abstraction.
#
# Design: data/fm-backend-design-d7/report.md ("Backend Interface") and
# data/fm-backend-design-d7/herdr-addendum.md ("Events as the core
# abstraction"). P1 extracted the tmux command sequences that fm-send.sh,
# fm-peek.sh, fm-watch.sh, fm-spawn.sh, and fm-teardown.sh already ran inline
# into bin/backends/tmux.sh, with those SAME command sequences, so the default
# (tmux) path stays byte-identical. P2 adds bin/backends/herdr.sh, an
# EXPERIMENTAL spawn-capable backend behind `--backend herdr`/`FM_BACKEND=herdr`/
# `config/backend`, and behind runtime auto-detection when firstmate itself is
# running inside herdr with no explicit backend setting; see herdr-addendum.md and
# data/fm-backend-design-d7/herdr-verification-p2.md for its empirical basis.
# P3 adds bin/backends/zellij.sh, also EXPERIMENTAL and spawn-capable, behind
# `--backend zellij`/`FM_BACKEND=zellij`/`config/backend` - NOT behind runtime
# auto-detection (report.md's Open Question #2: start with a dedicated
# background session for predictability, unlike tmux's/herdr's ambient-session
# reuse); see report.md's "Zellij Backend" section and docs/zellij-backend.md
# for its empirical basis. P4 makes Orca spawn-capable: Orca owns both the
# task worktree and the terminal endpoint. P5 adds bin/backends/cmux.sh, also
# EXPERIMENTAL and spawn-capable, behind `--backend cmux`/`FM_BACKEND=cmux`/
# `config/backend`, and behind runtime auto-detection when firstmate itself is
# running inside a cmux-spawned terminal (primary CMUX_WORKSPACE_ID marker, or
# the documented macOS fallback signals when cmux's claude wrapper strips that
# marker) with no explicit backend setting - unlike Orca, which stays
# never-auto-detected because it also owns the task worktree; see
# docs/cmux-backend.md for its empirical basis.
# Codex App is intentionally not in the known set yet.
# docs/codex-app-backend.md owns that blocked backend contract.
#
# HERDR-ONLY RUNTIME INVARIANT (AGENTS.md hard rule 6; owner:
# bin/fm-backend-policy-lib.sh). The paragraphs above are the adapter history.
# In the active runtime only `herdr` is known, spawn-capable, selectable, or
# dispatchable: FM_BACKEND, config/backend, --backend, inherited secondmate
# config, task metadata, selectors, and supervisor discovery all refuse any
# other value and any absent identity through fm_backend_policy_refuse, and
# fm_backend_detect never selects anything. The tmux, zellij, orca, and cmux
# adapter files stay on disk as retained legacy code and are unreachable by
# every Firstmate runtime path.
#
# Pre-invariant compatibility contract (legacy lane only): a task's meta may
# omit `backend=`; readers treat that as `tmux` (fm_backend_of_meta), and
# fm-spawn.sh does not write `backend=tmux` for a default-backend task. In the
# active runtime an absent `backend=` is a legacy record and is refused
# read-only (docs/configuration.md "Legacy task records").
#
# Event-source framing (herdr-addendum "Events as the core abstraction"): a
# backend's supervision surface is conceptually an EVENT SOURCE - it produces
# task events (status-changed, went-stale, exited) that map onto firstmate's
# existing signal/stale/check/heartbeat wake vocabulary. The tmux adapter has
# no native event push, so fm-watch.sh's poll loop over the pull primitives
# below (capture, list-live, busy-state via regex) IS the default event-source
# implementation that synthesizes those events; P1 only names that seam, it
# does not change the loop's behavior. The pull primitives also stay available
# on their own for on-demand reads (fm-peek.sh, fm-crew-state.sh).

FM_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_BACKEND_LIB_DIR="$(cd "$(dirname "$FM_BACKEND_SCRIPT")" && pwd)"
unset FM_BACKEND_SCRIPT
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# The Herdr-only invariant and its retained-adapter history.
# shellcheck source=bin/fm-backend-policy-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-backend-policy-lib.sh"

# Known and spawn-capable backends are exactly the one supported backend,
# herdr (FM_BACKEND_ACTIVE). Retained adapters remain historical files and
# codex-app remains deliberately absent; see docs/codex-app-backend.md.
FM_BACKEND_KNOWN="$FM_BACKEND_ACTIVE"
FM_BACKEND_SPAWN="$FM_BACKEND_ACTIVE"

# fm_backend_list_contains: whitespace-delimited membership without relying on
# shell word splitting. fm-backend.sh is normally sourced by bash scripts, but
# zsh diagnostics can source it too, so backend-name matching must stay portable.
fm_backend_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

fm_backend_is_known() {  # <name>
  fm_backend_list_contains "$FM_BACKEND_KNOWN" "$1"
}

# fm_backend_detect: runtime markers never select a backend and this function
# always returns 1.
# Nesting resolves INNERMOST-first: tmux sets $TMUX in every process running
# inside it, even a tmux started inside a herdr pane, so $TMUX is checked first
# and wins over HERDR_ENV=1 in that nested case. herdr injects HERDR_ENV=1 (plus
# HERDR_SOCKET_PATH/HERDR_PANE_ID) into every process it manages a pane for;
# HERDR_ENV=1 alone (no $TMUX) selects herdr. cmux injects CMUX_WORKSPACE_ID
# (plus CMUX_SURFACE_ID/CMUX_SOCKET_PATH and the legacy CMUX_TAB_ID/
# CMUX_PANEL_ID aliases) into every terminal surface it spawns - verified from
# the shipped source (`TerminalSurface+StartupEnvironment.swift`'s
# `applyManagedCmuxContextEnvironment`, which marks all five keys
# `protectedKeys`, i.e. non-overridable) and corroborated by cmux's own CLI
# (`cmux_open.swift`) reading `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` as its own
# ambient-target fallback, exactly how `$TMUX` and `HERDR_ENV` work for their
# backends. CMUX_WORKSPACE_ID, not CMUX_SOCKET_PATH, is the chosen marker:
# CMUX_SOCKET_PATH is independently documented as a user-settable override for
# pointing the CLI at a non-default socket, so its mere presence would not
# reliably mean "running inside a cmux-spawned terminal" the way
# CMUX_WORKSPACE_ID does. cmux is checked LAST because it is a terminal
# application (the outermost layer, like iTerm2/Terminal.app), not a session
# multiplexer - both tmux and herdr can run nested inside a cmux-provided
# shell, but cmux cannot run nested inside either of them, so a tmux or herdr
# marker set alongside CMUX_WORKSPACE_ID always means that multiplexer is the
# innermost, currently-executing layer and must win.
#
# cmux FALLBACK signals (docs/cmux-backend.md "Runtime auto-detection" owns
# the empirical record): cmux's bundled `claude` PATH shim routes through
# cmux-claude-wrapper, whose passthrough path unsets every CMUX_* variable
# before exec'ing the real binary - so a claude-harness firstmate launched in
# a cmux tab can have NO CMUX_WORKSPACE_ID at all. When that primary marker is
# absent (and only then), two macOS-only fallback signals are consulted:
#   1. __CFBundleIdentifier == com.cmuxterm.app - LaunchServices' app-identity
#      env var, inherited by every process a cmux tab spawns and NOT stripped
#      by the wrapper (it only unsets CMUX_*, TERMINFO, and CLAUDECODE).
#      Authoritative in the common wrapper-strip case, but also inherited into
#      every pane of a tmux server started from a cmux tab - the $TMUX check
#      winning FIRST is what keeps that false positive absorbed.
#   2. Process ancestry reaching the running cmux app (resolved by bundle id
#      via lsappinfo, plus a bundle-shaped `ps` comm match so the install
#      location is never hardcoded). Authoritative when the environment was
#      scrubbed entirely (no bundle id to inherit); NOT usable from inside
#      tmux, where the tmux server reparents to launchd and the chain never
#      reaches cmux - which is fine, because $TMUX already won there.
# Callers needing the winning signal read FM_BACKEND_DETECT_SIGNAL (set to
# TMUX, HERDR_ENV, CMUX_WORKSPACE_ID, bundle-id, or ancestry) and
# FM_BACKEND_DETECTED after a direct (non-command-substitution) call.
FM_BACKEND_CMUX_BUNDLE_ID="com.cmuxterm.app"

fm_backend_detect() {
  FM_BACKEND_DETECTED=""
  FM_BACKEND_DETECT_SIGNAL=""
  return 1
  if [ -n "${TMUX:-}" ]; then
    FM_BACKEND_DETECTED=tmux
    FM_BACKEND_DETECT_SIGNAL=TMUX
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ]; then
    FM_BACKEND_DETECTED=herdr
    FM_BACKEND_DETECT_SIGNAL=HERDR_ENV
    printf 'herdr'
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    FM_BACKEND_DETECTED=cmux
    FM_BACKEND_DETECT_SIGNAL=CMUX_WORKSPACE_ID
    printf 'cmux'
    return 0
  fi
  if fm_backend_detect_cmux_fallback; then
    FM_BACKEND_DETECTED=cmux
    printf 'cmux'
    return 0
  fi
  return 1
}

# fm_backend_detect_cmux_fallback: the two macOS-only cmux fallback signals
# (see fm_backend_detect's header comment). Sets FM_BACKEND_DETECT_SIGNAL to
# bundle-id or ancestry on success. Cheap-first: the bundle-id check is a pure
# env read; the ancestry walk (subprocess-per-hop) runs only when it misses.
fm_backend_detect_cmux_fallback() {
  [ "$(uname 2>/dev/null)" = Darwin ] || return 1
  if [ "${__CFBundleIdentifier:-}" = "$FM_BACKEND_CMUX_BUNDLE_ID" ]; then
    FM_BACKEND_DETECT_SIGNAL=bundle-id
    return 0
  fi
  if fm_backend_detect_cmux_app_is_ancestor; then
    FM_BACKEND_DETECT_SIGNAL=ancestry
    return 0
  fi
  return 1
}

# fm_backend_detect_cmux_app_pid: the running cmux app's pid, resolved by
# bundle id via lsappinfo (`"pid"=<n>`), or failure when lsappinfo is missing,
# errors, or the app is not running (lsappinfo prints nothing, exit 0).
fm_backend_detect_cmux_app_pid() {
  command -v lsappinfo >/dev/null 2>&1 || return 1
  local out pid
  out=$(lsappinfo info -only pid -app "$FM_BACKEND_CMUX_BUNDLE_ID" 2>/dev/null) || return 1
  pid=${out##*=}
  pid=$(printf '%s' "$pid" | tr -d '[:space:]"')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$pid"
}

# fm_backend_detect_cmux_app_is_ancestor: walk this process's parent chain and
# report whether it reaches the cmux app - matching either the lsappinfo-
# resolved pid (bundle id, no path assumption) or a bundle-shaped comm path
# (`*/cmux.app/Contents/MacOS/cmux`, any install location) when lsappinfo
# could not resolve one. Stops at launchd (ppid 1), where a tmux server that
# was started from a cmux tab has already reparented - ancestry can never
# false-positive from inside tmux.
fm_backend_detect_cmux_app_is_ancestor() {
  local cmux_pid pid ppid comm hops=0
  cmux_pid=$(fm_backend_detect_cmux_app_pid) || cmux_pid=""
  pid=$$
  while [ "$hops" -lt 32 ]; do
    if [ -n "$cmux_pid" ] && [ "$pid" = "$cmux_pid" ]; then
      return 0
    fi
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=""
    comm="${comm#"${comm%%[![:space:]]*}"}"
    comm="${comm%"${comm##*[![:space:]]}"}"
    [ -n "$comm" ] || return 1
    case "$comm" in
      */cmux.app/Contents/MacOS/cmux) return 0 ;;
    esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$ppid" -gt 1 ] || return 1
    pid=$ppid
    hops=$((hops + 1))
  done
  return 1
}

# fm_backend_name: resolve the ACTIVE backend for a NEW spawn, absent an
# explicit per-task override. Precedence: FM_BACKEND env, then config/backend
# (a single word on its first non-empty line, mirroring config/crew-harness).
# A per-task `--backend` flag is parsed by the caller (fm-spawn.sh) and takes
# precedence over this resolution entirely; it is not read here.
#
# Active runtime (hard rule 6): whichever input is consulted first must name
# herdr, and a home that declares nothing is refused - there is no default and
# runtime markers ($TMUX, HERDR_ENV=1, cmux signals) never select. A refusal
# prints exactly one fm_backend_policy_refuse line naming the input, Herdr, and
# the remediation, prints NOTHING to stdout, and returns 1, so a caller that
# captures the name can never receive a usable non-Herdr value.
#
fm_backend_name() {
  local line v detected marker config_line=""
  if [ -f "$FM_BACKEND_CONFIG_DIR/backend" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      v=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$v" ]; then
        config_line=$v
        break
      fi
    done < "$FM_BACKEND_CONFIG_DIR/backend"
  fi
  if ! fm_backend_policy_legacy_lane; then
    if [ -n "${FM_BACKEND:-}" ]; then
      [ "$FM_BACKEND" = "$FM_BACKEND_ACTIVE" ] && { printf '%s' "$FM_BACKEND_ACTIVE"; return 0; }
      fm_backend_policy_refuse "FM_BACKEND" "$FM_BACKEND" \
        "$(fm_backend_policy_config_remediation "$FM_BACKEND_CONFIG_DIR")"
      return 1
    fi
    if [ -n "$config_line" ]; then
      [ "$config_line" = "$FM_BACKEND_ACTIVE" ] && { printf '%s' "$FM_BACKEND_ACTIVE"; return 0; }
      fm_backend_policy_refuse "$FM_BACKEND_CONFIG_DIR/backend" "$config_line" \
        "$(fm_backend_policy_config_remediation "$FM_BACKEND_CONFIG_DIR")"
      return 1
    fi
    if [ -f "$FM_BACKEND_CONFIG_DIR/backend" ]; then
      fm_backend_policy_refuse "$FM_BACKEND_CONFIG_DIR/backend (present but empty)" "" \
        "$(fm_backend_policy_config_remediation "$FM_BACKEND_CONFIG_DIR")"
      return 1
    fi
    fm_backend_policy_refuse "neither FM_BACKEND nor $FM_BACKEND_CONFIG_DIR/backend" "" \
      "$(fm_backend_policy_config_remediation "$FM_BACKEND_CONFIG_DIR")"
    return 1
  fi
  if [ -n "${FM_BACKEND:-}" ]; then
    printf '%s' "$FM_BACKEND"
    return 0
  fi
  if [ -n "$config_line" ]; then
    printf '%s' "$config_line"
    return 0
  fi
  # Called directly (not in a command substitution) so the detect signal
  # globals survive into the notice below.
  if fm_backend_detect >/dev/null; then
    detected=$FM_BACKEND_DETECTED
    if [ "$detected" = herdr ]; then
      echo "NOTICE: auto-detected herdr runtime (HERDR_ENV=1) - spawning into the EXPERIMENTAL herdr backend. Set config/backend or pass --backend tmux to opt out." >&2
    fi
    if [ "$detected" = cmux ]; then
      case "$FM_BACKEND_DETECT_SIGNAL" in
        bundle-id) marker="FALLBACK signal __CFBundleIdentifier=$FM_BACKEND_CMUX_BUNDLE_ID; CMUX_WORKSPACE_ID absent, stripped by cmux's bundled claude wrapper" ;;
        ancestry) marker="FALLBACK signal process-ancestry reaching the running cmux app; CMUX_WORKSPACE_ID absent, stripped by cmux's bundled claude wrapper" ;;
        *) marker="CMUX_WORKSPACE_ID" ;;
      esac
      echo "NOTICE: auto-detected cmux runtime ($marker) - spawning into the EXPERIMENTAL cmux backend. Set config/backend or pass --backend tmux to opt out." >&2
    fi
    printf '%s' "$detected"
    return 0
  fi
  printf 'tmux'
}

# fm_backend_validate: refuse anything but a dispatchable backend LOUDLY.
# Silent on success. <origin> names the input being judged in the refusal
# (default: "the selected runtime backend"). Every dispatcher below routes
# through fm_backend_source, which calls this, so a retained legacy adapter is
# unreachable for the active runtime no matter which operation names it.
fm_backend_validate() {  # <name> [origin]
  local name=$1 origin=${2:-the selected runtime backend}
  if fm_backend_policy_permits "$name"; then
    return 0
  fi
  if fm_backend_policy_is_retained "$name"; then
    fm_backend_policy_refuse "$origin" "$name" \
      "Select Herdr instead; the $name adapter is retained on disk only as historical code and is unreachable for Firstmate."
    return 1
  fi
  if fm_backend_policy_legacy_lane; then
    echo "error: unknown backend '$name' (known: $FM_BACKEND_KNOWN)" >&2
  else
    fm_backend_policy_refuse "$origin" "$name" \
      "Declare Herdr explicitly in config/backend or with FM_BACKEND=herdr, then prove the runtime with 'herdr status --json'."
    return 1
  fi
  return 1
}

fm_backend_validate_spawn() {  # <name> [origin]
  local name=$1
  fm_backend_validate "$name" "${2-}" || return 1
  fm_backend_list_contains "$FM_BACKEND_SPAWN" "$name" && return 0
  echo "error: backend '$name' does not support task spawning yet (spawn-supported: $FM_BACKEND_SPAWN)" >&2
  return 1
}

# fm_backend_required_tools: the backend-SPECIFIC CLI tools a firstmate home on
# <backend> genuinely requires, beyond firstmate's universal toolchain (owned by
# docs/configuration.md "Toolchain" and bootstrap's COMMON list). This is the
# single owner of the per-backend dependency delta, so bootstrap follows the
# RESOLVED backend instead of demanding an inactive backend's tools. Each set is:
#   - the session-provider CLI itself (tmux/herdr/zellij/orca/cmux);
#   - jq, for the JSON-emitting experimental adapters (herdr, zellij, cmux) whose
#     spawn/liveness paths parse the backend's JSON output (see each adapter's
#     tool check, e.g. fm_backend_herdr_tool_check);
#   - the treehouse worktree provider for every session-provider-only backend
#     (tmux, herdr, zellij, cmux); orca owns its own task worktree and terminal,
#     so it drops both treehouse and any other backend's session CLI.
# Prints a single space-separated line and returns 0 for a known backend; returns
# 1 and prints nothing for an unknown backend.
fm_backend_required_tools() {  # <backend>
  case "$1" in
    tmux)   printf '%s' 'tmux treehouse' ;;
    herdr)  printf '%s' 'herdr jq treehouse' ;;
    zellij) printf '%s' 'zellij jq treehouse' ;;
    cmux)   printf '%s' 'cmux jq treehouse' ;;
    orca)   printf '%s' 'orca' ;;
    *) return 1 ;;
  esac
}

fm_backend_required_tool_available() {  # <backend> <tool>
  local backend=$1 tool=$2 required
  required=$(fm_backend_required_tools "$backend") || return 1
  fm_backend_list_contains "$required" "$tool" || return 1
  case "$backend:$tool" in
    cmux:cmux)
      fm_backend_source cmux >/dev/null 2>&1 || return 1
      fm_backend_cmux_bin >/dev/null 2>&1
      ;;
    *) command -v "$tool" >/dev/null 2>&1 ;;
  esac
}

# fm_meta_get: the LAST value of `key=` in <meta-file>, or empty (never
# errors) if the file or key is absent. Mirrors the ad hoc `grep '^key=' |
# tail -1 | cut -d= -f2-` snippet every fm-*.sh script used to repeat inline.
fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_backend_of_meta: the backend identity recorded in <meta-file>.
# Active runtime: prints `herdr` for a Herdr record. Any other record is
# refused - an absent `backend=` line is a pre-invariant legacy record, a
# non-Herdr value is a retained-adapter record - with one
# fm_backend_policy_refuse line naming the record, and return 1. Refusals never
# print an accepted backend to stdout. Callers that render fleet state
# (fm-session-start.sh, fm-crew-state.sh, fm-fleet-snapshot.sh) check the
# status and present the record as legacy instead of dispatching on it.
fm_backend_of_meta() {  # <meta-file>
  local v backend_count
  backend_count=$(grep -c '^backend=' "$1" 2>/dev/null || true)
  if ! fm_backend_policy_legacy_lane && [ "$backend_count" -gt 1 ]; then
    fm_backend_policy_refuse "task record $1 (ambiguous duplicate backend identity)" "" \
      "Retire or explicitly migrate this pre-invariant task record through docs/configuration.md \"Legacy task records\"."
    return 1
  fi
  v=$(fm_meta_get "$1" backend)
  if fm_backend_policy_legacy_lane; then
    printf '%s' "${v:-tmux}"
    return 0
  fi
  if [ "$v" = "$FM_BACKEND_ACTIVE" ]; then
    printf '%s' "$v"
    return 0
  fi
  if [ -z "$v" ]; then
    fm_backend_policy_refuse "task record $1 (no backend= line)" "" \
      "$(fm_backend_policy_legacy_record_remediation)"
  else
    fm_backend_policy_refuse "task record $1 (backend=$v)" "$v" \
      "$(fm_backend_policy_legacy_record_remediation)"
  fi
  return 1
}

fm_backend_target_of_meta() {  # <meta-file>
  local meta=$1 backend terminal window
  # A pure record read: the recorded name only chooses which field holds the
  # target. Identity judgement belongs to fm_backend_of_meta, so a legacy record
  # is diagnosed exactly once, by the caller that asks for its backend.
  backend=$(fm_meta_get "$meta" backend)
  if [ "$backend" = orca ]; then
    terminal=$(fm_meta_get "$meta" terminal)
    [ -n "$terminal" ] && { printf '%s' "$terminal"; return 0; }
  fi
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

fm_backend_meta_recorded_backend() {  # <meta-file> [<key>]; passive display accessor
  local meta=$1 key=${2:-backend} count
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  case "$count" in
    0) printf 'absent' ;;
    1) fm_meta_get "$meta" "$key" ;;
    *) printf 'ambiguous' ;;
  esac
}

# fm_backend_validate_task_endpoint: validate a task cleanup record entirely
# from its durable metadata before any runtime command or cleanup mutation.
# The validation binds the exact task id, selected backend, target, project,
# and worktree. New non-tmux records carry endpoint_task_id because their
# opaque runtime ids do not encode the task label. Legacy tmux records remain
# valid only when their window name itself is exactly fm-<task-id>.
# On success, sets FM_BACKEND_VALIDATED_BACKEND and
# FM_BACKEND_VALIDATED_TARGET. On failure, prints one refusal and returns 1.
fm_backend_meta_exact_value() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^$key=" "$meta" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_backend_validate_remote_meta() {  # <meta-file> <task-id>
  local meta=$1 id=$2 backend
  backend=$(fm_backend_meta_exact_value "$meta" remote_backend 2>/dev/null || true)
  [ "$backend" = "$FM_BACKEND_ACTIVE" ] && return 0
  if [ -n "$backend" ]; then
    fm_backend_policy_refuse "task $id remote endpoint record $meta (remote_backend=$backend)" "$backend" \
      "Retire or explicitly migrate this remote task record through docs/configuration.md \"Legacy task records\"."
  else
    fm_backend_policy_refuse "task $id remote endpoint record $meta (missing or ambiguous remote_backend)" "" \
      "Retire or explicitly migrate this remote task record through docs/configuration.md \"Legacy task records\"."
  fi
  return 1
}

fm_backend_validate_remote_task_endpoint() {  # <meta-file> <task-id> [expected-session]
  local meta=$1 id=$2 expected_session=${3:-}
  local backend binding recorded_session target target_session pane
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  backend=$(fm_backend_meta_exact_value "$meta" remote_backend 2>/dev/null || true)
  [ "$backend" = "$FM_BACKEND_ACTIVE" ] || return 1
  binding=$(fm_backend_meta_exact_value "$meta" endpoint_task_id 2>/dev/null || true)
  [ "$binding" = "$id" ] || return 1
  recorded_session=$(fm_backend_meta_exact_value "$meta" remote_herdr_session 2>/dev/null || true)
  [ -n "$recorded_session" ] || return 1
  [ -z "$expected_session" ] || [ "$recorded_session" = "$expected_session" ] || return 1
  fm_backend_endpoint_atom_valid "$recorded_session" || return 1
  target=$(fm_backend_meta_exact_value "$meta" remote_target 2>/dev/null || true)
  [ -n "$target" ] || return 1
  target_session=${target%%:*}
  pane=${target#*:}
  [ "$target_session" = "$recorded_session" ] || return 1
  [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
  fm_backend_endpoint_atom_valid "${pane//:/_}" || return 1
  FM_BACKEND_VALIDATED_BACKEND=$backend
  FM_BACKEND_VALIDATED_TARGET=$target
}

fm_backend_herdr_capability_check() {  # <origin>
  local origin=$1 detail
  if detail=$(fm_backend_herdr_version_check 2>&1); then
    return 0
  fi
  detail=$(printf '%s\n' "$detail" | sed -n '1p')
  fm_backend_policy_refuse "$origin" herdr \
    "The native Herdr capability check failed${detail:+: $detail} Upgrade or repair Herdr, then verify with 'herdr status --json'."
  return 2
}

fm_backend_herdr_capability_preflight() {  # <origin> [session]
  local origin=$1 session=${2:-}
  fm_backend_source herdr "$origin" "$session"
}

fm_backend_endpoint_atom_valid() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._@%+-]*) return 1 ;;
  esac
}

fm_backend_validate_task_endpoint() {  # <meta-file> <task-id>
  local meta=$1 id=$2 backend_count backend window worktree project binding_count binding
  local session pane recorded_session workspace tab terminal worktree_id surface
  FM_BACKEND_VALIDATED_BACKEND=
  FM_BACKEND_VALIDATED_TARGET=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    fm_backend_policy_refuse "task $id endpoint record" "" \
      "Repair or explicitly migrate this task record through docs/configuration.md \"Legacy task records\". Task state is preserved."
    return 1
  }
  case "$id" in ''|*[!A-Za-z0-9._-]*)
    fm_backend_policy_refuse "task endpoint identity" "" \
      "Use a valid task id and explicitly migrate any legacy record through docs/configuration.md \"Legacy task records\"."
    return 1
  esac
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  case "$backend_count" in
    0)
      if fm_backend_policy_legacy_lane; then
        backend=tmux
      else
        fm_backend_policy_refuse "task $id endpoint record $meta (no backend= line)" "" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      fi
      ;;
    1) backend=$(fm_backend_meta_exact_value "$meta" backend) || backend= ;;
    *) backend= ;;
  esac
  if [ -z "$backend" ]; then
    fm_backend_policy_refuse "task $id endpoint record $meta (missing or ambiguous backend identity)" "" \
      "Retire or explicitly migrate this pre-invariant task record through docs/configuration.md \"Legacy task records\". Task state is preserved."
    return 1
  fi
  if ! fm_backend_policy_permits "$backend"; then
    fm_backend_policy_refuse "task $id endpoint record $meta (backend=$backend)" "$backend" \
      "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
    return 1
  fi
  if ! fm_backend_is_known "$backend"; then
    fm_backend_policy_refuse "task $id endpoint record $meta (unknown backend=$backend)" "$backend" \
      "Retire or explicitly migrate this task record through docs/configuration.md \"Legacy task records\". Task state is preserved."
    return 1
  fi
  window=$(fm_backend_meta_exact_value "$meta" window) || {
    fm_backend_policy_refuse "task $id endpoint record (window)" "$backend" \
      "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
    return 1
  }
  worktree=$(fm_backend_meta_exact_value "$meta" worktree) || {
    fm_backend_policy_refuse "task $id endpoint record (worktree)" "$backend" \
      "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
    return 1
  }
  project=$(fm_backend_meta_exact_value "$meta" project) || {
    fm_backend_policy_refuse "task $id endpoint record (project)" "$backend" \
      "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
    return 1
  }
  case "$worktree$project$window" in *$'\n'*|*$'\r'*|*$'\t'*)
    fm_backend_policy_refuse "task $id endpoint record (malformed metadata)" "$backend" \
      "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
    return 1
  esac
  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  case "$binding_count" in
    0) binding= ;;
    1)
      binding=$(fm_backend_meta_exact_value "$meta" endpoint_task_id) || {
        fm_backend_policy_refuse "task $id endpoint record (empty task binding)" "$backend" \
      "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
        return 1
      }
      ;;
    *)
      fm_backend_policy_refuse "task $id endpoint record (ambiguous task binding)" "$backend" \
      "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
      return 1
      ;;
  esac
  if [ -n "$binding" ] && [ "$binding" != "$id" ]; then
    fm_backend_policy_refuse "task $id endpoint record (task binding mismatch)" "$backend" \
      "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
    return 1
  fi

  case "$backend" in
    tmux)
      session=${window%%:*}
      pane=${window#*:}
      if [ "$pane" = "$window" ] || [ "$pane" != "fm-$id" ] \
        || [ -z "$session" ]; then
        fm_backend_policy_refuse "task $id endpoint record (legacy tmux endpoint)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      fi
      ;;
    herdr)
      [ "$binding" = "$id" ] || {
        fm_backend_policy_refuse "task $id endpoint record (Herdr binding)" "$backend" \
          "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
        return 1
      }
      recorded_session=$(fm_backend_meta_exact_value "$meta" herdr_session) || recorded_session=
      workspace=$(fm_backend_meta_exact_value "$meta" herdr_workspace_id) || workspace=
      tab=$(fm_backend_meta_exact_value "$meta" herdr_tab_id) || tab=
      pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) || pane=
      if [ -z "$recorded_session" ] || [ -z "$workspace" ] || [ -z "$tab" ] || [ -z "$pane" ] \
        || [ "$window" != "$recorded_session:$pane" ] \
        || ! fm_backend_endpoint_atom_valid "$recorded_session" \
        || ! fm_backend_endpoint_atom_valid "$workspace" \
        || ! fm_backend_endpoint_atom_valid "${tab//:/_}" \
        || ! fm_backend_endpoint_atom_valid "${pane//:/_}"; then
        fm_backend_policy_refuse "task $id endpoint record (Herdr endpoint)" "$backend" \
          "Repair the endpoint metadata or explicitly migrate the record through docs/configuration.md \"Legacy task records\". Task state is preserved."
        return 1
      fi
      ;;
    zellij)
      [ "$binding" = "$id" ] || {
        fm_backend_policy_refuse "task $id endpoint record (legacy Zellij endpoint)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      }
      recorded_session=$(fm_backend_meta_exact_value "$meta" zellij_session) || recorded_session=
      tab=$(fm_backend_meta_exact_value "$meta" zellij_tab_id) || tab=
      pane=$(fm_backend_meta_exact_value "$meta" zellij_pane_id) || pane=
      case "$tab:$pane" in *[!0-9:]*) tab= ;; esac
      if [ -z "$recorded_session" ] || [ -z "$tab" ] || [ -z "$pane" ] \
        || [ "$window" != "$recorded_session:$pane" ] \
        || ! fm_backend_endpoint_atom_valid "$recorded_session"; then
        fm_backend_policy_refuse "task $id endpoint record (legacy Zellij endpoint)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      fi
      ;;
    orca)
      [ "$binding" = "$id" ] || {
        fm_backend_policy_refuse "task $id endpoint record (legacy Orca endpoint)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      }
      terminal=$(fm_backend_meta_exact_value "$meta" terminal) || terminal=
      worktree_id=$(fm_backend_meta_exact_value "$meta" orca_worktree_id) || worktree_id=
      [ -n "$terminal" ] || {
        fm_backend_policy_refuse "task $id endpoint record (legacy Orca terminal)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      }
      [ -n "$worktree_id" ] || {
        fm_backend_policy_refuse "task $id endpoint record (legacy Orca worktree)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      }
      if [ "$window" != "fm-$id" ] \
        || ! fm_backend_endpoint_atom_valid "$terminal" \
        || ! fm_backend_endpoint_atom_valid "$worktree_id"; then
        fm_backend_policy_refuse "task $id endpoint record (legacy Orca endpoint)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      fi
      window=$terminal
      ;;
    cmux)
      [ "$binding" = "$id" ] || {
        fm_backend_policy_refuse "task $id endpoint record (legacy cmux endpoint)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      }
      workspace=$(fm_backend_meta_exact_value "$meta" cmux_workspace_id) || workspace=
      surface=$(fm_backend_meta_exact_value "$meta" cmux_surface_id) || surface=
      if [ -z "$workspace" ] || [ -z "$surface" ] || [ "$window" != "$workspace:$surface" ] \
        || ! fm_backend_endpoint_atom_valid "$workspace" \
        || ! fm_backend_endpoint_atom_valid "$surface"; then
        fm_backend_policy_refuse "task $id endpoint record (legacy cmux endpoint)" "$backend" \
          "$(fm_backend_policy_legacy_record_remediation) Task state is preserved."
        return 1
      fi
      ;;
  esac
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_BACKEND=$backend
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_TARGET=$window
  return 0
}

fm_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta window terminal
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(fm_meta_get "$meta" window)
    terminal=$(fm_meta_get "$meta" terminal)
    { [ -n "$window" ] && [ "$window" = "$target" ]; } || { [ -n "$terminal" ] && [ "$terminal" = "$target" ]; } || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_backend_task_id_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  case "$raw" in
    *:*) return 1 ;;
  esac
  if [ -f "$state/$raw.meta" ]; then
    printf '%s' "$raw"
    return 0
  fi
  case "$raw" in
    fm-*)
      id=${raw#fm-}
      [ -f "$state/$id.meta" ] || return 1
      printf '%s' "$id"
      return 0
      ;;
  esac
  return 1
}

fm_backend_meta_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state") || return 1
  printf '%s/%s.meta' "$state" "$id"
}

fm_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta target
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    local backend
    backend=$(fm_backend_of_meta "$meta") || return 1
    [ "$backend" = "$FM_BACKEND_ACTIVE" ] || return 1
    target=$resolved
    [ -n "$target" ] || target=$(fm_backend_target_of_meta "$meta")
    fm_backend_herdr_capability_preflight "selector backend for $raw" "${target%%:*}" || return 2
    printf '%s' "$backend"
    return $?
  fi
  if [ -n "$resolved" ]; then
    meta=$(fm_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    if [ -n "$meta" ]; then
      local backend
      backend=$(fm_backend_of_meta "$meta") || return 1
      [ "$backend" = "$FM_BACKEND_ACTIVE" ] || return 1
      target=$resolved
      [ -n "$target" ] || target=$(fm_backend_target_of_meta "$meta")
      fm_backend_herdr_capability_preflight "selector backend for $raw" "${target%%:*}" || return 2
      printf '%s' "$backend"
      return $?
    fi
  fi
  # An explicit target with no matching record is a Herdr "<session>:<pane-id>"
  # endpoint in the active runtime; the adapter's capability proof is required
  # before the backend identity is returned.
  if fm_backend_policy_legacy_lane; then
    printf 'tmux'
  else
    fm_backend_herdr_capability_preflight "selector backend for $raw" "${resolved%%:*}" || return 2
    printf '%s' "$FM_BACKEND_ACTIVE"
  fi
}

fm_backend_expected_label_of_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$id" ] && printf 'fm-%s' "$id"
  return 0
}

# fm_backend_source: source the named backend's adapter file, once per shell.
# Each adapter is an independently linted canonical root. The /dev/null source
# boundaries keep runtime dispatch from importing all five adapter ASTs into
# every dispatcher consumer while preserving the runtime source operations.
fm_backend_source() {  # <name> [origin] [session] [spawn]
  local name=$1 origin=${2:-Herdr runtime operation} session=${3:-} mode=${4:-}
  fm_backend_validate "$name" || return 1
  case "$name" in
    tmux)
      if [ -z "${_FM_BACKEND_TMUX_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_BACKEND_LIB_DIR/backends/tmux.sh" || return 1
        _FM_BACKEND_TMUX_SOURCED=1
      fi
      ;;
    herdr)
      if [ -z "${_FM_BACKEND_HERDR_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_BACKEND_LIB_DIR/backends/herdr.sh" || return 1
        _FM_BACKEND_HERDR_SOURCED=1
      fi
      ;;
    zellij)
      if [ -z "${_FM_BACKEND_ZELLIJ_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_BACKEND_LIB_DIR/backends/zellij.sh" || return 1
        _FM_BACKEND_ZELLIJ_SOURCED=1
      fi
      ;;
    orca)
      if [ -z "${_FM_BACKEND_ORCA_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_BACKEND_LIB_DIR/backends/orca.sh" || return 1
        _FM_BACKEND_ORCA_SOURCED=1
      fi
      ;;
    cmux)
      if [ -z "${_FM_BACKEND_CMUX_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_BACKEND_LIB_DIR/backends/cmux.sh" || return 1
        _FM_BACKEND_CMUX_SOURCED=1
      fi
      ;;
  esac
  if [ "$name" = herdr ]; then
    fm_backend_herdr_capability_check "$origin" || return 2
    if [ "$mode" = spawn ] || [ "$mode" = setup ]; then
      return 0
    fi
    [ -n "$session" ] || session=$(fm_backend_herdr_session)
    fm_backend_herdr_session_capability_check "$session" >/dev/null 2>&1 && return 0
    fm_backend_policy_refuse "$origin" herdr \
      "The native Herdr session capability check failed. Repair Herdr, then verify the named session with 'herdr status --json'."
    return 2
  fi
}

# fm_backend_resolve_selector: resolve a raw fm-send.sh/fm-peek.sh style
# selector to a live session-provider target. Four forms, in order:
#   target with ":"   used as-is (the escape hatch for a window/pane outside
#                      this firstmate home) - backend-independent, a literal string.
#   exact task id      routed through <state-dir>/<id>.meta's backend target
#                      (`window=` normally, `terminal=` for Orca), after the
#                      active backend's native capability proof.
#   "fm-<id>"          legacy task window label fallback routed through
#                      <state-dir>/<id>.meta when no exact
#                      <state-dir>/fm-<id>.meta exists.
#   anything else      first matched against recorded `window=`/`terminal=`
#                      metadata, then treated as an ad hoc bare window name and
#                      resolved by searching the legacy tmux live inventory.
fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window id backend=
  case "$raw" in
    *:*)
      if ! fm_backend_policy_legacy_lane; then
        fm_backend_herdr_capability_preflight "explicit endpoint resolution" "${raw%%:*}" || return 2
      fi
      printf '%s' "$raw"
      return 0
      ;;
  esac
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    id=${meta##*/}
    id=${id%.meta}
    if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      fm_backend_validate_remote_meta "$meta" "$id" || return 1
    else
      backend=$(fm_backend_of_meta "$meta") || return 1
      [ "$backend" = "$FM_BACKEND_ACTIVE" ] || return 1
    fi
    window=$(fm_backend_target_of_meta "$meta")
    [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
    [ "$backend" != "$FM_BACKEND_ACTIVE" ] || \
      fm_backend_herdr_capability_preflight "selector resolution for task $id" "${window%%:*}" || return 2
    printf '%s' "$window"
    return 0
  fi
  case "$raw" in
    fm-*)
      echo "error: no metadata for $raw in $state; pass session:window to target a window outside this firstmate home" >&2
      return 1
      ;;
    *)
      meta=$(fm_backend_meta_for_window "$raw" "$state" 2>/dev/null || true)
      if [ -n "$meta" ]; then
        backend=$(fm_backend_of_meta "$meta") || return 1
        [ "$backend" = "$FM_BACKEND_ACTIVE" ] || return 1
        window=$(fm_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
        fm_backend_herdr_capability_preflight "selector resolution for task ${meta##*/}" "${window%%:*}" || return 2
        printf '%s' "$window"
        return 0
      fi
      # Active runtime: a bare window name has no inventory to search - Herdr
      # endpoints are "<session>:<pane-id>" and every task is reachable by id.
      # The legacy tmux live-inventory search survives only in the regression lane.
      if ! fm_backend_policy_legacy_lane; then
        echo "error: target '$raw' has no task record in $state, and bare window names are not resolvable because Herdr is the sole supported runtime backend; pass a task id, fm-<id>, or an explicit <herdr-session>:<pane-id> target" >&2
        return 1
      fi
      fm_backend_source tmux || return 1
      fm_backend_tmux_resolve_bare_selector "$raw"
      ;;
  esac
}

# --- generic per-op dispatch -------------------------------------------------
#
# Thin case-dispatch wrappers so a caller names an operation and a backend
# rather than hand-writing `case "$backend" in tmux) fm_backend_tmux_x ;; esac`
# at every call site. Each verified backend adds its own arm here, without
# changing call sites.

# fm_backend_capture: bounded plain-text session capture.
fm_backend_capture() {  # <backend> <target> <lines> [expected-label]
  local backend=$1 target
  shift
  target=${1:-}
  fm_backend_source "$backend" "capture" "${target%%:*}" || return $?
  case "$backend" in
    tmux) fm_backend_tmux_capture "$@" ;;
    herdr) fm_backend_herdr_capture "$@" ;;
    zellij) fm_backend_zellij_capture "$@" ;;
    orca) fm_backend_orca_capture "$@" ;;
    cmux) fm_backend_cmux_capture "$@" ;;
    *) echo "error: no capture implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_send_key: one backend-supported named special key.
fm_backend_send_key() {  # <backend> <target> <key> [expected-label]
  local backend=$1 target
  shift
  target=${1:-}
  fm_backend_source "$backend" "send key" "${target%%:*}" || return $?
  case "$backend" in
    tmux) fm_backend_tmux_send_key "$@" ;;
    herdr) fm_backend_herdr_send_key "$@" ;;
    zellij) fm_backend_zellij_send_key "$@" ;;
    orca) fm_backend_orca_send_key "$@" ;;
    cmux) fm_backend_cmux_send_key "$@" ;;
    *) echo "error: no send-key implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_send_text_submit: type text once, then submit and verify,
# retrying only the submission (never retyping). Echoes the backend's
# proof-carrying verdict; callers require exact empty for confirmed delivery.
fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local backend=$1 target
  shift
  target=${1:-}
  fm_backend_source "$backend" "send text" "${target%%:*}" || return $?
  case "$backend" in
    tmux) fm_backend_tmux_send_text_submit "$@" ;;
    herdr) fm_backend_herdr_send_text_submit "$@" ;;
    zellij) fm_backend_zellij_send_text_submit "$@" ;;
    orca) fm_backend_orca_send_text_submit "$@" ;;
    cmux) fm_backend_cmux_send_text_submit "$@" ;;
    *) echo "error: no send-text implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_kill: remove the task's session endpoint (best-effort; a
# nonexistent/already-gone target is not an error - callers already swallow
# failures here exactly as the inline `tmux kill-window ... || true` did).
fm_backend_kill() {  # <backend> <target>
  local backend=$1 target
  shift
  [ -n "${1:-}" ] || { echo "error: refusing empty backend kill target" >&2; return 1; }
  target=$1
  fm_backend_source "$backend" "kill endpoint" "${target%%:*}" || return $?
  case "$backend" in
    tmux) fm_backend_tmux_kill "$@" ;;
    herdr) fm_backend_herdr_kill "$@" ;;
    zellij) fm_backend_zellij_kill "$@" ;;
    orca) fm_backend_orca_kill "$@" ;;
    cmux) fm_backend_cmux_kill "$@" ;;
    *) echo "error: no kill implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_remove_worktree() {  # <backend> <worktree-id>
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    orca) fm_backend_orca_remove_worktree "$@" ;;
    *) echo "error: backend '$backend' does not own task worktrees" >&2; return 1 ;;
  esac
}

fm_backend_worktree_path() {  # <backend> <worktree-id>
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    orca) fm_backend_orca_worktree_path "$@" ;;
    *) echo "error: backend '$backend' does not own task worktrees" >&2; return 1 ;;
  esac
}

# fm_backend_busy_state: semantic busy/idle/unknown for backends that expose
# native agent-state (herdr-addendum "busy state" row - the first backend
# where this gets real semantics beyond pane-regex). Backends with no such
# primitive (tmux) report unknown. Callers own the fallback policy: fm-watch.sh
# uses unknown as the cue for harness-scoped pane-tail detection, while
# fm-crew-state.sh also corroborates native idle verdicts with the recorded
# harness's signature before treating a no-run crew as not busy.
fm_backend_busy_state() {  # <backend> <target>
  local backend=$1 target
  shift
  target=${1:-}
  fm_backend_source "$backend" "busy state" "${target%%:*}"
  local source_rc=$?
  if [ "$source_rc" -ne 0 ]; then
    fm_backend_policy_legacy_lane && { printf 'unknown'; return 0; }
    return "$source_rc"
  fi
  case "$backend" in
    herdr) fm_backend_herdr_busy_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_composer_state: classify the composer/input area of <target> as
# empty|pending|pending-unproven|unknown for callers that need a pre-submit
# input guard, a submit acknowledgement, or a launch-readiness check. It is
# exposed so a caller other than the send path (the away-mode daemon's
# supervisor-pane pending-input guard in bin/fm-supervise-daemon.sh, and
# fm-spawn.sh's kimi readiness/delivery checks) can ask the same question
# without duplicating per-backend composer reading. Every adapter's named
# classifier is a THIN wrapper - capture plus a capability descriptor fed to
# the one shared shape owner (bin/fm-composer-lib.sh,
# fm_composer_classify_screen) - so no backend can hold a private shape
# assumption; zellij's classifier reads `dump-screen --ansi`, which replaced
# its old no-classifier content-diff reporting.
fm_backend_composer_state() {  # <backend> <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local backend=$1 target
  shift
  target=${1:-}
  fm_backend_source "$backend" "composer state" "${target%%:*}"
  local source_rc=$?
  if [ "$source_rc" -ne 0 ]; then
    fm_backend_policy_legacy_lane && { printf 'unknown'; return 0; }
    return "$source_rc"
  fi
  case "$backend" in
    tmux) fm_tmux_composer_state "$@" ;;
    herdr) fm_backend_herdr_composer_state "$@" ;;
    orca) fm_backend_orca_composer_state "$@" ;;
    cmux) fm_backend_cmux_composer_state "$@" ;;
    zellij) fm_backend_zellij_composer_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_target_exists: cheap, READ-ONLY existence check - does the
# recorded TARGET endpoint still exist on BACKEND? Never starts a server or
# session: for herdr this deliberately queries the pane directly instead of
# going through fm_backend_herdr_target_ready (which auto-starts the herdr
# server as a side effect via fm_backend_herdr_server_ensure - fine for an
# operation that is about to use the pane, wrong for a passive liveness
# probe). A gone tmux window or an unqueryable herdr pane (server down, pane
# closed), missing zellij pane, or unreadable Orca terminal simply fails, which
# IS "does not exist" for this purpose.
# Mirrors fm-crew-state.sh's pane_readable check; exists here as one shared
# primitive so callers that only need a fast alive/dead read (recovery
# digests, the session-start fleet digest) do not re-derive it inline.
fm_backend_target_exists() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 expected_label=${3:-} session pane pane_out pane_rc pane_error_code
  # The tmux arm below calls the tmux CLI directly rather than through
  # fm_backend_source, so the invariant is enforced here explicitly: a retained
  # legacy backend is refused before any runtime command runs.
  fm_backend_validate "$backend" || return 1
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
      ;;
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_capability_preflight "target existence check" "$session" || return 2
      # fm_backend_herdr_cli (not a raw HERDR_SESSION-only call): verified
      # empirically (docs/herdr-backend.md "Session targeting") that the bare
      # env var alone is NOT reliably honored once another herdr server is
      # already bound on the machine - it silently queries whatever server IS
      # running instead. fm_backend_herdr_cli appends the required --session
      # flag on top, so this check is correctly scoped even when the caller's
      # own ambient session (e.g. the primary firstmate's default session) is
      # a DIFFERENT one than the target's.
      if pane_out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1); then
        pane_rc=0
      else
        pane_rc=$?
      fi
      pane_error_code=$(printf '%s' "$pane_out" | jq -r '.error.code // empty' 2>/dev/null || true)
      if [ "$pane_rc" -eq 0 ] && [ -z "$pane_error_code" ]; then
        return 0
      fi
      [ "$pane_error_code" = pane_not_found ] && return 1
      fm_backend_policy_refuse "Herdr target $target" herdr \
        "The verified Herdr session became unavailable while reading the endpoint. Repair Herdr, then verify with 'herdr status --json'."
      return 2
      ;;
    zellij)
      fm_backend_source zellij || return 1
      fm_backend_zellij_target_ready "$target" "$expected_label"
      ;;
    orca)
      fm_backend_source orca || return 1
      fm_backend_orca_capture "$target" 1 >/dev/null 2>&1
      ;;
    cmux)
      fm_backend_source cmux || return 1
      fm_backend_cmux_target_ready "$target" "$expected_label"
      ;;
    *)
      return 1
      ;;
  esac
}

# fm_backend_agent_state: the single recovery-grade agent/endpoint state
# contract. It is deliberately richer than fm_backend_target_exists's cheap
# pane-presence read and prints exactly one of:
#   alive      - a verified harness agent is running.
#   dead       - the endpoint exists but confidently has no agent.
#   missing    - the recorded endpoint is authoritatively absent.
#   ambiguous  - the endpoint exists but its process cannot be attributed.
#   unreadable - a target or inventory read failed or contradicted itself.
#   unverified - this backend has no recovery classifier.
# Only `dead` and `missing` license recovery. The tmux adapter requires a
# successful session inventory and returns `missing` only when it omits the
# exact window; the Herdr adapter reuses its husk
# classifier. Zellij remains unverified because its secondmate ghost-tab and
# agent-process recovery path has not been empirically validated. Orca and cmux
# do not support secondmate spawns.
fm_backend_agent_state() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" "agent state" "${target%%:*}"
  local source_rc=$?
  if [ "$source_rc" -ne 0 ]; then
    fm_backend_policy_legacy_lane && { printf 'unverified'; return 0; }
    return "$source_rc"
  fi
  case "$backend" in
    tmux) fm_backend_tmux_agent_state "$target" ;;
    herdr) fm_backend_herdr_agent_state "$target" ;;
    *) printf 'unverified' ;;
  esac
}

# Backward-compatible three-state view for existing callers. An
# authoritatively missing endpoint is confidently not a live agent, while every
# ambiguous, unreadable, or unverified result stays unknown.
fm_backend_agent_alive() {  # <backend> <target>
  local state state_rc
  state=$(fm_backend_agent_state "$1" "$2")
  state_rc=$?
  [ "$state_rc" -eq 0 ] || return "$state_rc"
  case "$state" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# --- native event push (backend-extensible) ---------------------------------
#
# The watcher's event-wait splice (bin/fm-watch.sh) is backend-agnostic: it asks
# fm_backend_has_push whether a window's backend can push semantic state changes,
# and for those backends replaces its blind `sleep POLL` with a bounded wait on
# fm_backend_wait_transition. Every push-capable backend reuses the shared
# normalized-transition shape and policy table (bin/fm-transition-lib.sh); today
# only herdr implements the surface (docs/herdr-backend.md "Native
# pane.agent_status_changed push escalation"). A backend with no native push
# reports has-push false and returns 2 from the dispatchers below, so the
# watcher falls back to its poll loop - the permanent fail-closed backstop.

# fm_backend_has_push: 0 if <backend> exposes a native transition push stream.
fm_backend_has_push() {  # <backend>
  case "$1" in
    herdr) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_backend_events_capable: 0 if <backend>'s push path is usable for <session>
# right now (version/schema/reader gate). Non-push backends are never capable.
# The watcher memoizes this per session so the potentially heavy capability
# probe is not repeated every poll.
fm_backend_events_capable() {  # <backend> <session>
  local backend=$1 session=$2
  shift 2
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" "event capability" "$session" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_events_capable "$session" "$@" ;;
    *) return 1 ;;
  esac
}

# fm_backend_wait_transition: bounded wait for a fresh actionable (blocked)
# transition on one of <pane_window...> in <session>, up to <timeout_secs>.
# Prints the normalized transition record and returns 0 on a fresh actionable
# edge; returns 1 on a clean timeout (the caller has effectively already slept);
# returns 2 when the event path is unusable (the caller sleeps the budget
# itself). Non-push backends always return 2.
fm_backend_wait_transition() {  # <backend> <session> <timeout_secs> <state_dir> <pane_window...>
  local backend=$1 session=$2
  shift 2
  fm_backend_has_push "$backend" || return 2
  fm_backend_source "$backend" "event wait" "$session" || return 2
  case "$backend" in
    herdr) fm_backend_herdr_wait_transition "$session" "$@" ;;
    *) return 2 ;;
  esac
}

fm_backend_commit_transition() {  # <backend> <state_dir> <session> <record>
  local backend=$1 state_dir=$2 session=$3
  shift 3
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" "event commit" "$session" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_commit_transition "$state_dir" "$session" "$@" ;;
    *) return 1 ;;
  esac
}

fm_backend_clear_transition() {  # <backend> <state_dir> <window>
  local backend=$1 state_dir=$2 window=$3
  shift 3
  fm_backend_has_push "$backend" || return 0
  fm_backend_source "$backend" "event clear" "${window%%:*}" || return 1
  case "$backend" in
    herdr) fm_backend_herdr_clear_transition "$state_dir" "$window" "$@" ;;
    *) return 0 ;;
  esac
}
