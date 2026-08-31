#!/usr/bin/env bash
# tests/fm-validation-loop.test.sh - deterministic rational limits for the
# automatic continuation of a crew's validation loop
# (bin/fm-validation-loop-lib.sh), their integration into crew_absorb_class
# (bin/fm-classify-lib.sh), and the watcher's decorated limit surface
# (bin/fm-watch.sh). The accepted contract these cases pin:
#   - a run with fresh evidence, coherent advance, bounded findings, and a
#     credible path to completion keeps absorbing (near-complete continuation);
#   - repetition (fix rounds or an identical findings theme past its bound),
#     an unknown/unreadable current state, a stalled active run, and stale
#     pipeline evidence all STOP automatic continuation - the wake surfaces
#     and is never re-absorbed as routine progress;
#   - a stop changes nothing but the durable journal: branch and run custody
#     stay recorded, and the supervised recovery handoff (a new run id on the
#     same copy) resets the counters so continuation resumes.
# All cases drive the REAL fold/verdict/absorb functions over crafted evidence
# files; the crew-state reader is stubbed exactly like the watcher suite stubs
# it (FM_CREW_STATE_BIN), with an evidence-exporting variant where a case needs
# the real export-then-fold path.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-validation-loop-tests)

# A fake fm-crew-state.sh that also honors the evidence-export seam: when
# FM_FAKE_EVIDENCE names a file and the caller passed
# FM_CREW_STATE_EVIDENCE_FILE, the fixture is copied there exactly as the real
# reader exports an attributed run's raw evidence.
make_exporting_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/fm-crew-state-ev.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_EVIDENCE:-}" ] && [ -n "${FM_CREW_STATE_EVIDENCE_FILE:-}" ]; then
  cp "$FM_FAKE_EVIDENCE" "$FM_CREW_STATE_EVIDENCE_FILE"
fi
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/fm-crew-state-ev.sh"
  printf '%s\n' "$fakebin/fm-crew-state-ev.sh"
}

# --- evidence fixtures (raw `axi status` TOON, as the reader exports it) -----

ev_running() {  # <file> <run-id> <review-status> <test-status>
  cat > "$1" <<EOF
run:
  id: "$2"
  branch: fm/loop
  status: running
  head: "abc1234"
  pr: ""
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,$3,0,20
    test,$4,0,30
EOF
}

ev_fixing() {  # <file> <run-id>
  cat > "$1" <<EOF
run:
  id: "$2"
  branch: fm/loop
  status: fixing
  head: "abc1234"
  pr: ""
  findings: none
EOF
}

ev_ci() {  # <file> <run-id>
  cat > "$1" <<EOF
run:
  id: "$2"
  branch: fm/loop
  status: running
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,completed,0,20
    push,completed,0,30
    ci,running,0,40
EOF
}

ev_gate() {  # <file> <run-id> <finding-id-1> <finding-id-2> <description>
  cat > "$1" <<EOF
run:
  id: "$2"
  branch: fm/loop
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "abc1234"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    $3,warning,a.go,,auto-fix,$5
    $4,error,b.go,,auto-fix,unchecked slice
gate: review
EOF
}

new_state() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# Fold one fixture at a virtual epoch.
fold() {  # <state> <id> <evidence-file> <epoch>
  FM_VLOOP_NOW=$4 fm_vloop_observe "$1" "$2" "$3" "${5:-}" || fail "fm_vloop_observe failed for $3"
}

verdict_at() {  # <state> <id> <epoch>
  FM_VLOOP_NOW=$3 fm_vloop_verdict "$1" "$2"
}

