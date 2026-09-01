#!/usr/bin/env bash
# fm-handoff-confirm.sh - the ONE executable owner of confirmed worker handoff.
#
# THE RULE THIS ENFORCES. A queued steering record is not delivery, and a
# doorbell that reached a terminal is not delivery either. An actionable
# instruction is handed off only when BOTH of these are proven:
#   1. ACKNOWLEDGEMENT - the worker moved THAT EXACT inbox record into
#      handled/, identified by sequence and by the record's own bytes, so a
#      different record, a replayed record, or a rewritten one cannot pass; and
#   2. START - the work that instruction asked for is observably under way on
#      the same task, run, and finding set, read through bin/fm-crew-state.sh,
#      which owns run attribution against the task's branch and current code
#      identity.
# Until both hold, no caller may report the instruction dispatched, end its
# handling turn, or relay the same parked finding again.
#
# Why an executable owns this rather than a supervision prompt: "did the worker
# take it" is a question about durable records and process state, both of which
# a script reads exactly. There is no polling agent here and none is wanted -
# `confirm` blocks deterministically for a bounded time and returns a verdict.
#
# AUTHORITY BOUNDARY. This script invents none. It composes:
#   bin/fm-task-inbox-lib.sh   record identity, handled/ acknowledgement, the ring
#   bin/fm-crew-state.sh       current state, run attribution, gate findings
#   bin/fm-wake-lib.sh         the durable wake that carries a failure
#   stuck-crewmate-recovery    the playbook a failure routes to
# It never claims a lease, never steers on its own beyond ONE re-ring of the
# exact record it is confirming, and never tears anything down.
#
# Usage:
#   fm-handoff-confirm.sh register --task <id> --record <path>
#       [--kind steer|finding-response] [--expect-state-change]
#       [--expect-head <sha>] [--expect-gate <name>] [--expect-findings <n>]
#     Record the obligation and the pre-handoff baseline, then print the exact
#     confirm command. --kind finding-response implies --expect-state-change:
#     answering a gate that leaves the run parked at the same gate with the same
#     findings is the defining "acknowledged but never started" failure.
#     An --expect-* value that does not match what is actually true right now is
#     refused (exit 4) BEFORE the obligation exists, so a decision aimed at the
#     wrong head, gate, or finding set fails at the boundary instead of being
#     confirmed against the wrong work.
#
#   fm-handoff-confirm.sh confirm --task <id> --record <path>
#       [--timeout <secs>] [--poll <secs>] [--no-rering]
#     Wait up to --timeout for the acknowledgement, then prove the start. A
#     first window that expires without acknowledgement re-rings the exact
#     record ONCE and waits one further window. A worker whose endpoint is
#     already gone fails immediately rather than burning the window.
#     Exit 0 = acknowledged AND started; both proven, and the obligation closes.
#     Exit 3 = not proven. A `stale` wake naming the task and the exact reason
#     is queued first, so the failure reaches supervision as recovery work
#     rather than as this command's exit status alone.
#
#   fm-handoff-confirm.sh list [--task <id>]
#     Print every OPEN obligation: "<task> <record> <kind> <age-secs> <reason>".
#     An open obligation is an instruction nobody has proven was taken up.
#
#   fm-handoff-confirm.sh status --task <id> --record <path>
#     Print one line for a single obligation and exit 0 confirmed, 3 open.
#
# Records, under $STATE/<task>.handoff/:
#   <seq>.expect   the obligation: schema, task, record basename, record digest,
#                  kind, registered_at, the baseline crew-state signature, and
#                  each --expect-* value that was validated at register time.
#   <seq>.result   confirmed|failed written once confirm reaches a verdict.
# Both are plain key=value. A missing .result IS an open obligation, so a crash
# between register and confirm leaves the obligation open rather than silently
# satisfied.
#
# Exit codes: 0 ok, 1 internal failure, 2 usage, 3 unconfirmed, 4 expectation
# mismatch at register time.
#
# Tunables (env): FM_HANDOFF_TIMEOUT (default 90), FM_HANDOFF_POLL (default 2).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

