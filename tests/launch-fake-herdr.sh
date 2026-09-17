#!/usr/bin/env bash
# tests/launch-fake-herdr.sh - the stateful fake `herdr` CLI shared by the
# launch-record suites (fm-launch-spawn.test.sh, fm-launch-helpers.test.sh).
#
# Source this after tests/lib.sh. It provides make_fake_herdr <dir>, which
# writes <dir>/fakebin/herdr, <dir>/fakebin/treehouse (exit 0), and
# <dir>/fakebin/herdr-workspace-control (the socket helper the supervisor uses
# for workspace list/close) and echoes the fakebin directory.
#
# The fake is JSON-backed ($FM_FAKE_HERDR_STATE) and models exactly what the
# launch owners ask of Herdr: status, session list (with a socket file that
# exists, so socket identity can be read), workspace/tab/pane list, get,
# create, and close, pane run / send-text / send-keys / read / process-info, and
# agent get. Every call is logged to $FM_HERDR_LOG as
#   <argv joined by \x1f>\trecord=<present|absent>
# where record presence is whether $FM_FAKE_WATCH_RECORD exists at call time -
# the observation "intent before creation" is proved from.
#
# Fault injection and lifecycle modelling, all files beside the state:
#   $FM_FAKE_BLOCK_DIR/<cmd>-<sub>   the call blocks until the file is removed
#   $FM_FAKE_FAIL_DIR/<cmd>-<sub>    the call fails before any effect, printing
#                                    the file's contents
#   $FM_FAKE_FAIL_DIR/<cmd>-<sub>.lost  the call creates, then exits 1 with a
#                                    garbage response (a lost response)
#   $FM_FAKE_FAIL_DIR/<cmd>-<sub>.effect  the call creates, then prints the
#                                    <cmd>-<sub> file (a structured error) and
#                                    exits 1 (an error following an effect)
#   $FM_FAKE_FAIL_DIR/<cmd>-<sub>.effect-hidden  as .effect, but the created
#                                    tab carries the label "hidden-<label>"
#                                    so an immediate label inventory finds
#                                    nothing (an effect the lookup cannot see)
#   <fake-dir>/ps-table              rows `pid ppid [stat]` the fake `ps`
#                                    (fakebin/fakeps, for FM_HERDR_PS_BIN)
#                                    answers with; default: the idle shell
#                                    40001 under pid 1, sleeping
#   <fake-dir>/agent-on-enter        the next Enter that follows a launch
#                                    command registers an agent with that
#                                    status on the pane (one-shot)
#   send-text /exit or /quit         ends the pane's agent
#   pane run "exec bash ..."         is executed for real in the background and
#                                    its pid becomes the pane's tracked
#                                    shell_pid (the supervisor loop model)
#   <fake-dir>/busy-<pane>           pane process-info reports a foreground
#                                    command owning the foreground group (a
#                                    launch in progress); absent = an idle shell
#   <fake-dir>/helper-<pane>         the shell keeps the foreground group but a
#                                    helper process stays beside it (a prompt
#                                    hook that never settles)
#   FM_FAKE_WORKTREE                 pane run "treehouse get" moves the pane's
#                                    cwd there

make_fake_herdr() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/fakeps" <<'SH'
#!/usr/bin/env bash
# The process table the adapter's strict idle-shell proof consults, modelled
# from <fake-dir>/ps-table (pid ppid [stat] per row).
STATE="${FM_FAKE_HERDR_STATE:?}"
FAKE_DIR=$(dirname "$STATE")
table() {
  if [ -f "$FAKE_DIR/ps-table" ]; then cat "$FAKE_DIR/ps-table"; else printf '40001 1 S\n'; fi
}
case "$*" in
  "-axo pid=,ppid=") table | awk '{ printf "%s %s\n", $1, $2 }' ;;
  "-p "*" -o stat=") pid=$2; table | awk -v p="$pid" '$1 == p { print ($3 == "" ? "S" : $3) }' ;;
  "-o pgid= -p "*) pid=$4; table | awk -v p="$pid" '$1 == p { print p }' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/fakeps"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_HERDR_STATE:?}"