# --- required regression: near-complete continuation -------------------------
# A healthy run advancing toward completion keeps the continue verdict at every
# observation, and the absorb classification keeps reporting working.
test_near_complete_continuation() {
  local state ev fakebin dir
  dir=$(make_case vloop-near-complete); state="$dir/state"; fakebin="$dir/fakebin"
  ev="$dir/ev"
  ev_running "$ev" 01RUN running pending
  fold "$state" near "$ev" 1000
  [ "$(verdict_at "$state" near 1010)" = continue ] || fail "early advancing run did not continue"
  ev_running "$ev" 01RUN completed running
  fold "$state" near "$ev" 1600
  [ "$(verdict_at "$state" near 1610)" = continue ] || fail "step advance did not continue"
  ev_ci "$ev" 01RUN
  fold "$state" near "$ev" 2200
  [ "$(verdict_at "$state" near 2210)" = continue ] || fail "near-complete ci monitoring did not continue"

  # Through the real export-then-fold absorb path: still absorbed as working,
  # and the transient evidence export is cleaned up.
  export FM_CREW_STATE_BIN
  FM_CREW_STATE_BIN=$(make_exporting_crew_state "$fakebin")
  export FM_FAKE_EVIDENCE="$ev" FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
  [ "$(STATE=$state FM_VLOOP_NOW=2300 crew_absorb_class near)" = working ] \
    || fail "a near-complete healthy run was not absorbed as working"
  find "$state" -name '.vloop-evidence-*' | grep -q . \
    && fail "the transient evidence export was not cleaned up"
  unset FM_FAKE_EVIDENCE FM_FAKE_CREW_STATE
  pass "near-complete continuation: fresh advancing evidence keeps continue/working at every observation"
}

# --- required regression: repeated-finding stop -------------------------------
# The identical findings set presented past the same-theme bound stops
# continuation; genuinely different findings never trip it.
test_repeated_finding_stop() {
  local state ev fakebin dir v
  dir=$(make_case vloop-repeat-finding); state="$dir/state"; fakebin="$dir/fakebin"
  ev="$dir/ev"
  # Identical findings (per-round finding ids differ; the theme is the same),
  # re-presented after each fix round.
  ev_gate "$ev" 01RUN r1 r2 "ignored error"; fold "$state" rep "$ev" 1000
  ev_fixing "$ev" 01RUN;                      fold "$state" rep "$ev" 1010
  ev_gate "$ev" 01RUN r3 r4 "ignored error"; fold "$state" rep "$ev" 1020
  [ "$(verdict_at "$state" rep 1030)" = continue ] || fail "second identical presentation stopped too early"
  ev_fixing "$ev" 01RUN;                      fold "$state" rep "$ev" 1040
  ev_gate "$ev" 01RUN r5 r6 "ignored error"; fold "$state" rep "$ev" 1050
  v=$(verdict_at "$state" rep 1060)
  case "$v" in
    stop*"identical findings theme"*) ;;
    *) fail "third identical presentation did not stop with the theme reason: '$v'" ;;
  esac

  # The stop is reflected by the absorb classification, not hidden as working.
  export FM_CREW_STATE_BIN
  FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (fixing)'
  [ "$(STATE=$state crew_absorb_class rep)" = limit ] \
    || fail "a theme-bounded loop was not classed limit"
  STATE=$state crew_is_provably_working rep \
    && fail "a theme-bounded loop still read as provably working"
  unset FM_FAKE_CREW_STATE

  # Control: three DIFFERENT findings themes are ordinary progress.
  ev_gate "$ev" 02RUN r1 r2 "ignored error";   fold "$state" ctl "$ev" 1000
  ev_fixing "$ev" 02RUN;                        fold "$state" ctl "$ev" 1010
  ev_gate "$ev" 02RUN r3 r4 "missing doc";     fold "$state" ctl "$ev" 1020
  ev_fixing "$ev" 02RUN;                        fold "$state" ctl "$ev" 1030
  ev_gate "$ev" 02RUN r5 r6 "shadowed field";  fold "$state" ctl "$ev" 1040
  [ "$(verdict_at "$state" ctl 1050)" = continue ] || fail "distinct findings themes were miscounted as repetition"

  # A cycle longer than the old theme cache must not evict a theme's count.
  local cycle theme
  for cycle in 1 2 3; do
    for theme in 1 2 3 4 5 6 7 8 9; do
      ev_gate "$ev" 03RUN "c${cycle}a" "c${cycle}b" "cycle-theme-$theme"
      fold "$state" cyc "$ev" $((1100 + cycle * 100 + theme))
    done
  done
  v=$(verdict_at "$state" cyc 1500)
  case "$v" in
    stop*"identical findings theme"*) ;;
    *) fail "a long repeating theme cycle bypassed the same-theme bound: '$v'" ;;
  esac
  pass "repeated-finding stop: the identical theme past its bound stops; distinct themes continue"
}

