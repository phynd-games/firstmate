#!/usr/bin/env bash
# tests/secondmate-helpers.sh - shared fixtures and mocks for the secondmate
# suites (fm-secondmate-lifecycle-e2e and fm-secondmate-safety).
#
# These mocks encode secondmate-lifecycle behavior (fake tmux that logs window
# ops, fake treehouse that leases/returns homes, fake no-mistakes that records
# init/doctor), so they live here rather than in the generic tests/lib.sh. The
# generic git/identity/meta primitives come from lib.sh, which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake tmux (window ops are logged to FM_FAKE_TMUX_LOG, list-windows returns
# FM_FAKE_TMUX_WINDOW, capture-pane echoes FM_FAKE_TMUX_CAPTURE) plus a fake
# treehouse (durable lease of FM_FAKE_TREEHOUSE_HOME, recording the lease holder
# to FM_FAKE_TREEHOUSE_LEASE_FILE; `return` removes the target and lease unless
# FM_FAKE_TREEHOUSE_RETURN_FAIL is set). Echoes the fakebin dir.
make_fake_tmux() {
  local dir=$1 fakebin capture
  fakebin=$(fm_fakebin "$dir")
  capture="$dir/pane.txt"
  # A real, positively identified empty agent composer. A blank capture is
  # deliberately unknown under the fleet-wide strict blank-row posture.
  printf '❯\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys|kill-window)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  list-windows)
    if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    fi
    exit 0
    ;;
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '0\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  get)
    # Durable lease: print only the worktree path to stdout (banners to stderr),
    # and record the lease holder so tests can assert it is set and later cleared.
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ -n "${FM_FAKE_TREEHOUSE_HOME:-}" ]; then
      mkdir -p "$FM_FAKE_TREEHOUSE_HOME"
      [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && printf '%s\n' "$holder" > "$FM_FAKE_TREEHOUSE_LEASE_FILE"
      printf 'leased worktree for %s\n' "${holder:-unknown}" >&2
      printf '%s\n' "$FM_FAKE_TREEHOUSE_HOME"
    fi
    exit 0
    ;;
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && rm -f "$FM_FAKE_TREEHOUSE_LEASE_FILE"
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  chmod +x "$fakebin/treehouse"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

# A deterministic Herdr fixture for backend-neutral secondmate behavior. It
# models only the public calls needed by spawn/send/teardown and keeps all
# endpoint identity in a JSON state file.
make_fake_herdr() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '{"next":1,"workspaces":[],"tabs":[],"synthetic_closed":false}' > "$dir/herdr-state.json"
  : > "$dir/herdr.log"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:-$(cd "$(dirname "$0")/.." && pwd)/herdr-state.json}