LOG="${FM_HERDR_LOG:?}"
FAKE_DIR=$(dirname "$STATE")
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  unset 'args[n-1]' 'args[n-2]'
fi
set -- "${args[@]:-}"
rec=absent
[ -z "${FM_FAKE_WATCH_RECORD:-}" ] || { [ -e "$FM_FAKE_WATCH_RECORD" ] && rec=present; }
{ for a in "$@"; do printf '%s\x1f' "$a"; done; printf '\trecord=%s\tlaunch=%s\n' "$rec" "${FM_BACKEND_HERDR_CREATE_LAUNCH_ID:-none}"; } >> "$LOG"
cmd=${1:-}; sub=${2:-}
key="$cmd-$sub"
if [ -n "${FM_FAKE_BLOCK_DIR:-}" ] && [ -e "$FM_FAKE_BLOCK_DIR/$key" ]; then
  while [ -e "$FM_FAKE_BLOCK_DIR/$key" ]; do sleep 0.05; done
fi
if [ -n "${FM_FAKE_FAIL_DIR:-}" ] && [ -e "$FM_FAKE_FAIL_DIR/$key" ] && [ ! -e "$FM_FAKE_FAIL_DIR/$key.lost" ] && [ ! -e "$FM_FAKE_FAIL_DIR/$key.effect" ] && [ ! -e "$FM_FAKE_FAIL_DIR/$key.effect-hidden" ]; then
  cat "$FM_FAKE_FAIL_DIR/$key"
  exit 1