# --- required regression: unknown-state stop ----------------------------------
# An unknown, unreadable, or dead current state is never absorbed as working,
# with or without a validation journal.
test_unknown_state_stop() {
  local state ev fakebin dir
  dir=$(make_case vloop-unknown); state="$dir/state"; fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone (torn down?)'
  [ "$(STATE=$state crew_absorb_class unk)" = none ] || fail "an unknown state was absorbed"
  FM_FAKE_CREW_STATE='state: unknown · source: remote-endpoint · remote endpoint dead on host'
  [ "$(STATE=$state crew_absorb_class unk)" = none ] || fail "a dead endpoint was absorbed"
  FM_FAKE_CREW_STATE='garbage the reader never prints'
  [ "$(STATE=$state crew_absorb_class unk)" = none ] || fail "an unreadable verdict was absorbed"
  # Same with an ACTIVE journal recorded: unknown current state still surfaces.
  ev="$dir/ev"
  ev_running "$ev" 01RUN running pending
  fold "$state" unk "$ev" 1000
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  [ "$(STATE=$state crew_absorb_class unk)" = none ] \
    || fail "an unknown state over an active journal was absorbed"
  unset FM_FAKE_CREW_STATE
  pass "unknown-state stop: unknown, unreadable, and dead verdicts are never absorbed"
}

test_malformed_evidence_stop() {
  local state fakebin dir ev rc
  dir=$(make_case vloop-malformed-evidence); state="$dir/state"; fakebin="$dir/fakebin"
  ev="$dir/ev"
  printf 'run:\n  id: "01RUN"\n  branch: fm/loop\n' > "$ev"
  export FM_CREW_STATE_BIN
  FM_CREW_STATE_BIN=$(make_exporting_crew_state "$fakebin")
  export FM_FAKE_EVIDENCE="$ev" FM_FAKE_CREW_STATE='state: working · source: run-step · malformed'
  [ "$(STATE=$state crew_absorb_class malformed)" = none ] \
    || fail "malformed run evidence was absorbed as working"
  [ ! -e "$state/malformed.validation-loop" ] \
    || fail "malformed evidence created a continuation journal without a valid run"
  ev_running "$ev" 01RUN running pending
  fold "$state" malformed-outcome "$ev" 1000
  printf 'outcome: garbage\n' >> "$ev"
  if fm_vloop_observe "$state" malformed-outcome "$ev"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 2 ] || fail "an unrecognized run outcome was accepted"
  [ "$(fm_vloop_reason "$state" malformed-outcome)" = \
    'validation evidence malformed or incomplete for task malformed-outcome' ] \
    || fail "an unrecognized run outcome did not stop with its recovery reason"
  unset FM_FAKE_EVIDENCE FM_FAKE_CREW_STATE
  pass "malformed evidence stop: incomplete run evidence fails closed at the absorb boundary"
}

