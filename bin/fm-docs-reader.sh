#!/usr/bin/env bash
# fm-docs-reader.sh - the local Markdown document reader for one Firstmate home.
#
# Serves every Markdown file under this home's data/ directory as a navigable,
# live-reloading site on the loopback interface, so a report link the captain
# receives opens as a formatted page instead of a raw file. The server is
# MkDocs (its own navigation, search, theme, and live reload) driven by a
# private generated configuration; bin/fm-docs-reader-hooks.py narrows the site
# to Markdown and raster images inside the real data/ directory and sanitizes
# every rendered page, so report text is never compiled or executed and never
# triggers a network fetch. There is no dashboard, no task control, and no
# write path: the reader reads data/ and writes only under state/.
#
# NO FALSE URL. A URL is printed only after a GET against 127.0.0.1 returned the
# page and the page carried this home's identity token. Anything unproven prints
# a plain reason instead, so a caller can fall back to the file path honestly.
#
# IDEMPOTENT AND RESTART-SAFE. `ensure` converges on one server per home: a
# per-home lock serializes concurrent callers, a live recorded server is reused,
# a dead one is replaced, and a recorded pid that no longer runs this reader is
# left alone and forgotten rather than killed. A port already answering for
# another process is skipped for the next candidate; nothing is ever killed
# that this script cannot prove is its own reader for this home.
#
# LOOPBACK ONLY. The server binds 127.0.0.1 exclusively. There is no host flag.
#
# Usage:
#   fm-docs-reader.sh install [--refresh]  create the private pinned runtime
#                                          (state/docs-reader/venv) from
#                                          defaults/docs-reader-requirements.txt
#   fm-docs-reader.sh ensure               start or adopt this home's reader and
#                                          print `DOCS_READER: <url>`, or
#                                          `DOCS_READER: unavailable - <reason>`
#   fm-docs-reader.sh status               report without starting anything
#   fm-docs-reader.sh url <path>[#anchor]  print the verified page URL for one
#                                          Markdown file under data/ (starts the
#                                          reader when needed); on failure print
#                                          the reason to stderr and exit 1
#   fm-docs-reader.sh url --no-start <path>  the same without starting a server
#   fm-docs-reader.sh stop                 stop the reader this home recorded
#   fm-docs-reader.sh python               print the interpreter the reader uses
#
# Runtime resolution, first match wins: FM_DOCS_READER_PYTHON, the private
# venv from `install`, then `python3` on PATH (a Nix environment that already
# carries mkdocs, nh3, and pygments). An interpreter counts only when it imports
# all three modules. Python 3.10 or newer is required.
#
# Durable records, all under this home's state/ (gitignored with it):
#   .docs-reader          key=value owner record: pid, port, url, home, config,
#                         python, started
#   .docs-reader.lock     the per-home lock serializing ensure/stop
#   docs-reader/          the generated mkdocs.yml, theme override, private
#                         venv (after install), and serve.log
#
# Tuning:
#   FM_DOCS_READER_PORT         first candidate port (default: 8600 + a stable
#                               per-home hash, so each home keeps its port)
#   FM_DOCS_READER_PORT_TRIES   candidate ports to try (default 10)
#   FM_DOCS_READER_READY_SECS   seconds to wait for a fresh server (default 20)
#   FM_DOCS_READER_HTTP_SECS    seconds per verification request (default 3)
#   FM_DOCS_READER_PYTHON       interpreter override
#   config/docs-reader          `off` disables the reader for this home
#
# Under the test harness (FM_BACKEND_TEST_HARNESS=1) nothing starts unless
# FM_DOCS_READER_TEST_ALLOW=1, so unrelated suites never leave servers behind.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

READER_DIR="$STATE/docs-reader"
RECORD="$STATE/.docs-reader"
LOCK="$STATE/.docs-reader.lock"
MKDOCS_CONFIG="$READER_DIR/mkdocs.yml"
THEME_DIR="$READER_DIR/theme"
VENV_DIR="$READER_DIR/venv"
SERVE_LOG="$READER_DIR/serve.log"
REQUIREMENTS="$FM_ROOT/defaults/docs-reader-requirements.txt"
HOOKS="$SCRIPT_DIR/fm-docs-reader-hooks.py"

FM_DOCS_READER_PORT_TRIES=${FM_DOCS_READER_PORT_TRIES:-10}
FM_DOCS_READER_READY_SECS=${FM_DOCS_READER_READY_SECS:-20}
FM_DOCS_READER_HTTP_SECS=${FM_DOCS_READER_HTTP_SECS:-3}
LOG_MAX_BYTES=1048576

# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_LIB_NO_STATE_MKDIR=1 . "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-docs-reader.sh" | sed 's/^# \{0,1\}//; $d'
}

die() {  # <message>
  printf 'fm-docs-reader: %s\n' "$1" >&2
  exit 1
}

realdir() {  # <dir> - physical path, empty when missing
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

write_atomic() {  # <dest>, content on stdin
  local dest=$1 tmp
  tmp=$(mktemp "$dest.XXXXXX" 2>/dev/null) || return 1
  if cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

write_if_changed() {  # <dest>, content on stdin
  local dest=$1 content
  content=$(cat)
  if [ -f "$dest" ] && [ "$(cat "$dest" 2>/dev/null)" = "$content" ]; then
    return 0
  fi
  printf '%s\n' "$content" | write_atomic "$dest"
}

# --- identity ---------------------------------------------------------------

HOME_REAL=$(realdir "$FM_HOME")
[ -n "$HOME_REAL" ] || HOME_REAL=$FM_HOME
DATA_REAL=$(realdir "$DATA")

home_token() {
  printf 'fm-docs-%s' "$(printf '%s' "$HOME_REAL" | cksum | awk '{printf "%08x", $1}')"
}

default_port() {
  local sum
  sum=$(printf '%s' "$HOME_REAL" | cksum | awk '{print $1}')
  printf '%d' $((8600 + sum % 200))
}

record_get() {  # <key>
  [ -f "$RECORD" ] || return 0
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$RECORD" 2>/dev/null
}

record_write() {  # <pid> <port> <python>
  write_atomic "$RECORD" <<EOF
pid=$1
port=$2
url=http://127.0.0.1:$2/
home=$HOME_REAL
config=$MKDOCS_CONFIG
python=$3
started=$(date +%s)
EOF
}

record_drop() {
  rm -f "$RECORD" 2>/dev/null || true
}

# process_is_ours <pid>: alive AND running this home's mkdocs configuration.
process_is_ours() {
  local pid=$1 command
  fm_pid_alive "$pid" || return 1
  command=$(ps -o command= -p "$pid" 2>/dev/null || true)
  case "$command" in
    *mkdocs*"$MKDOCS_CONFIG"*) return 0 ;;
  esac
  return 1
}

# port_answers_as_ours <port>: the page at / carries this home's token.
port_answers_as_ours() {
  local port=$1 body
  body=$(curl -s --max-time "$FM_DOCS_READER_HTTP_SECS" "http://127.0.0.1:$port/" 2>/dev/null) || return 1
  case "$body" in
    *"name=\"fm-docs-home\" content=\"$(home_token)\""*) return 0 ;;
  esac
  return 1
}

port_in_use() {  # <port>
  curl -s -o /dev/null --max-time "$FM_DOCS_READER_HTTP_SECS" "http://127.0.0.1:$1/" 2>/dev/null
}

# --- runtime ------------------------------------------------------------------

python_ok() {  # <interpreter>
  [ -n "$1" ] && [ -x "$1" ] || return 1
  "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null || return 1
  "$1" -c 'import mkdocs, nh3, pygments' >/dev/null 2>&1
}

