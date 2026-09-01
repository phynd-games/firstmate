#!/usr/bin/env bash
# fm-dashboard-build.sh - build, or verify, the dashboard client bundle.
#
# The built client lives in assets/dashboard/ and is COMMITTED. That is what
# lets a fresh machine, and CI, serve the dashboard with no network and no
# install step: the toolchain is a development convenience, never a runtime or
# CI dependency.
#
# With a toolchain present this rebuilds from ui/src through the project's own
# vite build, whose output names are pinned flat in ui/vite.config.ts because the
# server serves assets by exact basename. Without a toolchain it verifies the
# committed bundle instead of failing, because a machine that cannot build can
# still serve. What it never does is report success over a missing or unreadable
# bundle: `verify` is the same check startup runs before it will print a URL.
#
# Usage:
#   fm-dashboard-build.sh build    rebuild from source when a toolchain exists
#   fm-dashboard-build.sh verify   check the committed bundle is complete
#   fm-dashboard-build.sh watch    rebuild on change (development only)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UI="$ROOT/ui"
APP="${FM_DASHBOARD_APP_DIR:-$ROOT/assets/dashboard}"
REQUIRED="index.html app.js app.css"

fail() { printf 'fm-dashboard-build: %s\n' "$*" >&2; exit 1; }

verify() {
  local f
  [ -d "$APP" ] && [ ! -L "$APP" ] || fail "the application directory is missing: $APP"
  for f in $REQUIRED; do
    [ -f "$APP/$f" ] && [ ! -L "$APP/$f" ] || fail "the built client is incomplete: $APP/$f is missing"
    [ -s "$APP/$f" ] || fail "the built client is empty: $APP/$f"
  done
  # The bundle must actually be the app, not a stub: a served shell with no
  # mount point would render an empty page that looks like an idle fleet.
  grep -q 'id="root"' "$APP/index.html" || fail "$APP/index.html has no application mount point"
  printf 'dashboard client: verified (%s)\n' "$APP"
}

# One runner, resolved the same way for build and watch: bun is what the client
# was initialized with, npm is the fallback, and neither being present is not an
# error - it is the committed-bundle path.
ui_runner() {
  [ -d "$UI/node_modules" ] || return 1
  if command -v bun >/dev/null 2>&1; then
    printf 'bun\n'
    return 0
  fi
  if command -v npm >/dev/null 2>&1; then
    printf 'npm\n'
    return 0
  fi
  return 1
}

case "${1-}" in
  build)
    if runner=$(ui_runner); then
      case "$runner" in
        bun) (cd "$UI" && bun run build) ;;
        npm) (cd "$UI" && npm run build) ;;
      esac
    else
      printf 'dashboard client: no toolchain, serving the committed bundle\n'
    fi
    verify
    ;;
  watch)
    runner=$(ui_runner) \
      || fail "watch needs ui/node_modules and bun or npm (run: bun install --cwd ui)"
    case "$runner" in
      bun) (cd "$UI" && bun run vite build --watch) ;;
      npm) (cd "$UI" && npm exec -- vite build --watch) ;;
    esac
    ;;
  verify) verify ;;
  -h|--help|help)
    sed -n '2,20{s/^# \{0,1\}//;p;}' "$0"
    ;;
  *) sed -n '2,20{s/^# \{0,1\}//;p;}' "$0" >&2; exit 2 ;;
esac