test_malformed_journal_stop() {
  local state fakebin dir
  dir=$(make_case vloop-malformed-journal); state="$dir/state"; fakebin="$dir/fakebin"
  printf 'version=1\nactive=1\n' > "$state/broken.validation-loop"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (native)'
  [ "$(STATE=$state crew_absorb_class broken)" = none ] \
    || fail "an incomplete validation journal was absorbed as working"
  [ "$(fm_vloop_reason "$state" broken)" = \
    'validation-loop journal unreadable or incomplete; recover in the same copy' ] \
    || fail "an incomplete validation journal did not expose its recovery reason"
  cat > "$state/bogus.validation-loop" <<'EOF'
version=1
run=01RUN
head=abc1234
status=bogus
phase=running
findings_sig=
progress_sig=abc
fix_rounds=0
themes=
heads=abc1234
last_observed=1000
last_progress=1000
active=1
stop_reason=
EOF
  [ "$(FM_VLOOP_NOW=2000 fm_vloop_verdict "$state" bogus 2>/dev/null || true)" = \
    'stop validation-loop journal unreadable or incomplete; recover in the same copy' ] \
    || fail "an unrecognized journal status continued"
  cat > "$state/incoherent.validation-loop" <<'EOF'
version=1
run=01RUN
head=abc1234
status=completed
phase=terminal
findings_sig=
progress_sig=abc
fix_rounds=0
themes=
heads=abc1234
last_observed=1000
last_progress=1000
active=1
stop_reason=
scope_base=
scope_head=
scope_paths=
EOF
  [ "$(FM_VLOOP_NOW=2000 fm_vloop_verdict "$state" incoherent 2>/dev/null || true)" = \
    'stop validation-loop journal unreadable or incomplete; recover in the same copy' ] \
    || fail "an incoherent terminal journal state continued"
  unset FM_FAKE_CREW_STATE
  pass "malformed journal stop: incomplete and unrecognized loop state fails closed"
}

test_journal_write_failure_stops_closed() {
  local state ev dir rc
  dir=$(make_case vloop-write-failure); state="$dir/state"; ev="$dir/ev"
  ev_running "$ev" 01RUN running pending; fold "$state" writefail "$ev" 1000
  if FM_VLOOP_NOW=9000 bash -c '
    . "$1/bin/fm-validation-loop-lib.sh"
    _fm_vloop_record_stop() { return 1; }
    fm_vloop_observe "$2" writefail "$3"
  ' _ "$ROOT" "$state" "$dir/missing-evidence"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "a time-stop journal write failure was reported as success"
  pass "journal write failure: time-based stop propagation fails closed"
}

# --- required regression: stale pipeline evidence ------------------------------
# An active run recorded in the journal with no readable run evidence within
# the freshness bound stops continuation even though the pane still reads busy.
test_stale_pipeline_evidence() {
  local state ev fakebin dir v
  dir=$(make_case vloop-stale-evidence); state="$dir/state"; fakebin="$dir/fakebin"
  ev="$dir/ev"
  ev_running "$ev" 01RUN running pending
  fold "$state" stale "$ev" 1000
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  # The pane is busy but no run is readable this call (the stub exports no
  # evidence), inside the freshness bound: continuation is allowed.
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (native)'
  [ "$(STATE=$state FM_VLOOP_NOW=2000 crew_absorb_class stale)" = working ] \
    || fail "fresh-enough journal evidence did not allow pane-source continuation"
  # Past the bound the same pane-busy read stops: the run state is unknown.
  [ "$(STATE=$state FM_VLOOP_NOW=9000 crew_absorb_class stale)" = limit ] \
    || fail "stale pipeline evidence did not stop pane-source continuation"
  v=$(FM_VLOOP_NOW=9000 fm_vloop_verdict "$state" stale)
  case "$v" in
    stop*"pipeline evidence stale"*) ;;
    *) fail "stale-evidence stop did not carry its reason: '$v'" ;;
  esac
  # A terminal run releases the bound entirely: nothing active is being continued.
  cat > "$ev" <<EOF
run:
  id: "01RUN"
  branch: fm/loop
  status: completed
  head: "abc1234"
  findings: none
outcome: passed
EOF
  fold "$state" stale "$ev" 9100
  [ "$(verdict_at "$state" stale 99999)" = continue ] \
    || fail "a terminal run still enforced the evidence-freshness bound"
  unset FM_FAKE_CREW_STATE
  pass "stale pipeline evidence: an active run unreadable past the bound stops; fresh or terminal evidence does not"
}