resolve_python() {
  local candidate
  for candidate in "${FM_DOCS_READER_PYTHON:-}" "$VENV_DIR/bin/python" "$(command -v python3 2>/dev/null || true)"; do
    if python_ok "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

base_python() {
  local candidate name
  for name in "${FM_DOCS_READER_PYTHON:-}" python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
    [ -n "$name" ] || continue
    case "$name" in
      /*) candidate=$name ;;
      *) candidate=$(command -v "$name" 2>/dev/null || true) ;;
    esac
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c 'import sys, venv; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

requirements_digest() {
  cksum "$REQUIREMENTS" 2>/dev/null | awk '{print $1}'
}

cmd_install() {
  local refresh=0 base stamp
  case "${1:-}" in
    --refresh) refresh=1 ;;
    '') ;;
    *) die "install takes only --refresh" ;;
  esac
  [ -f "$REQUIREMENTS" ] || die "pinned requirements missing: $REQUIREMENTS"
  stamp="$VENV_DIR/.fm-requirements"
  if [ "$refresh" -eq 0 ] && python_ok "$VENV_DIR/bin/python" \
    && [ "$(cat "$stamp" 2>/dev/null)" = "$(requirements_digest)" ]; then
    printf 'DOCS_READER_INSTALL: already installed (%s)\n' "$VENV_DIR"
    return 0
  fi
  base=$(base_python) || die 'no Python 3.10+ interpreter with venv support found; install python3 (3.10 or newer) and rerun install'
  mkdir -p "$READER_DIR" || die "cannot create $READER_DIR"
  rm -rf "$VENV_DIR"
  "$base" -m venv "$VENV_DIR" || die 'venv creation failed'
  if ! "$VENV_DIR/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --no-deps -r "$REQUIREMENTS"; then
    rm -rf "$VENV_DIR"
    die 'pinned install failed; the venv was removed so a partial runtime is never used'
  fi
  python_ok "$VENV_DIR/bin/python" || { rm -rf "$VENV_DIR"; die 'installed runtime does not import mkdocs, nh3, and pygments'; }
  requirements_digest > "$stamp"
  printf 'DOCS_READER_INSTALL: ok python=%s mkdocs=%s\n' "$VENV_DIR/bin/python" \
    "$("$VENV_DIR/bin/python" -c 'import mkdocs; print(mkdocs.__version__)' 2>/dev/null)"
}

# --- generated configuration ------------------------------------------------

write_site_config() {  # <python>
  local python=$1 token
  token=$(home_token)
  mkdir -p "$THEME_DIR/css" || return 1
  write_if_changed "$THEME_DIR/main.html" <<EOF
{% extends "base.html" %}
{% block extrahead %}
<meta name="fm-docs-home" content="{{ config.extra.fm_home_token }}">
<link rel="stylesheet" href="{{ 'css/codehilite.css'|url }}">
{% endblock %}
EOF
  if [ ! -s "$THEME_DIR/css/codehilite.css" ]; then
    "$python" -m pygments -S default -f html -a .codehilite > "$THEME_DIR/css/codehilite.css" 2>/dev/null \
      || printf '/* pygments stylesheet unavailable */\n' > "$THEME_DIR/css/codehilite.css"
  fi
  # docs_dir is the real data/ path: the hooks compare every page's real path
  # against it, so a symlinked home cannot make its own pages look like escapes.
  write_if_changed "$MKDOCS_CONFIG" <<EOF
# Generated by bin/fm-docs-reader.sh for $HOME_REAL - do not edit; rerun ensure.
site_name: Firstmate documents ($(basename "$HOME_REAL"))
docs_dir: $DATA_REAL
use_directory_urls: true
strict: false
theme:
  name: mkdocs
  custom_dir: theme
  highlightjs: false
  color_mode: auto
  user_color_mode_toggle: true
  navigation_depth: 3
plugins:
  - search
hooks:
  - $HOOKS
markdown_extensions:
  - toc:
      permalink: true
  - tables
  - fenced_code
  - codehilite:
      guess_lang: false
  - sane_lists
validation:
  links:
    absolute_links: ignore
    unrecognized_links: ignore
    anchors: ignore
    not_found: ignore
  nav:
    omitted_files: ignore
    not_found: ignore
    absolute_links: ignore
extra:
  fm_home_token: $token
EOF
}

# --- lifecycle ----------------------------------------------------------------

disabled_reason() {
  if [ -f "$CONFIG_DIR/docs-reader" ] && [ "$(tr -d '[:space:]' < "$CONFIG_DIR/docs-reader")" = off ]; then
    printf 'turned off by config/docs-reader\n'
    return 0
  fi
  if [ "${FM_BACKEND_TEST_HARNESS:-0}" = 1 ] && [ "${FM_DOCS_READER_TEST_ALLOW:-0}" != 1 ]; then
    printf 'not started under the test harness\n'
    return 0
  fi
  return 1
}

# verified_url: prints the recorded URL when the recorded server is alive,
# ours, and answering with this home's token. Read-only.
verified_url() {
  local pid port
  pid=$(record_get pid)
  port=$(record_get port)
  [ -n "$pid" ] && [ -n "$port" ] || return 1
  [ "$(record_get home)" = "$HOME_REAL" ] || return 1
  process_is_ours "$pid" || return 1
  port_answers_as_ours "$port" || return 1
  printf 'http://127.0.0.1:%s/\n' "$port"
}

# reconcile_record: drop a record that no longer describes a live reader of ours.
# A live pid that is not our reader is left untouched: it belongs to someone else.
reconcile_record() {
  local pid
  pid=$(record_get pid)
  [ -n "$pid" ] || { record_drop; return 0; }
  if process_is_ours "$pid"; then
    return 0
  fi
  record_drop
}

trim_log() {
  local size
  [ -f "$SERVE_LOG" ] || return 0
  size=$(wc -c < "$SERVE_LOG" 2>/dev/null || echo 0)
  [ "$size" -gt "$LOG_MAX_BYTES" ] && : > "$SERVE_LOG"
  return 0
}

wait_ready() {  # <pid> <port> - until the token answers, the pid dies, or the bound
  local pid=$1 port=$2 deadline
  deadline=$(( $(date +%s) + FM_DOCS_READER_READY_SECS ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if port_answers_as_ours "$port"; then
      return 0
    fi
    fm_pid_alive "$pid" || return 1
    sleep 0.25
  done
  return 1
}

start_server() {  # <python> - prints the URL on success
  local python=$1 base_port port tries=0 pid listener
  base_port=${FM_DOCS_READER_PORT:-$(default_port)}
  case "$base_port" in
    ''|*[!0-9]*) base_port=$(default_port) ;;
  esac
  mkdir -p "$READER_DIR" || return 1
  trim_log
  while [ "$tries" -lt "$FM_DOCS_READER_PORT_TRIES" ]; do
    port=$((base_port + tries))
    tries=$((tries + 1))
    if port_in_use "$port"; then
      if port_answers_as_ours "$port"; then
        # A reader of ours whose record was lost: adopt it instead of doubling.
        listener=$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -n1)
        if [ -n "$listener" ] && process_is_ours "$listener"; then
          record_write "$listener" "$port" "$python"
          printf 'http://127.0.0.1:%s/\n' "$port"
          return 0
        fi
      fi
      continue
    fi
    printf '\n[%s] fm-docs-reader starting on 127.0.0.1:%s\n' "$(date -u +%FT%TZ)" "$port" >> "$SERVE_LOG"
    nohup "$python" -m mkdocs serve -f "$MKDOCS_CONFIG" -a "127.0.0.1:$port" \
      >> "$SERVE_LOG" 2>&1 </dev/null &
    pid=$!
    if wait_ready "$pid" "$port"; then
      record_write "$pid" "$port" "$python"
      printf 'http://127.0.0.1:%s/\n' "$port"
      return 0
    fi
    # Not ready in time: reclaim only the process we just started.
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  return 1
}

# ensure_locked: the converge step, run under the per-home lock. Prints the URL.
ensure_locked() {
  local url python reason
  if url=$(verified_url); then
    printf '%s\n' "$url"
    return 0
  fi
  reconcile_record
  if ! python=$(resolve_python); then
    printf 'reader runtime not installed - run bin/fm-docs-reader.sh install (Python 3.10+ with mkdocs, nh3, pygments)\n' >&2
    return 1
  fi
  [ -n "$DATA_REAL" ] || { printf 'data directory missing: %s\n' "$DATA" >&2; return 1; }
  [ -f "$HOOKS" ] || { printf 'hooks missing: %s\n' "$HOOKS" >&2; return 1; }
  write_site_config "$python" || { printf 'could not write %s\n' "$MKDOCS_CONFIG" >&2; return 1; }
  if url=$(start_server "$python"); then
    printf '%s\n' "$url"
    return 0
  fi
  reason="no server answered within ${FM_DOCS_READER_READY_SECS}s on ${FM_DOCS_READER_PORT_TRIES} candidate ports from ${FM_DOCS_READER_PORT:-$(default_port)}"
  [ -f "$SERVE_LOG" ] && reason="$reason; see $SERVE_LOG"
  printf '%s\n' "$reason" >&2
  return 1
}

with_lock() {  # <function> [args...]
  local rc
  mkdir -p "$STATE" || return 1
  fm_lock_acquire_bounded "$LOCK" 200 || { printf 'another fm-docs-reader operation holds %s\n' "$LOCK" >&2; return 1; }
  "$@"
  rc=$?
  fm_lock_release "$LOCK"
  return "$rc"
}

# ensure_url: prints the verified URL to stdout, a reason to stderr, exit 1 otherwise.
ensure_url() {
  local reason
  if reason=$(disabled_reason); then
    printf '%s\n' "$reason" >&2
    return 1
  fi
  with_lock ensure_locked
}

cmd_ensure() {
  local url err
  err=$(mktemp "${TMPDIR:-/tmp}/fm-docs-reader.XXXXXX") || die 'mktemp failed'
  if url=$(ensure_url 2>"$err"); then
    rm -f "$err"
    printf 'DOCS_READER: %s\n' "$url"
    return 0
  fi
  printf 'DOCS_READER: unavailable - %s (Markdown links fall back to file paths)\n' "$(tr '\n' ' ' < "$err" | sed 's/ *$//')"
  rm -f "$err"
  return 1
}

cmd_status() {
  local url reason
  if reason=$(disabled_reason); then
    printf 'DOCS_READER: %s\n' "$reason"
    return 1
  fi
  if url=$(verified_url); then
    printf 'DOCS_READER: %s\n' "$url"
    return 0
  fi
  if [ -f "$RECORD" ]; then
    printf 'DOCS_READER: not running - recorded server (pid %s, port %s) is not answering as this home'"'"'s reader\n' \
      "$(record_get pid)" "$(record_get port)"
  else
    printf 'DOCS_READER: not running - no reader recorded for this home\n'
  fi
  return 1
}

cmd_stop() {
  with_lock stop_locked
}

stop_locked() {
  local pid
  pid=$(record_get pid)
  if [ -z "$pid" ]; then
    printf 'DOCS_READER: nothing recorded to stop\n'
    return 0
  fi
  if ! process_is_ours "$pid"; then
    record_drop
    printf 'DOCS_READER: recorded pid %s is not this home'"'"'s reader; record dropped, process untouched\n' "$pid"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local waited=0
  while fm_pid_alive "$pid" && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  if fm_pid_alive "$pid"; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  record_drop
  printf 'DOCS_READER: stopped pid %s\n' "$pid"
}

# --- url ------------------------------------------------------------------------

# route_for <path>: the site route for one Markdown file under data/, or a
# reason on stderr. Rejects anything that is not a regular .md file whose
# every component under data/ is a real (non-symlink) entry inside data/.
route_for() {
  local given=$1 dir base real_dir real rel current part stem route
  case "$given" in
    /*) ;;
    *) given="$PWD/$given" ;;
  esac
  dir=$(dirname "$given")
  base=$(basename "$given")
  [ -n "$DATA_REAL" ] || { printf 'data directory missing: %s\n' "$DATA" >&2; return 1; }
  real_dir=$(realdir "$dir") || { printf 'no such directory: %s\n' "$dir" >&2; return 1; }
  [ -n "$real_dir" ] || { printf 'no such directory: %s\n' "$dir" >&2; return 1; }
  real="$real_dir/$base"
  case "$base" in
    *.md|*.MD|*.Md|*.mD) ;;
    *) printf 'not a Markdown file: %s\n' "$given" >&2; return 1 ;;
  esac
  [ -f "$real" ] || { printf 'not a regular file: %s\n' "$given" >&2; return 1; }
  case "$real" in
    "$DATA_REAL"/*) ;;
    *) printf 'outside this home'"'"'s data directory (%s): %s\n' "$DATA_REAL" "$given" >&2; return 1 ;;
  esac
  rel=${real#"$DATA_REAL"/}
  current=$DATA_REAL
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    case "$part" in
      .*) printf 'hidden path component is not served: %s\n' "$given" >&2; return 1 ;;
    esac
    current="$current/$part"
    if [ -L "$current" ]; then
      printf 'symlinked path component is not served: %s\n' "$current" >&2
      return 1
    fi
  done <<EOF
$(printf '%s\n' "$rel" | tr '/' '\n')
EOF
  stem=${rel%.*}
  case "$(basename "$stem")" in
    index|README) route=$(dirname "$stem"); [ "$route" = . ] && route='' ;;
    *) route=$stem ;;
  esac
  [ -z "$route" ] || route="$route/"
  printf '%s\n' "$route"
}

urlencode_route() {  # <python> <route>
  "$1" -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$2"
}

cmd_url() {
  local start=1 given fragment='' route base_url python encoded url code
  if [ "${1:-}" = --no-start ]; then
    start=0
    shift
  fi
  given=${1:-}
  [ -n "$given" ] || die 'url needs a Markdown path'
  case "$given" in
    *'#'*) fragment=${given#*#}; given=${given%%#*} ;;
  esac
  route=$(route_for "$given") || exit 1
  if [ "$start" -eq 1 ]; then
    base_url=$(ensure_url) || exit 1
  else
    base_url=$(verified_url) || die 'reader not running (use ensure)'
  fi
  python=$(record_get python)
  [ -n "$python" ] && [ -x "$python" ] || python=$(resolve_python) || die 'reader runtime missing'
  encoded=$(urlencode_route "$python" "$route") || die 'could not encode the route'
  url="${base_url}${encoded}"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$FM_DOCS_READER_HTTP_SECS" "$url" 2>/dev/null || true)
  [ "$code" = 200 ] || die "page not served (HTTP ${code:-none}): $url"
  [ -z "$fragment" ] || url="$url#$fragment"
  printf '%s\n' "$url"
}

cmd_python() {
  local python
  python=$(resolve_python) || die 'no reader runtime found (run install)'
  printf '%s\n' "$python"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  ensure) cmd_ensure ;;
  status) cmd_status ;;
  url) shift; cmd_url "$@" ;;
  stop) cmd_stop ;;
  python) cmd_python ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command: $1 (see --help)" ;;
esac