fi
jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
remove_pane() {  # <pane> - drop the pane's tab and keep one focused tab per workspace
  jq_state --arg p "$1" '
    ([.tabs[] | select(.pane_id == $p)][0]) as $removed
    | (.tabs |= [.[] | select(.pane_id != $p)])
    | (.agent_status |= del(.[$p]))
    | if ($removed.focused // false) then
        ([.tabs[] | select(.workspace_id == $removed.workspace_id)][0]) as $next
        | (.tabs |= map(if .workspace_id == $removed.workspace_id then .focused = (.tab_id == ($next.tab_id // "")) else . end))
        | (.workspaces |= map(if .workspace_id == $removed.workspace_id then .active_tab_id = ($next.tab_id // "") else . end))
      else . end' | save
}
ws=""; label=""; cwd=""; pane_opt=""
for ((i=0; i<$#; i++)); do
  a=${args[$i]:-}
  case "$a" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --pane) pane_opt=${args[$((i+1))]:-} ;;
  esac
done
session=${HERDR_SESSION:-default}
sock="$FAKE_DIR/$session.sock"
[ -e "$sock" ] || : > "$sock"
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"status":"running","compatible":true,"protocol":20,"version":"0.8.2"}}\n' ;;
  "session list")
    printf '{"sessions":[{"name":"%s","default":%s,"running":true,"socket_path":"%s"}]}\n' "$session" "$([ "$session" = default ] && echo true || echo false)" "$sock" ;;
  "workspace list")
    jq_state '{result:{type:"workspace_list",workspaces:.workspaces}}' ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" --arg cwd "$cwd" \
      '(.workspaces |= map(.focused = false))
       | (.workspaces += [{workspace_id:$wsid, label:$wlabel, focused:true, active_tab_id:$tabid}])
       | (.tabs |= map(.focused = false))
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid, focused:true, cwd:$cwd}]
       | .next = (.next + 2)' | save
    if [ -n "${FM_FAKE_FAIL_DIR:-}" ] && [ -e "$FM_FAKE_FAIL_DIR/$key.lost" ]; then
      if [ -f "$FM_FAKE_FAIL_DIR/$key" ]; then cat "$FM_FAKE_FAIL_DIR/$key"; else printf 'connection reset while reading response\n'; fi
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s","workspace_id":"%s"},"root_pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s","terminal_id":"term_%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid" "$wsid:p$dn" "$wsid:t$dn" "$wsid" "$wsid:p$dn" ;;
  "workspace close")
    wsid=${3:-}
    jq_state --arg w "$wsid" '.workspaces |= [.[] | select(.workspace_id != $w)] | .tabs |= [.[] | select(.workspace_id != $w)]' | save
    printf '{"result":{}}\n' ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select($w == "" or .workspace_id==$w)|{tab_id,label,workspace_id,pane_id,focused}]}}' ;;
  "tab get")
    tab=${3:-}
    jq_state --arg t "$tab" '([.tabs[]|select(.tab_id==$t)][0]) as $tab | if $tab == null then {error:{code:"tab_not_found",message:"no tab"}} else {result:{tab:{tab_id:$tab.tab_id,workspace_id:$tab.workspace_id,label:$tab.label}}} end' ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" --arg cwd "$cwd" \
      '([.tabs[] | select(.workspace_id == $w and .focused == true)] | length) as $focused
       | .tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, focused:($focused == 0), cwd:$cwd}]
       | .next = (.next + 1)' | save
    if [ -n "${FM_FAKE_FAIL_DIR:-}" ] && [ -e "$FM_FAKE_FAIL_DIR/$key.lost" ]; then
      printf 'connection reset while reading response\n'
      exit 1
    fi
    if [ -n "${FM_FAKE_FAIL_DIR:-}" ] && [ -e "$FM_FAKE_FAIL_DIR/$key.effect" ]; then
      # The tab exists, and Herdr still answers a structured error.
      cat "$FM_FAKE_FAIL_DIR/$key"
      exit 1
    fi
    if [ -n "${FM_FAKE_FAIL_DIR:-}" ] && [ -e "$FM_FAKE_FAIL_DIR/$key.effect-hidden" ]; then
      # The tab exists under a label the inventory will not match.
      jq_state --arg t "$tabid" '.tabs |= map(if .tab_id == $t then .label = ("hidden-" + .label) else . end)' | save
      cat "$FM_FAKE_FAIL_DIR/$key"
      exit 1
    fi
    printf '{"result":{"tab":{"tab_id":"%s","workspace_id":"%s"},"root_pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s","terminal_id":"term_%s"}}}\n' "$tabid" "$ws" "$paneid" "$tabid" "$ws" "$paneid" ;;
  "tab focus")
    jq_state --arg t "${3:-}" '([.tabs[] | select(.tab_id == $t)][0].workspace_id) as $w
      | .workspaces |= map(.focused = (.workspace_id == $w))
      | .tabs |= map(if .workspace_id == $w then .focused = (.tab_id == $t) else . end)
      | .workspaces |= map(if .workspace_id == $w then .active_tab_id = $t else . end)' | save
    printf '{"result":{}}\n' ;;
  "tab close")
    pane=$(jq_state -r --arg t "${3:-}" '[.tabs[]|select(.tab_id==$t)][0].pane_id // empty')
    [ -z "$pane" ] || remove_pane "$pane"
    printf '{"result":{}}\n' ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id, workspace_id:.workspace_id, terminal_id:("term_"+.pane_id)}]}}' ;;
  "pane get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length')" = 0 ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$pane"
      exit 1
    fi
    jq_state --arg p "$pane" '([.tabs[] | select(.pane_id == $p)][0]) as $tab
      | {result:{pane:{pane_id:$tab.pane_id,tab_id:$tab.tab_id,workspace_id:$tab.workspace_id,terminal_id:("term_" + $tab.pane_id),foreground_cwd:$tab.cwd}}}' ;;
  "pane process-info")
    pane=${pane_opt:-${3:-}}
    pid=$(cat "$FAKE_DIR/loop-pid" 2>/dev/null || echo 40001)
    if [ -e "$FAKE_DIR/helper-$pane" ]; then
      # The shell keeps the foreground group but a helper process sits beside
      # it for as long as the marker exists (the real 0.8.2 lab shows this
      # transiently for a prompt hook; persistently it must read busy once the
      # settle window is spent).
      jq_state --arg p "$pane" --argjson pid "$pid" '([.tabs[] | select(.pane_id == $p)][0]) as $tab
        | {result:{type:"pane_process_info",process_info:{pane_id:$tab.pane_id,tab_id:$tab.tab_id,workspace_id:$tab.workspace_id,shell_pid:$pid,foreground_process_group_id:$pid,foreground_processes:[{pid:($pid + 2),name:"python3.13",argv0:"python"},{pid:$pid,name:"zsh",argv0:"-zsh"}]}}}'
    elif [ -e "$FAKE_DIR/busy-$pane" ]; then
      # A foreground command is running in the pane (a harness that has not
      # registered as an agent looks exactly like this to a launch owner).
      jq_state --arg p "$pane" --argjson pid "$pid" '([.tabs[] | select(.pane_id == $p)][0]) as $tab
        | {result:{type:"pane_process_info",process_info:{pane_id:$tab.pane_id,tab_id:$tab.tab_id,workspace_id:$tab.workspace_id,shell_pid:$pid,foreground_process_group_id:($pid + 1),foreground_processes:[{pid:$pid,name:"zsh",argv0:"-zsh"},{pid:($pid + 1),name:"sleep",argv0:"sleep"}]}}}'
    else
      jq_state --arg p "$pane" --argjson pid "$pid" '([.tabs[] | select(.pane_id == $p)][0]) as $tab
        | {result:{type:"pane_process_info",process_info:{pane_id:$tab.pane_id,tab_id:$tab.tab_id,workspace_id:$tab.workspace_id,shell_pid:$pid,foreground_process_group_id:$pid,foreground_processes:[{pid:$pid,name:"zsh",argv0:"-zsh"}]}}}'
    fi ;;
  "pane run")
    pane=${3:-}; text=${4:-}
    case "$text" in
      "treehouse get"*) jq_state --arg p "$pane" --arg c "${FM_FAKE_WORKTREE:-}" '.tabs |= map(if .pane_id == $p then .cwd = $c else . end)' | save ;;
      "exec bash "*)
        # The supervisor loop model: run the launcher for real, detached, and
        # let the pane track its pid.
        bash -c "$text" >>"$FAKE_DIR/loop.out" 2>&1 &
        printf '%s\n' "$!" > "$FAKE_DIR/loop-pid"
        ;;
    esac
    printf '%s\n' "$text" >> "$FAKE_DIR/typed.log"
    printf '{"result":{"sent":true}}\n' ;;
  "pane send-text")
    printf '%s\n' "${4:-}" >> "$FAKE_DIR/typed.log"
    case "${4:-}" in
      /exit|/quit) jq_state --arg p "${3:-}" '.agent_status |= del(.[$p])' | save; printf 'exit' > "$FAKE_DIR/last-text" ;;
      *) printf 'launch' > "$FAKE_DIR/last-text" ;;
    esac
    printf '{"result":{"sent":true}}\n' ;;
  "pane send-keys")
    printf 'KEY:%s\n' "${4:-}" >> "$FAKE_DIR/typed.log"
    if [ -f "$FAKE_DIR/agent-on-enter" ] && [ "${4:-}" = enter ] && [ "$(cat "$FAKE_DIR/last-text" 2>/dev/null)" != exit ]; then
      jq_state --arg p "${3:-}" --arg s "$(cat "$FAKE_DIR/agent-on-enter")" '.agent_status[$p] = $s' | save
      rm -f "$FAKE_DIR/agent-on-enter"
    fi
    printf '{"result":{"sent":true}}\n' ;;
  "pane read")
    if [ -f "$FAKE_DIR/pane-text" ]; then cat "$FAKE_DIR/pane-text"; else printf '\n\n❯ \n'; fi ;;
  "pane close")
    remove_pane "${3:-}"
    printf '{"result":{}}\n' ;;
  "agent get")
    pane=${3:-}
    status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      jq_state --arg p "$pane" --arg status "$status" '([.tabs[] | select(.pane_id == $p)][0]) as $tab
        | {result:{agent:{agent_status:$status,pane_id:$p,workspace_id:$tab.workspace_id,tab_id:$tab.tab_id,agent:"fake"}}}'
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
      exit 1
    fi ;;
  *)
    printf '{"error":{"code":"unsupported_by_fake","message":"%s %s"}}\n' "$cmd" "$sub"
    exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  # The socket helper the supervisor uses for workspace list/close over the
  # verified socket: <socket> <identity> <operation> [workspace].
  cat > "$fb/herdr-workspace-control" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_HERDR_STATE:?}"
operation=${3:-}
workspace=${4:-}
case "$operation" in
  list)
    jq '{id:"fm-workspace-control",result:{workspaces:[.workspaces[] | {workspace_id,label}]}}' "$STATE"
    ;;
  close)
    tmp="$STATE.tmp.$$"
    jq --arg w "$workspace" '.workspaces |= [.[] | select(.workspace_id != $w)] | .tabs |= [.[] | select(.workspace_id != $w)]' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
    printf '{"id":"fm-workspace-control","result":{"closed":true}}\n'
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fb/herdr-workspace-control"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  chmod +x "$fb/treehouse"
  printf '%s\n' "$fb"
}