# --- required regression: recovery handoff ------------------------------------
# A stop preserves the recorded run custody unchanged, and the supported
# same-copy recovery (a NEW run on the same branch and copy) resets the
# counters so continuation resumes - without any manual journal surgery.
test_recovery_handoff() {
  local state ev fakebin dir v journal
  dir=$(make_case vloop-recovery); state="$dir/state"; fakebin="$dir/fakebin"
  ev="$dir/ev"
  # Breach the fix-round bound quickly with a tight override.
  ev_running "$ev" 01RUN running pending; FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" rec "$ev" 1000
  ev_fixing  "$ev" 01RUN;                 FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" rec "$ev" 1010
  ev_running "$ev" 01RUN running rerun;    FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" rec "$ev" 1020
  ev_fixing  "$ev" 01RUN;                 FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" rec "$ev" 1030
  v=$(verdict_at "$state" rec 1040)
  case "$v" in
    stop*"fix rounds"*"01RUN"*) ;;
    *) fail "fix-round breach did not stop with its reason: '$v'" ;;
  esac
  # Custody is preserved: the journal still names the bounded run and its head,
  # and stopping wrote nothing anywhere else in the state directory.
  journal=$(fm_vloop_journal_path "$state" rec)
  grep -q '^run=01RUN$' "$journal" || fail "the stop lost the recorded run identity"
  grep -q '^head=abc1234$' "$journal" || fail "the stop lost the recorded run head"
  [ "$(find "$state" -type f | wc -l | tr -d ' ')" = 1 ] \
    || fail "a stop wrote state beyond the journal: $(find "$state" -type f)"
  # Supported same-copy recovery: a replacement run starts a clean slate.
  ev_running "$ev" 02RUN running pending
  FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" rec "$ev" 2000
  [ "$(verdict_at "$state" rec 2010)" = continue ] \
    || fail "a recovery run did not reset the loop bounds"
  grep -q '^fix_rounds=0$' "$journal" || fail "fix rounds were not reset on the recovery run"
  grep -q '^run=02RUN$' "$journal" || fail "the recovery run identity was not recorded"
  pass "recovery handoff: a stop preserves run custody, and a new run on the same copy resets the bounds"
}

# --- threshold semantics -------------------------------------------------------

test_fix_round_bound_semantics() {
  local state ev dir i v
  dir=$(make_case vloop-fix-bound); state="$dir/state"
  ev="$dir/ev"
  for i in 1 2 3 4 5 6; do
    ev_running "$ev" 01RUN running pending; fold "$state" fx "$ev" $((1000 + i * 20))
    ev_fixing  "$ev" 01RUN;                 fold "$state" fx "$ev" $((1010 + i * 20))
  done
  [ "$(verdict_at "$state" fx 1150)" = continue ] || fail "the bound itself (6 rounds) stopped"
  ev_running "$ev" 01RUN running pending; fold "$state" fx "$ev" 1200
  ev_fixing  "$ev" 01RUN;                 fold "$state" fx "$ev" 1210
  v=$(verdict_at "$state" fx 1220)
  case "$v" in
    stop*"fix rounds 7 exceeded bound 6"*) ;;
    *) fail "the seventh fix round did not stop with the counted reason: '$v'" ;;
  esac
  pass "fix-round bound: the default bound is routine; the first round past it stops with counts"
}

test_stall_stop_and_progress_resume() {
  local state ev dir v
  dir=$(make_case vloop-stall); state="$dir/state"
  ev="$dir/ev"
  # Identical active evidence except the duration column, which must not count
  # as advance.
  ev_running "$ev" 01RUN running pending; fold "$state" st "$ev" 1000
  sed -i.bak 's/,10$/,99/' "$ev" && rm -f "$ev.bak"
  fold "$state" st "$ev" 2000
  [ "$(verdict_at "$state" st 3000)" = continue ] || fail "a frozen run inside the stall bound stopped early"
  v=$(verdict_at "$state" st 4700)
  case "$v" in
    stop*"no evidence advance"*) ;;
    *) fail "a frozen active run past the stall bound did not stop: '$v'" ;;
  esac
  grep -q '^stop_reason=no evidence advance' "$state/st.validation-loop" \
    || fail "the time-based stall breach was not persisted in the journal"
  # A replacement run on the same copy is the supported recovery handoff.
  ev_running "$ev" 02RUN completed running; fold "$state" st "$ev" 4800
  [ "$(verdict_at "$state" st 4900)" = continue ] || fail "a recovery run did not resume continuation"
  # The ci phase is exempt: no-mistakes' own CI monitor owns that wait.
  ev_ci "$ev" 02RUN; fold "$state" st "$ev" 5000
  [ "$(verdict_at "$state" st 9990)" = continue ] || fail "a long ci monitor wait was misread as a stall"
  pass "stall: frozen evidence stops, recovery resumes, ci waits are exempt"
}

