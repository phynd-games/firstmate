#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-supervisor-review)
trap fm_test_cleanup EXIT
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected $2, got $1"; }

setup() {
  export FM_HOME="$TMP_ROOT/$1" FM_ROOT_OVERRIDE="$ROOT"
  export FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
  mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
  set --
  . "$ROOT/bin/fm-herdr-supervisor.sh" >/dev/null 2>&1 || true
  supervisor_eligible() { return 0; }
  hs_config_preference() { printf on; }
  fm_supervision_claim_pending_reclaim() { return 0; }
  fm_supervision_claim_pending_expired_live() { return 1; }
  harness_owner_provable() { return 1; }
  fm_supervision_needed() { return 0; }
  herdr_identity() { HS_SESSION=lab-review; HS_SOCKET="$STATE/socket"; HS_SOCKET_IDENTITY=12:34; }
  supervisor_label() { printf review; }
  supervisor_healthy() { [ "$(record_get workspace || true)" = workspace-review ]; }
  live_get() { printf '%s' "$$"; }
  hs_herdr() {
    printf '%s\n' "$*" >> "$STATE/native-calls"
    case "$*" in
      *'workspace create'*) cat "$STATE/create-response" ;;
      *'pane run'*) return 0 ;;
      *) return 1 ;;
    esac
  }
  printf '%s\n' '{"result":{"workspace":{"workspace_id":"workspace-review"},"tab":{"tab_id":"tab-review"},"root_pane":{"pane_id":"pane-review"},"terminal":{"terminal_id":"terminal-review"}}}' > "$STATE/create-response"
}

(
  setup complete
  cmd_ensure review > "$STATE/ensure-output" 2>&1 || fail "successful supervisor establish failed: $(cat "$STATE/ensure-output")"
  assert_grep 'herdr-supervisor: started' "$STATE/ensure-output" 'supervisor did not enter establish'
  assert_eq "$(record_get terminal_id)" terminal-review 'binding retains native terminal ID'
  assert_eq "$(fm_launch_record get --helper herdr-supervisor launch.identity.terminal_id)" terminal-review 'projection retains native terminal ID'
  pass 'R15: native terminal identity survives establish and projection'
) || exit 1

(
  setup incomplete
  printf '%s\n' '{"result":{"workspace":{"workspace_id":"partial-review"},"terminal":{"terminal_id":"partial-terminal"}}}' > "$STATE/create-response"
  cmd_ensure review >/dev/null 2>&1 && fail 'incomplete supervisor create succeeded'
  before=$(fm_launch_record get --helper herdr-supervisor launch.id)
  cmd_ensure retry >/dev/null 2>&1 && fail 'incomplete create permitted replacement'
  cmd_retire review >/dev/null 2>&1 && fail 'incomplete create permitted unproved retirement'
  assert_eq "$(fm_launch_record get --helper herdr-supervisor launch.id)" "$before" 'uncertain attempt remains current'
  assert_eq "$(pending_get workspace)" partial-review 'pending partial workspace is retained'
  assert_eq "$(pending_get terminal_id)" partial-terminal 'pending partial terminal is retained'
  assert_eq "$(fm_launch_record get --helper herdr-supervisor launch.identity.terminal_id)" partial-terminal 'partial terminal is projected'
  assert_eq "$(wc -l < "$STATE/native-calls" | tr -d ' ')" 1 'only one native create request issued'
  fm_launch_record reconcile --helper herdr-supervisor --launch "$before" --verdict manual --evidence 'fixture inspected and disposed' >/dev/null || fail 'manual settlement failed'
  reconcile_pending_locked || fail 'pending owner did not consume matching manual settlement'
  [ ! -f "$PENDING" ] || fail 'manually settled pending receipt remains blocking'
  pass 'R3/R15: incomplete creation blocks ensure and retire until inspected settlement'
) || exit 1

(
  setup unhealthy
  cmd_ensure review >/dev/null || fail 'setup establish failed'
  before=$(fm_launch_record get --helper herdr-supervisor launch.id)
  supervisor_healthy() { return 1; }
  recorded_herdr_identity_matches() { return 1; }
  cmd_ensure retry >/dev/null 2>&1 && fail 'unproved prior server permitted replacement'
  cmd_ensure retry-again >/dev/null 2>&1 && fail 'quarantine permitted replacement on second retry'
  assert_eq "$(fm_launch_record get --helper herdr-supervisor launch.id)" "$before" 'old attempt retained'
  assert_eq "$(fm_launch_record get --helper herdr-supervisor launch.phase)" ready 'unproved stop was not projected'
  [ -f "$RECORD" ] || fail 'unresolved binding was archived out of authority'
  assert_eq "$(wc -l < "$STATE/native-calls" | tr -d ' ')" 2 'retry did not issue create or pane run'
  pass 'R3: unsuccessful prior cleanup preserves the binding and launch obligation'
) || exit 1

for scenario in missing-python persistence ambiguous live; do
  (
    setup "monitor-$scenario"
    printf '%s\n' "$$" > "$STATE/.lock"
    setsid() { printf detached > "$STATE/detached"; }
    case "$scenario" in
      missing-python) FM_LAUNCH_RECORD_PYTHON="$STATE/missing-python" ;;
      persistence) mkdir -p "$STATE/.launch-herdr-supervisor-monitor" ;;
      ambiguous|live)
        hs_monitor_launch_intend || fail 'could not seed monitor attempt'
        before=$HS_MONITOR_LAUNCH_ID
        if [ "$scenario" = live ]; then
          hs_monitor_launch_created "$$" "$(fm_pid_identity "$$")" || fail 'could not seed live monitor identity'
        fi
        ;;
    esac
    cmd_monitor review >/dev/null 2>&1 && fail "$scenario monitor launch did not refuse"
    [ ! -e "$STATE/detached" ] || fail "$scenario detached a monitor without authority"
    if [ "$scenario" = ambiguous ] || [ "$scenario" = live ]; then
      assert_eq "$(fm_launch_record get --helper herdr-supervisor-monitor launch.id)" "$before" 'predecessor remains current'
    fi
    pass "R7: $scenario monitor attempt refuses detachment"
  ) || exit 1
done

(
  setup monitor-child
  printf '%s\n' "$$" > "$STATE/.lock"
  owner=$(session_owner_identity)
  hs_monitor_launch_intend || fail 'could not prepare monitor child intent'
  before=$HS_MONITOR_LAUNCH_ID
  harness_owner_provable() { HS_DEFER_REASON=fixture-complete; return 0; }
  cmd_monitor_run "$owner" || fail 'monitor child failed its owned lifecycle'
  assert_eq "$(fm_launch_record get --helper herdr-supervisor-monitor launch.id)" "$before" 'monitor child retains its launch ID'
  assert_eq "$(fm_launch_record get --helper herdr-supervisor-monitor launch.phase)" exited 'monitor child records its own exit'
  fm_launch_record show --helper herdr-supervisor-monitor --json | jq -e \
    '.launch.identity.pid != null and [.launch.history[].event] == ["intended", "created", "exited"]' >/dev/null \
    || fail 'monitor child did not publish native identity before entering its loop'
  [ ! -e "$MONITOR" ] || fail 'monitor child retained operational ownership after stand-down'
  pass 'R7: monitor child publishes its own identity and settles only its attempt'
) || exit 1

echo 'all supervisor launch review tests passed'
