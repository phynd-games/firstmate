#!/usr/bin/env bash
# tests/fm-handoff-confirm.test.sh - bin/fm-handoff-confirm.sh, the one owner of
# confirmed worker handoff.
#
# The failure this suite exists for is not a crash: it is a supervisor that
# reports an instruction dispatched, ends its turn, and relays the same parked
# finding again, while the worker never took the instruction up at all. Every
# case below is written adversarially against that - the passing cases prove the
# proof can be obtained, and the failing cases prove each way of NOT taking an
# instruction up is caught rather than mistaken for success.
#
# The current-state read is stubbed at bin/fm-crew-state.sh, which is the exact
# seam the script depends on and the single owner of run attribution. Stubbing
# it keeps these cases deterministic without a no-mistakes daemon, and the run
# attribution it owns is covered by its own suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-handoff-confirm)

PARKED='state: parked · source: run-step · parked at review: 3 finding(s) (ask-user: authority decision)'
WORKING='state: working · source: run-step · validating (fixing)'
GONE='state: unknown · source: none · no current-state source available'

# new_world <name>: a home with a fixed bin root whose crew-state read is a stub
# reading one file, so a case can move the worker's state between calls.
new_world() {  # <name> -> "<root>|<home>|<state-file>"
  local name=$1 w root home
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$root/bin" "$home/state"
  cp "$ROOT"/bin/*.sh "$root/bin/"
  cp -R "$ROOT/bin/backends" "$root/bin/"
  cat > "$root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "${FM_FAKE_CREW_STATE:?}"
SH
  chmod +x "$root/bin"/*.sh
  printf '%s\n' "$PARKED" > "$w/crew-state"
  printf '%s|%s|%s\n' "$root" "$home" "$w/crew-state"
}

# seed_task <home> <task>: metadata plus one steering record, ready to hand off.
seed_task() {  # <home> <task> -> record path
  local home=$1 task=$2 record
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-$task" "backend=tmux" "worktree=$home/wt-$task"
  mkdir -p "$home/state/$task.inbox/handled"
  record="$home/state/$task.inbox/004.msg"
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\nrespond to finding F1 at the review gate\n' \
    > "$record"
  printf '%s\n' "$record"
}

hc() {  # <root> <home> <state-file> <args...>
  local root=$1 home=$2 crew=$3
  shift 3
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$home/state" \
    FM_FAKE_CREW_STATE="$crew" \
    "$root/bin/fm-handoff-confirm.sh" "$@"
}

acknowledge() {  # <home> <task> <record>
  mv "$3" "$1/state/$2.inbox/handled/$(basename "$3")"
}

# --- 1. queued but unread -----------------------------------------------------
# The defining failure: the record is durable, the doorbell rang, and nobody
# read it. "Sent" here is exactly the claim that must not be made.
test_queued_but_unread_is_not_delivery() {
  local rec root home crew record out status=0
  rec=$(new_world queued-unread)
  IFS='|' read -r root home crew <<EOF
$rec
EOF
  record=$(seed_task "$home" alpha)
  hc "$root" "$home" "$crew" register --task alpha --record "$record" >/dev/null \
    || fail "register refused a well-formed obligation"
  out=$(hc "$root" "$home" "$crew" confirm --task alpha --record "$record" \
    --timeout 1 --poll 1 --no-rering 2>&1) || status=$?
  expect_code 3 "$status" "an unread record was accepted as a completed handoff: $out"
  assert_contains "$out" "queued and unread" "the failure did not name the unread record"
  assert_contains "$out" "do not report this instruction dispatched" \
    "the failure did not forbid reporting the instruction dispatched"
  pass "a queued, unread record is refused as delivery"
}

# --- 2. acknowledged, but the work never started ------------------------------
# The subtle one. The worker moved the record, so every acknowledgement-only
# check passes, and the run is still parked at the same gate with the same
# findings - which is precisely what "the decision was ignored" looks like.
test_acknowledged_without_starting_is_refused() {
  local rec root home crew record out status=0
  rec=$(new_world ack-no-work)
  IFS='|' read -r root home crew <<EOF
$rec
EOF
  record=$(seed_task "$home" bravo)
  hc "$root" "$home" "$crew" register --task bravo --record "$record" \
    --kind finding-response >/dev/null || fail "register refused a finding response"
  acknowledge "$home" bravo "$record"
  out=$(hc "$root" "$home" "$crew" confirm --task bravo --record "$record" \
    --timeout 1 --poll 1 --no-rering 2>&1) || status=$?
  expect_code 3 "$status" "an acknowledged-but-idle worker was reported as started: $out"
  assert_contains "$out" "the work never started" "the failure did not name the missing start"
  assert_contains "$out" "parked at review" "the failure did not carry the unchanged run state"
  pass "an acknowledgement with no work is refused as a handoff"
}

# --- 3. the wrong message -----------------------------------------------------
# A record with the right NAME but different bytes is a different instruction.
test_wrong_message_bytes_are_refused() {
  local rec root home crew record out status=0
  rec=$(new_world wrong-bytes)
  IFS='|' read -r root home crew <<EOF
$rec
EOF
  record=$(seed_task "$home" charlie)
  hc "$root" "$home" "$crew" register --task charlie --record "$record" >/dev/null \
    || fail "register refused a well-formed obligation"
  # Same name, different instruction.
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\nsomething else entirely\n' \
    > "$home/state/charlie.inbox/handled/004.msg"
  rm -f "$record"
  printf '%s\n' "$WORKING" > "$crew"
  out=$(hc "$root" "$home" "$crew" confirm --task charlie --record "$record" \
    --timeout 1 --poll 1 --no-rering 2>&1) || status=$?
  expect_code 3 "$status" "a different instruction was accepted under the same record name: $out"
  assert_contains "$out" "are not the instruction that was sent" \
    "the failure did not name the byte mismatch"
  pass "a record with the right name and the wrong bytes is refused"
}

# --- 4. wrong run, head, or finding set ---------------------------------------
# Refused at REGISTER, before the obligation exists: a decision aimed at work
# the worker is not doing is wrong when it is sent, not when it is confirmed.
test_expectation_mismatch_is_refused_at_registration() {
  local rec root home crew record out status=0 head
  rec=$(new_world expectation-mismatch)
  IFS='|' read -r root home crew <<EOF
$rec
EOF
  record=$(seed_task "$home" delta)
  fm_git_init_commit "$home/wt-delta"
  head=$(git -C "$home/wt-delta" rev-parse HEAD)

  status=0
  out=$(hc "$root" "$home" "$crew" register --task delta --record "$record" \
    --kind finding-response --expect-gate lint 2>&1) || status=$?
  expect_code 4 "$status" "a decision aimed at the wrong gate was registered: $out"
  assert_contains "$out" "targets a different gate" "the refusal did not name the gate mismatch"
  assert_absent "$home/state/delta.handoff/4.expect" \
    "a refused registration still left an obligation behind"

  status=0
  out=$(hc "$root" "$home" "$crew" register --task delta --record "$record" \
    --kind finding-response --expect-findings 9 2>&1) || status=$?
  expect_code 4 "$status" "a decision aimed at the wrong finding set was registered: $out"
  assert_contains "$out" "targets a different finding set" \
    "the refusal did not name the finding-set mismatch"

  status=0
  out=$(hc "$root" "$home" "$crew" register --task delta --record "$record" \
    --expect-head 0000000000000000000000000000000000000000 2>&1) || status=$?
  expect_code 4 "$status" "a decision aimed at the wrong head was registered: $out"
  assert_contains "$out" "targets different work" "the refusal did not name the head mismatch"

  # The matching expectations are accepted, so the guard is not simply refusing.
  hc "$root" "$home" "$crew" register --task delta --record "$record" \
    --kind finding-response --expect-gate review --expect-findings 3 --expect-head "$head" >/dev/null \
    || fail "register refused expectations that are actually true"
  pass "a decision aimed at the wrong gate, findings, or head is refused before it is owed"
}

# --- 5. the worker exited -----------------------------------------------------
# A worker that is gone can never acknowledge. Waiting out the window for it is
# lost supervision time, so this must fail at once.
test_departed_worker_fails_immediately() {
  local rec root home crew record out status=0 started elapsed
  rec=$(new_world worker-gone)
  IFS='|' read -r root home crew <<EOF
$rec
EOF
  record=$(seed_task "$home" echo1)
  hc "$root" "$home" "$crew" register --task echo1 --record "$record" >/dev/null \
    || fail "register refused a well-formed obligation"
  printf '%s\n' "$GONE" > "$crew"
  started=$(date +%s)
  out=$(hc "$root" "$home" "$crew" confirm --task echo1 --record "$record" \
    --timeout 20 --poll 1 2>&1) || status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 3 "$status" "a departed worker was not reported as a failed handoff: $out"
  assert_contains "$out" "gone before it acknowledged" "the failure did not name the departed worker"
  [ "$elapsed" -lt 10 ] \
    || fail "a departed worker burned the whole wait window ($elapsed s) instead of failing at once"
  pass "a worker that is already gone fails the handoff immediately"
}

# --- 6. delayed acknowledgement ------------------------------------------------
# The worker was simply busy. One re-ring and a second window must let it
# through: a slow worker is not a stuck worker, and failing it would be the
# mirror-image defect of passing an unread record.
test_delayed_acknowledgement_still_confirms() {
  local rec root home crew record out status=0
  rec=$(new_world delayed-ack)
  IFS='|' read -r root home crew <<EOF
$rec
EOF
  record=$(seed_task "$home" foxtrot)
  hc "$root" "$home" "$crew" register --task foxtrot --record "$record" \
    --kind finding-response >/dev/null || fail "register refused a finding response"
  # Acknowledge and start only after the first window has already expired.
  (
    sleep 3
    mv "$record" "$home/state/foxtrot.inbox/handled/004.msg"
    printf '%s\n' "$WORKING" > "$crew"
  ) &
  out=$(hc "$root" "$home" "$crew" confirm --task foxtrot --record "$record" \
    --timeout 2 --poll 1 2>&1) || status=$?
  wait
  expect_code 0 "$status" "a worker that acknowledged after one re-ring was failed: $out"
  assert_contains "$out" "handoff confirmed" "a late but real handoff was not reported confirmed"
  pass "a late acknowledgement inside the re-ring window still confirms"
}

# --- 7. acknowledged and started ----------------------------------------------
test_acknowledged_and_started_confirms() {
  local rec root home crew record out status=0
  rec=$(new_world ack-and-start)
  IFS='|' read -r root home crew <<EOF
$rec
EOF
  record=$(seed_task "$home" golf)
  hc "$root" "$home" "$crew" register --task golf --record "$record" \
    --kind finding-response >/dev/null || fail "register refused a finding response"
  acknowledge "$home" golf "$record"
  printf '%s\n' "$WORKING" > "$crew"
  out=$(hc "$root" "$home" "$crew" confirm --task golf --record "$record" \
    --timeout 2 --poll 1 --no-rering 2>&1) || status=$?
  expect_code 0 "$status" "a real handoff was not confirmed: $out"
  assert_contains "$out" "acknowledged and started" "the success did not state both proofs"
  # A confirmed obligation is closed; an unconfirmed one stays open work.
  out=$(hc "$root" "$home" "$crew" list 2>&1)
  assert_not_contains "$out" "golf" "a confirmed handoff was still listed as open"
  status=0
  hc "$root" "$home" "$crew" status --task golf --record "$record" >/dev/null || status=$?
  expect_code 0 "$status" "a confirmed obligation did not read back as confirmed"
  pass "an acknowledged and started instruction confirms and closes its obligation"
}

# --- 8. forced recovery escalation --------------------------------------------
# The exit status alone is not enough: a failed handoff has to reach supervision
# as recovery work even if whoever ran the command never looks at its output.
test_failed_handoff_queues_recovery_work() {
  local rec root home crew record queue row status=0
  rec=$(new_world recovery-escalation)
  IFS='|' read -r root home crew <<EOF
$rec
EOF
  record=$(seed_task "$home" hotel)
  hc "$root" "$home" "$crew" register --task hotel --record "$record" >/dev/null \
    || fail "register refused a well-formed obligation"
  hc "$root" "$home" "$crew" confirm --task hotel --record "$record" \
    --timeout 1 --poll 1 --no-rering >/dev/null 2>&1 || status=$?
  expect_code 3 "$status" "the unconfirmed handoff did not fail"
  queue="$home/state/.wake-queue"
  [ -s "$queue" ] || fail "a failed handoff queued no wake at all"
  row=$(grep -F "$(printf '\tstale\thotel\t')" "$queue" | tail -1)
  [ -n "$row" ] || fail "the failed handoff did not queue a stale wake for the task: $(cat "$queue")"
  assert_contains "$row" "never proven taken up" \
    "the queued wake did not say the instruction was never taken up"
  # Still open afterwards: a failure closes nothing.
  assert_contains "$(hc "$root" "$home" "$crew" list 2>&1)" "hotel" \
    "a failed handoff stopped being open work"
  pass "a failed handoff queues recovery work and stays open"
}

# --- 9. repeated outcomes never spam the captain ------------------------------
# Asserted against the real store, which is what the branch extension reads.
test_repeated_outcomes_coalesce() {
  local store out first second third
  store="$TMP_ROOT/outcome-store"
  mkdir -p "$store"
  first=$(FM_STATE_OVERRIDE="$store" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task india --verdict captain --summary 'the PR is red') \
    || fail "the outcome store refused a first captain outcome"
  case "$first" in
    *repeat=*) fail "a first outcome was reported as a repeat: $first" ;;
  esac
  second=$(FM_STATE_OVERRIDE="$store" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task india --verdict captain --summary 'the PR is red')
  assert_contains "$second" "repeat=2" "the same outcome said twice was not coalesced: $second"
  third=$(FM_STATE_OVERRIDE="$store" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task india --verdict captain --summary 'the PR is red')
  assert_contains "$third" "repeat=3" "the repeat count did not keep rising: $third"

  # A genuinely different outcome is never coalesced away.
  out=$(FM_STATE_OVERRIDE="$store" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task india --verdict captain --summary 'the PR is green')
  case "$out" in
    *repeat=*) fail "a different outcome was suppressed as a repeat: $out" ;;
  esac

  # Every repeat is still durably stored: coalescing changes who is woken, not
  # what is recorded.
  [ "$(grep -c '"summary":"the PR is red"' "$store/branch-outcomes.jsonl")" = 3 ] \
    || fail "coalescing dropped a repeat from the append-only store"
  out=$(FM_STATE_OVERRIDE="$store" "$ROOT/bin/fm-branch-outcome.sh" unread)
  assert_contains "$out" '"repeat":3' "the store did not record the repeat count it reported"
  pass "an identical outcome coalesces with a rising count while the store keeps every row"
}

# --- 10. the send boundary owes the obligation --------------------------------
# The rule is only real if the obligation exists without anyone remembering to
# create it. bin/fm-send.sh registers it as it writes the record, and prints the
# exact confirm command, so "I sent it" and "it was taken up" cannot be
# conflated by omission. A fire-and-forget record opts out by definition.
test_send_registers_the_obligation_it_owes() {
  local w state fakebin out record
  w="$TMP_ROOT/send-boundary"
  state="$w/state"
  fakebin="$w/fakebin"
  mkdir -p "$state" "$fakebin"
  # A tmux that accepts everything: this case is about what fm-send RECORDS,
  # and the doorbell is explicitly best-effort on this plane.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *list-panes*|*display-message*) printf 'firstmate:fm-juliet
' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_write_meta "$state/juliet.meta" \
    "window=firstmate:fm-juliet" "backend=tmux" "worktree=$w/wt" "harness=claude"

  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w" \
    FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" fm-juliet "respond to the review gate" 2>&1) \
    || fail "fm-send refused an ordinary local steer: $out"
  record="$state/juliet.inbox/001.msg"
  [ -f "$record" ] || fail "fm-send did not record the steer at all: $out"
  assert_contains "$out" "FM_HANDOFF_CONFIRM_REQUIRED" \
    "fm-send did not print the confirm command its own steer owes: $out"
  assert_present "$state/juliet.handoff/1.expect" \
    "fm-send recorded a steer without registering the handoff obligation for it"
  assert_grep "record=001.msg" "$state/juliet.handoff/1.expect" \
    "the obligation does not name the exact record that was sent"

  # Fire-and-forget opts out of the acknowledgement ladder, so it owes nothing.
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w" \
    FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" fm-juliet --fire-and-forget 0123456789abcdef "no reply wanted" 2>&1) || true
  assert_absent "$state/juliet.handoff/2.expect" \
    "a fire-and-forget record registered a handoff obligation it never owed"
  pass "the send boundary registers the obligation and prints the confirm command it owes"
}

# --- 11. the supervision branch is told the same rule ------------------------
# The branch steers workers too, and it is the actor that reports outcomes, so
# the rule has to reach it through the interface it actually receives.
test_branch_prompt_carries_the_handoff_rule() {
  local prompt
  prompt="$TMP_ROOT/branch-prompt-handoff.txt"
  "$ROOT/bin/fm-branch-prompt.sh" > "$prompt"
  assert_grep 'A recorded steer is not a taken-up steer' "$prompt" \
    "the emitted branch prompt lets a recorded steer count as a delivered one"
  assert_grep 'an unchanged parked run is a failed handoff, not a reason to send it twice' "$prompt" \
    "the emitted branch prompt does not name the acknowledged-but-idle failure"
  assert_grep 'never reach for the captain because a finding recurred' "$prompt" \
    "the emitted branch prompt still lets a repeated finding go to the captain"
  pass "the emitted branch prompt carries the confirmed-handoff rule and the repeat rule"
}

test_branch_prompt_carries_the_handoff_rule
test_queued_but_unread_is_not_delivery
test_acknowledged_without_starting_is_refused
test_wrong_message_bytes_are_refused
test_expectation_mismatch_is_refused_at_registration
test_departed_worker_fails_immediately
test_delayed_acknowledgement_still_confirms
test_acknowledged_and_started_confirms
test_failed_handoff_queues_recovery_work
test_repeated_outcomes_coalesce
test_send_registers_the_obligation_it_owes