log=${FM_FAKE_HERDR_LOG:-${FM_FAKE_TMUX_LOG:-$(cd "$(dirname "$0")/.." && pwd)/herdr.log}}
printf '%s\n' "$*" >> "$log"
save() { local tmp="$state.tmp.$$"; cat > "$tmp" && mv "$tmp" "$state"; }
cmd=${1:-}; sub=${2:-}
ws= label= pane= tab=
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done
case "$cmd $sub" in
  "status --json") printf '%s\n' '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true,"status":"running","compatible":true,"protocol":14}}' ;;
  "session list") printf '{"sessions":[{"name":"%s","running":true,"socket_path":"/tmp/fm-fake-herdr.sock"}]}\n' "${HERDR_SESSION:-default}" ;;
  "workspace list")
    if [ "${FM_FAKE_HERDR_SYNTHETIC_ENDPOINT:-0}" = 1 ] \
      && [ "$(jq '.workspaces | length' "$state")" = 0 ] \
      && [ "$(jq -r '.synthetic_closed // false' "$state")" != true ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"fixture","focused":true,"active_tab_id":"w1:t1"}]}}'
    else
      jq '{result:{workspaces:.workspaces}}' "$state"
    fi
    ;;
  "workspace create")
    n=$(jq -r '.next' "$state"); wsid="w$n"; tabid="$wsid:t$((n+1))"; paneid="$wsid:p$((n+1))"
    jq --arg w "$wsid" --arg l "$label" --arg t "$tabid" --arg p "$paneid" \
      '(.workspaces |= map(.focused = false))
       | (.tabs |= map(.focused = false))
       | (.workspaces += [{workspace_id:$w,label:$l,focused:true,active_tab_id:$t}])
       | .tabs += [{tab_id:$t,workspace_id:$w,pane_id:$p,label:"1",focused:true}]
       | .next += 2' "$state" | save
    printf '{"result":{"workspace":{"workspace_id":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$wsid" "$tabid" "$paneid" ;;
  "tab list")
    if [ "${FM_FAKE_HERDR_SYNTHETIC_ENDPOINT:-0}" = 1 ] \
      && [ "$ws" = w1 ] && [ "$(jq '.tabs | length' "$state")" = 0 ] \
      && [ "$(jq -r '.synthetic_closed // false' "$state")" != true ]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","pane_id":"w1:p1","label":"1","focused":true},{"tab_id":"w1:t2","workspace_id":"w1","pane_id":"w1:p2","label":"2","focused":false},{"tab_id":"w1:t3","workspace_id":"w1","pane_id":"w1:p3","label":"3","focused":false}]}}'
    else
      jq --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' "$state"
    fi
    ;;
  "pane list")
    if [ "${FM_FAKE_HERDR_SYNTHETIC_ENDPOINT:-0}" = 1 ] \
      && [ "$ws" = w1 ] && [ "$(jq '.tabs | length' "$state")" = 0 ] \
      && [ "$(jq -r '.synthetic_closed // false' "$state")" != true ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}'
    else
      jq --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id,tab_id:.tab_id}]}}' "$state"
    fi
    ;;
  "tab create")
    n=$(jq -r '.next' "$state"); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq --arg w "$ws" --arg t "$tabid" --arg p "$paneid" --arg l "$label" \
      '([.tabs[] | select(.workspace_id == $w and .focused == true)] | length) as $focused
       | .tabs += [{tab_id:$t,workspace_id:$w,pane_id:$p,label:$l,focused:($focused == 0)}]
       | if $focused == 0 then .workspaces |= map(if .workspace_id == $w then .focused = true | .active_tab_id = $t else . end) else . end
       | .next += 1' "$state" | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid" ;;
  "pane get")
    pane=${3:-}
    if jq -e --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length == 0' "$state" >/dev/null; then
      if [ "$(jq -r '.synthetic_closed // false' "$state")" != true ] \
        && [ "$(jq -r --arg p "$pane" '((.closed_panes // []) | index($p)) == null' "$state")" = true ] \
        && [[ "$pane" =~ ^w1:p[0-9]+$ ]]; then
        tab=${pane#*:}
        printf '%s\n' '{"result":{"pane":{"pane_id":"'"$pane"'","tab_id":"w1:t'"${tab#p}"'","workspace_id":"w1","foreground_cwd":"'"${FM_FAKE_PANE_PATH:-/tmp}"'"}}}'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      fi
    else
      jq --arg p "$pane" --arg cwd "${FM_FAKE_PANE_PATH:-/tmp}" '([.tabs[]|select(.pane_id==$p)][0]) as $t | {result:{pane:{pane_id:$t.pane_id,tab_id:$t.tab_id,workspace_id:$t.workspace_id,foreground_cwd:$cwd}}}' "$state"
    fi ;;
  "pane close") pane=${3:-}; jq --arg p "$pane" --argjson synthetic "${FM_FAKE_HERDR_SYNTHETIC_ENDPOINT:-0}" '
    ([.tabs[] | select(.pane_id == $p)][0]) as $removed
    | (if $synthetic == 1 then .closed_panes = (((.closed_panes // []) + [$p]) | unique)
       elif $p | test("^w1:p[0-9]+$") then .synthetic_closed = true else . end)
    | (.tabs |= [.[] | select(.pane_id != $p)])
    | if ($removed.focused // false) then
        ([.tabs[] | select(.workspace_id == $removed.workspace_id)][0]) as $next
        | (.tabs |= map(if .workspace_id == $removed.workspace_id then .focused = (.tab_id == ($next.tab_id // "")) else . end))
        | (.workspaces |= map(if .workspace_id == $removed.workspace_id then .active_tab_id = ($next.tab_id // "") else . end))
      else . end
  ' "$state" | save ;;
  "tab close") tab=${3:-}; jq --arg t "$tab" '.tabs |= [.[]|select(.tab_id != $t)]' "$state" | save ;;
  "workspace close") ws=${3:-}; jq --arg w "$ws" '.workspaces |= [.[]|select(.workspace_id != $w)] | .tabs |= [.[]|select(.workspace_id != $w)]' "$state" | save ;;
  "agent get")
    pane=${3:-}
    if [[ "$pane" =~ ^w1:p[0-9]+$ ]]; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    fi
    ;;
  "pane read")
    if [ -n "${FM_FAKE_HERDR_CAPTURE:-}" ] && [ -f "$FM_FAKE_HERDR_CAPTURE" ]; then
      cat "$FM_FAKE_HERDR_CAPTURE"
    else
      printf '❯\n'
    fi
    ;;
  "pane send-text")
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      printf '%s\n' "${4:-}" >> "$FM_FAKE_LAUNCH_LOG"
    fi
    ;;
  "pane run"|"pane send-keys") : ;;
  *) : ;;
esac
SH
  chmod +x "$fakebin/herdr"
cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_HERDR_LOG:-${FM_FAKE_TMUX_LOG:-/dev/null}}"
case "${1:-}" in
  get)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'Usage: treehouse get [--lease]'
      exit 0
    fi
    holder=
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ -n "${FM_FAKE_TREEHOUSE_HOME:-}" ]; then
      mkdir -p "$FM_FAKE_TREEHOUSE_HOME"
      [ -z "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] || printf '%s\n' "$holder" > "$FM_FAKE_TREEHOUSE_LEASE_FILE"
      printf '%s\n' "$FM_FAKE_TREEHOUSE_HOME"
    fi
    ;;
  return)
  shift
  [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
  [ -z "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] || rm -f "$FM_FAKE_TREEHOUSE_LEASE_FILE"
  rm -rf -- "${2:-}"
  ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that touches .no-mistakes-init / .no-mistakes-doctor markers.
make_fake_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that records each "<pwd>\t<verb>" call to
# FM_FAKE_NO_MISTAKES_LOG and fails for the project named FM_FAKE_NO_MISTAKES_FAIL_PROJECT.
make_recording_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NO_MISTAKES_LOG"
if [ "$(basename "$PWD")" = "${FM_FAKE_NO_MISTAKES_FAIL_PROJECT:-}" ]; then
  exit 1
fi
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# Make a directory look like a minimal firstmate home (AGENTS.md + bin/).
mark_firstmate_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
}

# A firstmate home that is also a real git repo (so it can host detached
# worktrees for teardown/lease tests).
make_firstmate_git_root() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  cat > "$home/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/bin/fm-guard.sh"
  git -C "$home" init -q
  git -C "$home" add AGENTS.md bin/fm-guard.sh
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# Scaffold a filled secondmate charter brief under <home>/data/<id>/brief.md.
# Args: home id charter [project...]
scaffold_secondmate_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  FM_HOME="$home" FM_SECONDMATE_CHARTER="$charter" "$ROOT/bin/fm-brief.sh" "$id" --secondmate "$@" >/dev/null
}

# Make a directory look like a genuine seeded secondmate home (for handoff tests).
seed_secondmate_home_marker() {
  local home=$1 id=$2
  mark_firstmate_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive. Returns 1 if it dies.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