HANDOFF_SCHEMA='fm-handoff.v1'
TIMEOUT_DEFAULT=${FM_HANDOFF_TIMEOUT:-90}
POLL_DEFAULT=${FM_HANDOFF_POLL:-2}

usage() {
  echo "usage: fm-handoff-confirm.sh register --task <id> --record <path> [--kind steer|finding-response] [--expect-state-change] [--expect-head <sha>] [--expect-gate <name>] [--expect-findings <n>] | confirm --task <id> --record <path> [--timeout <s>] [--poll <s>] [--no-rering] | list [--task <id>] | status --task <id> --record <path>" >&2
  exit 2
}

die() { echo "fm-handoff-confirm: $1" >&2; exit "${2:-1}"; }

handoff_dir() {  # <task>
  printf '%s/%s.handoff\n' "$STATE" "$1"
}

# One field per line, no interior newlines: the obligation must stay a stable
# key=value record that grep and sed read the same way every time.
clean_field() {
  printf '%s' "$1" | tr '\n\t' '  ' | tr -d '\000-\010\013\014\016-\037'
}

record_digest() {  # <record-path>
  # The digest binds the obligation to the record's exact bytes, so a record
  # rewritten in place after registration can never satisfy it.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    # No digest tool: fall back to size+mtime, which still detects a rewrite.
    printf 'sizemtime-%s-%s' \
      "$(wc -c < "$1" 2>/dev/null | tr -d ' ')" "$(fm_path_mtime "$1" 2>/dev/null || echo 0)"
  fi
}

crew_state_line() {  # <task> -> the full deterministic current-state line
  "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null || printf 'state: unknown · source: none · crew-state read failed'
}

state_token() {  # <crew-state-line>
  printf '%s' "$1" | sed -n 's/^state: \([a-z-]*\).*/\1/p'
}

# The signature is what "unchanged" means. It is deliberately the WHOLE line:
# a run that stays parked at the same gate with the same finding count has not
# started the work, however many seconds have passed, while any real transition
# - a different state, a different gate, a different finding count - changes it.
state_signature() {  # <crew-state-line>
  clean_field "$1"
}

meta_of() {  # <task>
  printf '%s/%s.meta\n' "$STATE" "$1"
}

worktree_head() {  # <task>
  local wt
  wt=$(fm_meta_get "$(meta_of "$1")" worktree)
  [ -n "$wt" ] || return 1
  git -C "$wt" rev-parse HEAD 2>/dev/null
}

# Findings count and gate name as bin/fm-crew-state.sh reports them, so this
# script never parses no-mistakes output itself.
detail_gate() {  # <crew-state-line>
  printf '%s' "$1" | sed -n 's/.*parked at \([^:·]*\).*/\1/p' | sed 's/[[:space:]]*$//'
}

detail_findings() {  # <crew-state-line>
  printf '%s' "$1" | sed -n 's/.*: \([0-9][0-9]*\) finding(s).*/\1/p'
}

expect_get() {  # <expect-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

result_path() {  # <expect-file>
  printf '%s\n' "${1%.expect}.result"
}

# An endpoint that is provably gone is a failure NOW: waiting the full window
# for an acknowledgement no process can ever write is exactly the delay this
# script exists to remove.
endpoint_is_gone() {  # <crew-state-line>
  case "$1" in
    *"source: none"*) return 0 ;;
  esac
  return 1
}

emit_failure_wake() {  # <task> <reason>
  local task=$1 reason=$2
  fm_wake_append stale "$task" \
    "handoff not confirmed for $task: $reason; the instruction was never proven taken up - recover the worker before relaying it again" \
    || echo "fm-handoff-confirm: WARNING - the failure wake could not be queued for $task" >&2
}