test_coarse_evidence_does_not_enforce_stall() {
  local state ev dir
  dir=$(make_case vloop-coarse); state="$dir/state"; ev="$dir/ev"
  ev_running "$ev" 01RUN running pending; fold "$state" coarse "$ev" 1000
  printf 'coarse: running\n' > "$ev"
  FM_VLOOP_STALL_SECS=1 FM_VLOOP_EVIDENCE_MAX_AGE_SECS=99999 \
    fold "$state" coarse "$ev" 2000
  [ "$(FM_VLOOP_STALL_SECS=1 FM_VLOOP_EVIDENCE_MAX_AGE_SECS=99999 verdict_at "$state" coarse 3000)" = continue ] \
    || fail "coarse evidence inherited a running-phase stall bound"
  pass "coarse evidence: fallback status never enforces the running/fixing stall bound"
}

test_head_change_set_is_bounded() {
  local state ev dir repo old_head new_head unrelated_head v
  dir=$(make_case vloop-change-set); state="$dir/state"; ev="$dir/ev"; repo="$dir/repo"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf 'base\n' > "$repo/file"
  git -C "$repo" add file && git -C "$repo" commit -qm base
  old_head=$(git -C "$repo" rev-parse HEAD)
  printf 'one\n' > "$repo/file"
  git -C "$repo" commit -qam one
  printf 'two\n' > "$repo/file"
  git -C "$repo" commit -qam two
  new_head=$(git -C "$repo" rev-parse HEAD)
  ev_running "$ev" 01RUN running pending
  sed -i.bak "s/abc1234/$old_head/" "$ev" && rm -f "$ev.bak"
  printf 'base: "%s"\nchanges[1]{path}:\n  file\n' "$old_head" >> "$ev"
  fold "$state" changes "$ev" 1000 "$repo"
  sed -i.bak "s/^  head: \"$old_head\"/  head: \"$new_head\"/" "$ev" && rm -f "$ev.bak"
  FM_VLOOP_MAX_CHANGE_COMMITS=1 fold "$state" changes "$ev" 1010 "$repo"
  v=$(FM_VLOOP_MAX_CHANGE_COMMITS=1 verdict_at "$state" changes 1020)
  case "$v" in
    stop*"incoherent head transition"*) ;;
    *) fail "an overlarge head change set continued: '$v'" ;;
  esac
  mkdir -p "$dir/known-state"
  state="$dir/known-state"
  ev_running "$ev" 01RUN running pending
  sed -i.bak "s/abc1234/$old_head/" "$ev" && rm -f "$ev.bak"
  printf 'base: "%s"\nchanges[1]{path}:\n  file\n' "$old_head" >> "$ev"
  fold "$state" changes "$ev" 1030 "$repo"
  printf 'unrelated\n' > "$repo/unrelated.txt"
  git -C "$repo" add unrelated.txt && git -C "$repo" commit -qm unrelated
  unrelated_head=$(git -C "$repo" rev-parse HEAD)
  sed -i.bak "s/^  head: \"$old_head\"/  head: \"$unrelated_head\"/" "$ev" && rm -f "$ev.bak"
  fold "$state" changes "$ev" 1040 "$repo"
  v=$(verdict_at "$state" changes 1050)
  case "$v" in
    stop*"incoherent head transition"*) ;;
    *) fail "a new unrelated file entered the automatic head transition: '$v'" ;;
  esac
  pass "head change set: an overlarge transition stops instead of refreshing progress"
}

