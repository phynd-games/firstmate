#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names are unchanged from when this logic lived inline in
# bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh) keep
# exercising the same names after the daemon sources this file.
#
# HERDR-ONLY RUNTIME (AGENTS.md hard rule 6; owner bin/fm-backend-policy-lib.sh).
# In the active runtime the supervisor pane is a Herdr pane or nothing:
# FM_SUPERVISOR_BACKEND must be herdr when set, $TMUX_PANE never selects, and
# with no override the pane is discovered only from Herdr's own injected
# HERDR_ENV=1 + HERDR_PANE_ID identity. There is no `firstmate:0` tmux default;
# an undiscoverable pane refuses through fm_backend_policy_refuse and prints
# nothing, so a caller can never inject into a guessed endpoint.

_FM_SUPERVISOR_TARGET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend-policy-lib.sh
. "$_FM_SUPERVISOR_TARGET_LIB_DIR/fm-backend-policy-lib.sh"

# Defaults consulted when nothing is configured or detected. In the active
# runtime the backend default is herdr and the target default is EMPTY: the
# daemon's inject/busy readers (which fall back to these when startup discovery
# never ran, e.g. sourced test contexts) must then fail their existence check
# rather than address a tmux pane named "firstmate:0". The tmux pair survives
# only in the regression lane, byte-for-byte the daemon's pre-herdr behavior.
if fm_backend_policy_legacy_lane; then
  FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
  FM_SUPERVISOR_BACKEND_DEFAULT="tmux"
else
  FM_SUPERVISOR_TARGET_DEFAULT=""
  FM_SUPERVISOR_BACKEND_DEFAULT="$FM_BACKEND_ACTIVE"
fi

# Remediation shared by both discovery refusals below.
fm_supervisor_herdr_remediation() {
  printf 'Run the primary Firstmate session inside a Herdr pane so Herdr injects HERDR_ENV=1 and HERDR_PANE_ID, or set FM_SUPERVISOR_BACKEND=herdr and FM_SUPERVISOR_TARGET=<herdr-session>:<pane-id> explicitly.%s' \
    "$(fm_backend_policy_marker_note)"
}

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - a herdr
#      "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which backend; a tmux target is accepted only in the lane).
#   2. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID.
#   3. Refuse: print nothing, emit the policy diagnostic, return 1.
# Regression lane only: $TMUX_PANE is consulted between 1 and 2 (a tmux pane
# nested inside herdr resolves to tmux), and step 3 prints the legacy tmux
# default "firstmate:0" while still returning 1 so the caller can warn.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if fm_backend_policy_legacy_lane && [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  if fm_backend_policy_legacy_lane; then
    printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
    return 1
  fi
  fm_backend_policy_refuse "supervisor pane discovery (FM_SUPERVISOR_TARGET unset, no Herdr pane identity in the environment)" "" \
    "$(fm_supervisor_herdr_remediation)"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives to dispatch through. Priority:
#   1. FM_SUPERVISOR_BACKEND env (explicit override) - must be herdr; any other
#      value refuses through the policy diagnostic (accepted verbatim only in
#      the regression lane, where the daemon's own supported-set check judges it).
#   2. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   3. Refuse: print nothing, emit the policy diagnostic, return 1.
# Regression lane only: $TMUX_PANE set selects tmux between 1 and 2, and step 3
# prints the legacy tmux default while returning 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    if fm_backend_policy_legacy_lane || [ "$FM_SUPERVISOR_BACKEND" = "$FM_BACKEND_ACTIVE" ]; then
      printf '%s' "$FM_SUPERVISOR_BACKEND"
      return 0
    fi
    fm_backend_policy_refuse "FM_SUPERVISOR_BACKEND" "$FM_SUPERVISOR_BACKEND" \
      "$(fm_supervisor_herdr_remediation)"
    return 1
  fi
  if fm_backend_policy_legacy_lane && [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s' "$FM_BACKEND_ACTIVE"
    return 0
  fi
  if fm_backend_policy_legacy_lane; then
    printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
    return 1
  fi
  fm_backend_policy_refuse "supervisor backend discovery (FM_SUPERVISOR_BACKEND unset, no Herdr pane identity in the environment)" "" \
    "$(fm_supervisor_herdr_remediation)"
  return 1
}