cmd_register() {
  local task='' record='' kind=steer expect_change=0 expect_head='' expect_gate='' expect_findings=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 || usage ;;
      --record) record=${2:-}; shift 2 || usage ;;
      --kind) kind=${2:-}; shift 2 || usage ;;
      --expect-state-change) expect_change=1; shift ;;
      --expect-head) expect_head=${2:-}; shift 2 || usage ;;
      --expect-gate) expect_gate=${2:-}; shift 2 || usage ;;
      --expect-findings) expect_findings=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$task" ] && [ -n "$record" ] || usage
  case "$kind" in steer|finding-response) ;; *) usage ;; esac
  [ -f "$record" ] || die "no such steering record: $record"

  local base seq inbox dir expect line
  base=$(basename "$record")
  seq=$(fm_task_inbox_seq_of "$base") || true
  [ -n "$seq" ] || die "not a steering record name: $base" 2
  inbox=$(fm_task_inbox_dir "$STATE" "$task")
  case "$record" in
    "$inbox"/*|"$(fm_task_inbox_handled_dir "$STATE" "$task")"/*) ;;
    *) die "record $record does not belong to task $task's steering inbox" 2 ;;
  esac

  line=$(crew_state_line "$task")

  # Validate every expectation BEFORE the obligation exists. A decision aimed
  # at a head, gate, or finding set that is not the one in front of the worker
  # must fail here, not be confirmed later against whatever it did instead.
  if [ -n "$expect_head" ]; then
    local head
    head=$(worktree_head "$task" || true)
    [ -n "$head" ] || die "cannot read the task worktree HEAD to check --expect-head" 4
    [ "$head" = "$expect_head" ] \
      || die "expected head $expect_head but $task is on $head; the instruction targets different work" 4
  fi
  if [ -n "$expect_gate" ]; then
    local gate
    gate=$(detail_gate "$line")
    [ "$gate" = "$expect_gate" ] \
      || die "expected the worker parked at gate '$expect_gate' but it reads '${gate:-none}'; the instruction targets a different gate" 4
  fi
  if [ -n "$expect_findings" ]; then
    local found
    found=$(detail_findings "$line")
    [ "$found" = "$expect_findings" ] \
      || die "expected $expect_findings finding(s) at the gate but the run reports '${found:-none}'; the instruction targets a different finding set" 4
  fi

  [ "$kind" = finding-response ] && expect_change=1

  dir=$(handoff_dir "$task")
  mkdir -p "$dir" 2>/dev/null || die "cannot create the handoff record directory $dir"
  expect="$dir/$seq.expect"
  {
    printf 'schema=%s\n' "$HANDOFF_SCHEMA"
    printf 'task=%s\n' "$(clean_field "$task")"
    printf 'record=%s\n' "$(clean_field "$base")"
    printf 'digest=%s\n' "$(record_digest "$record")"
    printf 'kind=%s\n' "$kind"
    printf 'registered_at=%s\n' "$(date +%s)"
    printf 'baseline_state=%s\n' "$(state_token "$line")"
    printf 'baseline_signature=%s\n' "$(state_signature "$line")"
    printf 'expect_state_change=%s\n' "$expect_change"
    printf 'expect_head=%s\n' "$(clean_field "$expect_head")"
    printf 'expect_gate=%s\n' "$(clean_field "$expect_gate")"
    printf 'expect_findings=%s\n' "$(clean_field "$expect_findings")"
  } > "$expect" 2>/dev/null || die "cannot write the handoff obligation $expect"
  rm -f "$(result_path "$expect")" 2>/dev/null || true
  printf 'handoff registered: %s\n' "$expect"
  printf 'FM_HANDOFF_CONFIRM_REQUIRED %s bin/fm-handoff-confirm.sh confirm --task %s --record %s\n' \
    "$task" "$task" "$record"
}

# One bounded wait for the acknowledgement move. Returns 0 the moment the exact
# record appears in handled/ with unchanged bytes, 1 when the window expires.
# The BASENAME is the identity, not the numeric sequence: the worker moves the
# file it was given, and "007.msg" and "7.msg" are different files.
await_ack() {  # <task> <record-basename> <digest> <deadline> <poll>
  local task=$1 base=$2 digest=$3 deadline=$4 poll=$5 handled moved now
  handled=$(fm_task_inbox_handled_dir "$STATE" "$task")
  moved="$handled/$base"
  while :; do
    if [ -f "$moved" ]; then
      [ "$(record_digest "$moved")" = "$digest" ] && return 0
      # Same name, different bytes: this is not the record we handed over.
      return 2
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    sleep "$poll"
  done
}

cmd_confirm() {
  local task='' record='' timeout=$TIMEOUT_DEFAULT poll=$POLL_DEFAULT rering=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 || usage ;;
      --record) record=${2:-}; shift 2 || usage ;;
      --timeout) timeout=${2:-}; shift 2 || usage ;;
      --poll) poll=${2:-}; shift 2 || usage ;;
      --no-rering) rering=0; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$task" ] && [ -n "$record" ] || usage
  case "$timeout" in ''|*[!0-9]*) usage ;; esac

  local base seq dir expect digest kind expect_change baseline_sig
  base=$(basename "$record")
  seq=$(fm_task_inbox_seq_of "$base") || true
  [ -n "$seq" ] || die "not a steering record name: $base" 2
  dir=$(handoff_dir "$task")
  expect="$dir/$seq.expect"
  [ -f "$expect" ] || die "no registered handoff obligation for $task record $base; register before confirming" 2
  digest=$(expect_get "$expect" digest)
  kind=$(expect_get "$expect" kind)
  expect_change=$(expect_get "$expect" expect_state_change)
  baseline_sig=$(expect_get "$expect" baseline_signature)

  local line deadline rc reason=''
  line=$(crew_state_line "$task")
  if endpoint_is_gone "$line"; then
    reason="the worker is gone before it acknowledged the instruction ($line)"
    finish_failed "$expect" "$task" "$reason"
    return 3
  fi

  deadline=$(( $(date +%s) + timeout ))
  rc=0
  await_ack "$task" "$base" "$digest" "$deadline" "$poll" || rc=$?
  if [ "$rc" = 2 ]; then
    reason="record $base was acknowledged but its bytes are not the instruction that was sent"
    finish_failed "$expect" "$task" "$reason"
    return 3
  fi
  if [ "$rc" = 1 ] && [ "$rering" = 1 ]; then
    # Exactly one re-ring, of exactly this record. The record is already
    # durable; ringing again is free and is the only recovery this script
    # performs itself.
    local inbox target backend
    inbox=$(fm_task_inbox_dir "$STATE" "$task")
    target=$(fm_backend_target_of_meta "$(meta_of "$task")")
    backend=$(fm_backend_of_meta "$(meta_of "$task")")
    if [ -n "$target" ] && [ -f "$inbox/$base" ]; then
      fm_task_inbox_ring "$backend" "$target" "$inbox/$base" "" || true
    fi
    deadline=$(( $(date +%s) + timeout ))
    rc=0
    await_ack "$task" "$base" "$digest" "$deadline" "$poll" || rc=$?
    if [ "$rc" = 2 ]; then
      reason="record $base was acknowledged but its bytes are not the instruction that was sent"
      finish_failed "$expect" "$task" "$reason"
      return 3
    fi
  fi
  if [ "$rc" != 0 ]; then
    if [ "$rering" = 1 ]; then
      reason="the worker never acknowledged record $base, including after one re-ring; it is queued and unread"
    else
      reason="the worker never acknowledged record $base within the window; it is queued and unread"
    fi
    finish_failed "$expect" "$task" "$reason"
    return 3
  fi

  # Acknowledged. Now prove the work actually began.
  line=$(crew_state_line "$task")
  if endpoint_is_gone "$line"; then
    reason="the worker acknowledged record $base and then went away without starting the work ($line)"
    finish_failed "$expect" "$task" "$reason"
    return 3
  fi
  if [ "$expect_change" = 1 ] && [ "$(state_signature "$line")" = "$baseline_sig" ]; then
    reason="record $base was acknowledged but the work never started: the run is still $line"
    finish_failed "$expect" "$task" "$reason"
    return 3
  fi

  printf 'schema=%s\nresult=confirmed\nat=%s\nstate=%s\n' \
    "$HANDOFF_SCHEMA" "$(date +%s)" "$(state_signature "$line")" \
    > "$(result_path "$expect")" 2>/dev/null || die "cannot record the confirmed handoff result"
  printf 'handoff confirmed: %s record %s acknowledged and started (%s)\n' "$task" "$base" "$line"
}

finish_failed() {  # <expect-file> <task> <reason>
  local expect=$1 task=$2 reason=$3
  printf 'schema=%s\nresult=failed\nat=%s\nreason=%s\n' \
    "$HANDOFF_SCHEMA" "$(date +%s)" "$(clean_field "$reason")" \
    > "$(result_path "$expect")" 2>/dev/null || true
  # The wake is queued BEFORE the message is printed, so a caller that dies
  # reading our output still leaves supervision an actionable record.
  emit_failure_wake "$task" "$reason"
  echo "fm-handoff-confirm: FAILED - $reason" >&2
  echo "fm-handoff-confirm: do not report this instruction dispatched; recover the worker (stuck-crewmate-recovery) before relaying it again" >&2
}

cmd_list() {
  local only_task='' dir expect task base kind registered now age result reason
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) only_task=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  now=$(date +%s)
  for dir in "$STATE"/*.handoff; do
    [ -d "$dir" ] || continue
    for expect in "$dir"/*.expect; do
      [ -f "$expect" ] || continue
      task=$(expect_get "$expect" task)
      [ -z "$only_task" ] || [ "$only_task" = "$task" ] || continue
      result=$(result_path "$expect")
      if [ -f "$result" ] && [ "$(expect_get "$result" result)" = confirmed ]; then
        continue
      fi
      base=$(expect_get "$expect" record)
      kind=$(expect_get "$expect" kind)
      registered=$(expect_get "$expect" registered_at)
      case "$registered" in ''|*[!0-9]*) registered=$now ;; esac
      age=$(( now - registered ))
      reason=unconfirmed
      [ -f "$result" ] && reason=$(expect_get "$result" reason)
      printf '%s %s %s %s %s\n' "$task" "$base" "$kind" "$age" "${reason:-unconfirmed}"
    done
  done
}

cmd_status() {
  local task='' record='' base seq expect result
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 || usage ;;
      --record) record=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$task" ] && [ -n "$record" ] || usage
  base=$(basename "$record")
  seq=$(fm_task_inbox_seq_of "$base") || true
  [ -n "$seq" ] || die "not a steering record name: $base" 2
  expect="$(handoff_dir "$task")/$seq.expect"
  [ -f "$expect" ] || die "no registered handoff obligation for $task record $base" 2
  result=$(result_path "$expect")
  if [ -f "$result" ] && [ "$(expect_get "$result" result)" = confirmed ]; then
    printf '%s %s confirmed %s\n' "$task" "$base" "$(expect_get "$result" state)"
    return 0
  fi
  printf '%s %s open %s\n' "$task" "$base" "$(expect_get "$result" reason 2>/dev/null || printf unconfirmed)"
  return 3
}

CMD=${1:-}
shift 2>/dev/null || true
case "$CMD" in
  register) cmd_register "$@" ;;
  confirm) cmd_confirm "$@" ;;
  list) cmd_list "$@" ;;
  status) cmd_status "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