test_head_change_set_allows_authenticated_addition() {
  local state ev dir repo old_head new_head v
  dir=$(make_case vloop-change-addition); state="$dir/state"; ev="$dir/ev"; repo="$dir/repo"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf 'base\n' > "$repo/file"
  git -C "$repo" add file && git -C "$repo" commit -qm base
  old_head=$(git -C "$repo" rev-parse HEAD)
  printf 'added\n' > "$repo/new.txt"
  git -C "$repo" add new.txt && git -C "$repo" commit -qm addition
  new_head=$(git -C "$repo" rev-parse HEAD)
  ev_running "$ev" 01RUN running pending
  sed -i.bak "s/abc1234/$old_head/" "$ev" && rm -f "$ev.bak"
  printf 'base: "%s"\nchanges[1]{path}:\n  new.txt\n' "$old_head" >> "$ev"
  fold "$state" addition "$ev" 1000 "$repo"
  sed -i.bak "s/^  head: \"$old_head\"/  head: \"$new_head\"/" "$ev" && rm -f "$ev.bak"
  fold "$state" addition "$ev" 1010 "$repo"
  v=$(verdict_at "$state" addition 1020)
  [ "$v" = continue ] || fail "an authenticated new-file change stopped: '$v'"
  pass "head change set: an authenticated new file remains eligible"
}

test_head_transition_is_coherent() {
  local state ev dir v repo old_head new_head
  dir=$(make_case vloop-head-transition); state="$dir/state"; ev="$dir/ev"; repo="$dir/repo"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf 'one\n' > "$repo/file"
  git -C "$repo" add file && git -C "$repo" commit -qm one
  old_head=$(git -C "$repo" rev-parse HEAD)
  printf 'two\n' > "$repo/file"
  git -C "$repo" commit -qam two
  new_head=$(git -C "$repo" rev-parse HEAD)
  ev_running "$ev" 01RUN running pending
  sed -i.bak "s/abc1234/$old_head/" "$ev" && rm -f "$ev.bak"
  printf 'base: "%s"\nchanges[1]{path}:\n  file\n' "$old_head" >> "$ev"
  fold "$state" head "$ev" 1000 "$repo"
  sed -i.bak "s/^  head: \"$old_head\"/  head: \"$new_head\"/" "$ev" && rm -f "$ev.bak"
  fold "$state" head "$ev" 1010 "$repo"
  [ "$(verdict_at "$state" head 1020)" = continue ] || fail "a first head advance stopped"
  sed -i.bak "s/^  head: \"$new_head\"/  head: \"$old_head\"/" "$ev" && rm -f "$ev.bak"
  fold "$state" head "$ev" 1030 "$repo"
  v=$(verdict_at "$state" head 1040)
  case "$v" in
    stop*"incoherent head transition"*) ;;
    *) fail "a regressed head did not stop with an actionable reason: '$v'" ;;
  esac
  grep -q '^stop_reason=incoherent head transition' "$state/head.validation-loop" \
    || fail "the incoherent head stop was not durable"
  pass "head transition: repeated or regressed run heads stop instead of refreshing progress"
}

test_threshold_overrides_cannot_disable_bounds() {
  local state ev dir v
  dir=$(make_case vloop-override); state="$dir/state"
  ev="$dir/ev"
  ev_gate "$ev" 01RUN r1 r2 "ignored error"; FM_VLOOP_MAX_SAME_THEME=0 fold "$state" ov "$ev" 1000
  ev_fixing "$ev" 01RUN;                      FM_VLOOP_MAX_SAME_THEME=0 fold "$state" ov "$ev" 1010
  ev_gate "$ev" 01RUN r3 r4 "ignored error"; FM_VLOOP_MAX_SAME_THEME=0 fold "$state" ov "$ev" 1020
  # A zero/malformed override never widens OR disables: the default (2) applies,
  # so the second presentation is still routine.
  [ "$(verdict_at "$state" ov 1030)" = continue ] \
    || fail "a zero same-theme override changed the default bound"
  v=$(FM_VLOOP_EVIDENCE_MAX_AGE_SECS=bogus verdict_at "$state" ov 99999)
  case "$v" in
    stop*"pipeline evidence stale"*) ;;
    *) fail "a malformed freshness override disabled the evidence bound: '$v'" ;;
  esac
  pass "threshold overrides: zero or malformed values fall back to the defaults, never disable a bound"
}

