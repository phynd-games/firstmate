#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${FM_TEST_TMUX_LOG:?}"\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_TEST_TMUX_LOG="$home/tmux.log" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

test_ship_spawn_rejects_missing_base_before_endpoint_creation() {
  local rec home proj fakebin out status
  rec=$(make_home base-preflight)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" base-preflight-c1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" base-preflight-c1 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn without an approved base should exit non-zero"
  assert_contains "$out" "brief $home/data/base-preflight-c1/brief.md has no approved target base" \
    "missing-base refusal did not identify the brief"
  [ ! -s "$home/tmux.log" ] || fail "missing-base validation created a backend endpoint before refusing"
  pass "fm-spawn: missing approved bases fail before endpoint creation"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status proj wt base_sha local_proj local_wt local_base
  home="$TMP_ROOT/promote/home"
  proj="$TMP_ROOT/promote/proj"
  wt="$TMP_ROOT/promote/wt"
  mkdir -p "$home/state" "$home/data/promote-d1"
  fm_git_worktree "$proj" "$wt" "task-promote-d1"
  base_sha=$(git -C "$wt" rev-parse HEAD)
  printf 'Scout brief.\n' > "$home/data/promote-d1/brief.md"
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=%s\n' "$wt" > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing merge posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without an approved target base should exit non-zero"
  assert_contains "$out" "has no approved target base" "promote did not refuse a missing approved target base"
  assert_grep 'kind=scout' "$meta" "missing-base promotion changed the task record"

  printf 'Target-project approved base: ref=main; sha=%s\n' "$base_sha" >> "$home/data/promote-d1/brief.md"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'review_base_ref=main' "$meta" "promotion did not freeze the approved target base ref"
  assert_grep "review_base_sha=$base_sha" "$meta" "promotion did not freeze the approved target base SHA"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided merge posture"
  assert_grep '# Required PR self-review' "$home/data/promote-d1/brief.md" "promotion did not install the ship self-review contract"
  assert_grep 'Firstmate substrate launch SHA:' "$home/data/promote-d1/brief.md" "promotion did not install the substrate launch evidence"
  assert_grep 'Target-project approved base: ref=main;' "$home/data/promote-d1/brief.md" "promotion did not record the approved base in the ship brief"
  assert_contains "$(cat "$home/data/promote-d1/brief.md")" "Scout brief." "promotion did not preserve the scout task context"
  [ "$(grep -c '^Target-project approved base:' "$home/data/promote-d1/brief.md")" = 1 ] \
    || fail "promotion emitted more than one approved target base"
  assert_not_contains "$out" 'reset to a clean default-branch base' "promotion still instructed a default-base reset"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"

  git -C "$proj" branch approved-base "$base_sha"
  git -C "$proj" push --quiet origin approved-base
  git -C "$wt" update-ref -d refs/remotes/origin/approved-base
  mkdir -p "$home/data/promote-fetch"
  printf 'Scout brief for fetched base.\nTarget-project approved base: ref=origin/approved-base; sha=%s\n' \
    "$base_sha" > "$home/data/promote-fetch/brief.md"
  fm_write_meta "$home/state/promote-fetch.meta" \
    "window=fm-promote-fetch" "kind=scout" "worktree=$wt"
  [ "$(git -C "$wt" show-ref --verify --quiet refs/remotes/origin/approved-base; echo $?)" = 1 ] \
    || fail "promotion fixture unexpectedly had the approved remote-tracking ref"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-fetch --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion should fetch an approved base absent from the scout worktree"
  assert_grep 'kind=ship' "$home/state/promote-fetch.meta" "fetched-base promotion did not complete"
  assert_grep 'review_base_ref=origin/approved-base' "$home/state/promote-fetch.meta" \
    "fetched-base promotion changed the approved ref"
  assert_grep 'Target-project approved base: ref=origin/approved-base;' \
    "$home/data/promote-fetch/brief.md" \
    "fetched-base promotion did not persist the resolved approved ref"

  local_proj="$TMP_ROOT/promote/local-proj"
  local_wt="$TMP_ROOT/promote/local-wt"
  fm_git_init_commit "$local_proj"
  git -C "$local_proj" branch approved-local
  git -C "$local_proj" worktree add --quiet -b task-promote-local "$local_wt"
  local_base=$(git -C "$local_wt" rev-parse approved-local)
  mkdir -p "$home/data/promote-local"
  printf 'Scout brief for local base.\nTarget-project approved base: ref=approved-local; sha=%s\n' \
    "$local_base" > "$home/data/promote-local/brief.md"
  fm_write_meta "$home/state/promote-local.meta" \
    "window=fm-promote-local" "kind=scout" "worktree=$local_wt"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-local --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion should accept a matching local approved base without origin"
  assert_grep 'kind=ship' "$home/state/promote-local.meta" "local-base promotion did not complete"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

test_promote_strips_base_metadata_from_preserved_task() {
  local home meta brief out status proj wt base_sha
  home="$TMP_ROOT/promote-task-base/home"
  proj="$TMP_ROOT/promote-task-base/proj"
  wt="$TMP_ROOT/promote-task-base/wt"
  mkdir -p "$home/state" "$home/data/promote-task-base"
  fm_git_worktree "$proj" "$wt" "task-promote-task-base"
  base_sha=$(git -C "$wt" rev-parse HEAD)
  brief="$home/data/promote-task-base/brief.md"
  meta="$home/state/promote-task-base.meta"
  {
    printf 'You are a crewmate.\n\n# Task\nPreserve this task context.\n'
    printf 'Target-project approved base: ref=main; sha=%s\n\n# Setup\n' "$base_sha"
  } > "$brief"
  printf 'window=fm-promote-task-base\nkind=scout\nworktree=%s\n' "$wt" > "$meta"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" \
    promote-task-base --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion with task-local base metadata should succeed"
  assert_contains "$out" "promoted promote-task-base to ship" \
    "task-local base promotion did not complete"
  assert_contains "$(cat "$brief")" "Preserve this task context." \
    "task-local base promotion lost task context"
  [ "$(grep -c '^Target-project approved base:' "$brief")" = 1 ] \
    || fail "task-local base promotion emitted duplicate approved-base metadata"
  assert_grep "Target-project approved base: ref=main; sha=$base_sha" "$brief" \
    "task-local base promotion did not emit the canonical approved base"
  pass "fm-promote: preserved task content excludes duplicate base metadata"
}

test_promote_rejects_unfilled_scout_without_mutation() {
  local home meta brief out status proj wt base_sha
  home="$TMP_ROOT/promote-unfilled/home"
  proj="$TMP_ROOT/promote-unfilled/proj"
  wt="$TMP_ROOT/promote-unfilled/wt"
  mkdir -p "$home/state" "$home/data/promote-unfilled"
  fm_git_worktree "$proj" "$wt" "task-promote-unfilled"
  base_sha=$(git -C "$wt" rev-parse HEAD)
  brief="$home/data/promote-unfilled/brief.md"
  meta="$home/state/promote-unfilled.meta"
  {
    printf 'You are a crewmate.\n\n# Task\n{TASK}\n\n# Setup\n'
    printf 'Target-project approved base: ref=main; sha=%s\n' "$base_sha"
  } > "$brief"
  printf 'window=fm-promote-unfilled\nkind=scout\nworktree=%s\n' "$wt" > "$meta"
  cp "$brief" "$brief.before"
  cp "$meta" "$meta.before"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" \
    promote-unfilled --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion of an unfilled scout brief should fail"
  assert_contains "$out" "unfilled {TASK} placeholder" \
    "unfilled scout refusal did not identify the placeholder"
  cmp -s "$brief.before" "$brief" || fail "unfilled promotion changed the scout brief"
  cmp -s "$meta.before" "$meta" || fail "unfilled promotion changed task metadata"
  [ -z "$(find "$home/data/promote-unfilled" -name '.scout-brief.promote.*' -print -quit)" ] \
    || fail "unfilled promotion left a brief backup behind"
  pass "fm-promote: unfilled scout placeholders fail before mutation"
}

test_promote_restores_scout_when_metadata_publication_fails() {
  local home meta brief out status proj wt base_sha fakebin real_mv
  home="$TMP_ROOT/promote-rollback/home"
  proj="$TMP_ROOT/promote-rollback/proj"
  wt="$TMP_ROOT/promote-rollback/wt"
  fakebin="$TMP_ROOT/promote-rollback/fakebin"
  mkdir -p "$home/state" "$home/data/promote-rollback" "$fakebin"
  fm_git_worktree "$proj" "$wt" "task-promote-rollback"
  base_sha=$(git -C "$wt" rev-parse HEAD)
  brief="$home/data/promote-rollback/brief.md"
  meta="$home/state/promote-rollback.meta"
  {
    printf 'Scout task context.\n'
    printf 'Target-project approved base: ref=main; sha=%s\n' "$base_sha"
  } > "$brief"
  printf 'window=fm-promote-rollback\nkind=scout\nworktree=%s\n' "$wt" > "$meta"
  cp "$brief" "$brief.before"
  cp "$meta" "$meta.before"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/bin/sh
last=
for arg do last=$arg; done
if [ "$last" = "${FM_TEST_PROMOTE_META:-}" ] && [ "${FM_TEST_FAIL_PROMOTE_META_MV:-0}" = 1 ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_REAL_MV="$real_mv" FM_TEST_PROMOTE_META="$meta" \
    FM_TEST_FAIL_PROMOTE_META_MV=1 PATH="$fakebin:$PATH" "$PROMOTE" \
    promote-rollback --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "metadata publication failure should fail promotion"
  assert_contains "$out" "the scout brief was restored" \
    "metadata publication failure did not report brief restoration"
  cmp -s "$brief.before" "$brief" || fail "metadata failure did not restore the scout brief"
  cmp -s "$meta.before" "$meta" || fail "metadata failure changed the scout metadata"
  [ -z "$(find "$home/data/promote-rollback" -name '.scout-brief.promote.*' -print -quit)" ] \
    || fail "metadata failure left a brief backup behind"
  pass "fm-promote: metadata publication failure rolls back the brief"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promote_strips_base_metadata_from_preserved_task
test_promote_rejects_unfilled_scout_without_mutation
test_promote_restores_scout_when_metadata_publication_fails
test_project_mode_maps_the_conditional_policy
echo "# all fm-task-delivery tests passed"