# --- watcher integration: the surfaced reason names the breach -----------------
test_watcher_surfaces_validation_loop_limit() {
  local dir state fakebin out drain_out capture_file window key pane_hash ev pid
  dir=$(make_case vloop-watcher); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-loopy"
  printf 'static validation pane' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/loopy.meta"
  printf 'done: prior validation result\n' > "$state/loopy.status"
  prime_status_seen "$state" "$state/loopy.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text 'static validation pane')
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Breach the loop bounds through the real fold (tight override), so the
  # watcher's verdict read finds a recorded stop.
  ev="$dir/ev"
  ev_running "$ev" 01RUN running pending; FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" loopy "$ev" 1000
  ev_fixing  "$ev" 01RUN;                 FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" loopy "$ev" 1010
  ev_running "$ev" 01RUN running rerun;    FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" loopy "$ev" 1020
  ev_fixing  "$ev" 01RUN;                 FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" loopy "$ev" 1030
  # The crew still LOOKS working (an active run-step) - exactly the shape the
  # absorb path used to recycle forever.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (fixing)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a limit-stopped validating crew"
  grep -F "validation loop limit:" "$out" >/dev/null \
    || fail "the surfaced reason did not name the validation loop limit: $(cat "$out")"
  grep -F "fix rounds 2 exceeded bound 1" "$out" >/dev/null \
    || fail "the surfaced reason did not carry the recorded breach: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a limit stop was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || fail "the stale suppressor was not advanced on the limit surface"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the limit surface failed"
  grep -F "validation loop limit:" "$drain_out" >/dev/null \
    || fail "the durable queue record did not carry the limit reason"
  unset FM_FAKE_CREW_STATE
  pass "watcher: a limit-stopped crew surfaces once with the recorded breach in the durable wake reason"
}

test_watcher_surfaces_signal_validation_loop_limit() {
  local dir state fakebin out drain_out capture_file window ev pid
  dir=$(make_case vloop-signal-limit); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-signal-limit"
  printf 'quiet validation pane' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/signaled.meta"
  printf 'working: validating\n' > "$state/signaled.status"
  prime_status_seen "$state" "$state/signaled.status"
  ev="$dir/ev"
  ev_running "$ev" 01RUN running pending; FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" signaled "$ev" 1000
  ev_fixing  "$ev" 01RUN;                 FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" signaled "$ev" 1010
  ev_running "$ev" 01RUN running rerun;    FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" signaled "$ev" 1020
  ev_fixing  "$ev" 01RUN;                 FM_VLOOP_MAX_FIX_ROUNDS=1 fold "$state" signaled "$ev" 1030
  printf 'working: validating again\n' > "$state/signaled.status"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (fixing)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a signal limit"
  grep -F "validation loop limit:" "$out" >/dev/null \
    || fail "signal limit output did not name the validation loop limit: $(cat "$out")"
  grep -F "fix rounds 2 exceeded bound 1" "$out" >/dev/null \
    || fail "signal limit output lost the recorded breach: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after signal limit failed"
  grep -F "fix rounds 2 exceeded bound 1" "$drain_out" >/dev/null \
    || fail "signal limit queue record lost the recorded breach"
  unset FM_FAKE_CREW_STATE
  pass "watcher: a no-verb signal carries the validation-loop breach reason"
}

test_near_complete_continuation
test_repeated_finding_stop
test_unknown_state_stop
test_malformed_evidence_stop
test_malformed_journal_stop
test_journal_write_failure_stops_closed
test_stale_pipeline_evidence
test_recovery_handoff
test_fix_round_bound_semantics
test_stall_stop_and_progress_resume
test_coarse_evidence_does_not_enforce_stall
test_head_change_set_is_bounded
test_head_change_set_allows_authenticated_addition
test_head_transition_is_coherent
test_threshold_overrides_cannot_disable_bounds
test_watcher_surfaces_validation_loop_limit
test_watcher_surfaces_signal_validation_loop_limit
