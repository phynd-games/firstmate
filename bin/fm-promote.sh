#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, preserve only intended changes on the approved target
# base, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
PROMOTE_TASK_TMP=
PROMOTE_SHIP_TMP=
PROMOTE_BRIEF_BACKED_UP=0
promote_restore_scout_brief() {
  [ "$PROMOTE_BRIEF_BACKED_UP" -eq 1 ] || return 0
  rm -f -- "$PROMOTE_BRIEF" || return 1
  mv -- "$PROMOTE_BRIEF_BACKUP" "$PROMOTE_BRIEF" || return 1
  PROMOTE_BRIEF_BACKED_UP=0
}
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "$PROMOTE_TASK_TMP" ] || rm -f -- "$PROMOTE_TASK_TMP" 2>/dev/null || true
  [ -z "$PROMOTE_SHIP_TMP" ] || rm -f -- "$PROMOTE_SHIP_TMP" 2>/dev/null || true
  if [ "$status" -ne 0 ] && [ "$PROMOTE_BRIEF_BACKED_UP" -eq 1 ]; then
    promote_restore_scout_brief || true
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
"$FM_ROOT/bin/fm-guard.sh" || true
META="$STATE/$ID.meta"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

PROMOTE_WT=$(fmx_meta_get "$META" worktree || true)
[ -n "$PROMOTE_WT" ] && [ -d "$PROMOTE_WT" ] && [ ! -L "$PROMOTE_WT" ] || {
  echo "error: scout $ID has no valid worktree for its approved target base" >&2
  exit 1
}
PROMOTE_PROJECT=$(fmx_meta_get "$META" project || true)
[ -n "$PROMOTE_PROJECT" ] || PROMOTE_PROJECT=$(basename "$PROMOTE_WT")
PROMOTE_BRIEF="$DATA/$ID/brief.md"
PROMOTE_BRIEF_BACKUP="$DATA/$ID/.scout-brief.promote.$$"
PROMOTE_BRIEF_BACKED_UP=0
if [ -L "$PROMOTE_BRIEF" ]; then
  echo "error: scout $ID has an unsafe brief symlink" >&2
  exit 1
fi
PROMOTE_BASE_REF_COUNT=$(grep -c '^review_base_ref=' "$META" || true)
PROMOTE_BASE_SHA_COUNT=$(grep -c '^review_base_sha=' "$META" || true)
if [ "$PROMOTE_BASE_REF_COUNT" -ne 0 ] || [ "$PROMOTE_BASE_SHA_COUNT" -ne 0 ]; then
  PROMOTE_BASE=$(fm_pr_review_base_from_meta "$META") || {
    echo "error: scout $ID has an invalid approved target base" >&2
    exit 1
  }
elif [ -f "$DATA/$ID/brief.md" ] && [ ! -L "$DATA/$ID/brief.md" ]; then
  if PROMOTE_BASE=$(fm_pr_review_base_from_brief "$DATA/$ID/brief.md"); then
    :
  else
    PROMOTE_BASE_STATUS=$?
    [ "$PROMOTE_BASE_STATUS" -eq 2 ] || {
      echo "error: scout $ID has an invalid or ambiguous approved target base in its brief" >&2
      exit 1
    }
    PROMOTE_BASE=
  fi
else
  PROMOTE_BASE=
fi
if [ -z "$PROMOTE_BASE" ]; then
  echo "error: scout $ID has no approved target base; promotion refuses a moving default" >&2
  exit 1
fi
IFS="$(printf '\t')" read -r PROMOTE_BASE_REF PROMOTE_BASE_SHA <<EOF
$PROMOTE_BASE
EOF
PROMOTE_RESOLVED_BASE=$(fm_pr_review_base_resolve "$PROMOTE_WT" "$PROMOTE_BASE_REF" "$PROMOTE_BASE_SHA") || {
  echo "error: scout $ID's approved target base is unavailable" >&2
  exit 1
}
[ -n "$PROMOTE_RESOLVED_BASE" ] || { echo "error: scout $ID's approved target base is unavailable" >&2; exit 1; }
PROMOTE_BASE_REF=$PROMOTE_RESOLVED_BASE

if [ -e "$PROMOTE_BRIEF" ]; then
  [ -f "$PROMOTE_BRIEF" ] || {
    echo "error: scout $ID's brief is not a regular file" >&2
    exit 1
  }
  PROMOTE_TASK_TMP="$DATA/$ID/.scout-task.promote.$$"
  if ! awk '
    $0 == "# Task" { in_task = 1; next }
    in_task && ($0 == "# Setup" || $0 == "# Herdr isolation") { exit }
    in_task && $0 ~ /^Target-project approved base:/ { next }
    in_task { print }
  ' "$PROMOTE_BRIEF" > "$PROMOTE_TASK_TMP"; then
    rm -f -- "$PROMOTE_TASK_TMP"
    PROMOTE_TASK_TMP=
    echo "error: could not preserve scout $ID task context" >&2
    exit 1
  fi
  if [ ! -s "$PROMOTE_TASK_TMP" ]; then
    if ! grep -v '^Target-project approved base:' "$PROMOTE_BRIEF" > "$PROMOTE_TASK_TMP"; then
      rm -f -- "$PROMOTE_TASK_TMP"
      PROMOTE_TASK_TMP=
      echo "error: could not preserve scout $ID task context" >&2
      exit 1
    fi
  fi
  chmod 600 "$PROMOTE_TASK_TMP"
  if grep -Fqx '{TASK}' "$PROMOTE_TASK_TMP"; then
    rm -f -- "$PROMOTE_TASK_TMP"
    PROMOTE_TASK_TMP=
    echo "error: scout $ID's brief still contains the unfilled {TASK} placeholder" >&2
    exit 1
  fi
  mv -- "$PROMOTE_BRIEF" "$PROMOTE_BRIEF_BACKUP"
  PROMOTE_BRIEF_BACKED_UP=1
fi
if ! FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
  FM_STATE_OVERRIDE="$STATE" "$FM_ROOT/bin/fm-brief.sh" "$ID" "$PROMOTE_PROJECT" \
  --mode "$MODE" >/dev/null; then
  promote_restore_scout_brief || true
  echo "error: could not install the ship brief for promoted scout $ID" >&2
  exit 1
fi
if [ -n "$PROMOTE_TASK_TMP" ]; then
  PROMOTE_SHIP_TMP="$DATA/$ID/.ship-brief.promote.$$"
  if ! awk -v task_file="$PROMOTE_TASK_TMP" '
    $0 == "{TASK}" {
      found = 1
      while ((getline line < task_file) > 0) print line
      close(task_file)
      next
    }
    { print }
    END { if (!found) exit 1 }
  ' "$PROMOTE_BRIEF" > "$PROMOTE_SHIP_TMP"; then
    rm -f -- "$PROMOTE_SHIP_TMP" "$PROMOTE_BRIEF"
    promote_restore_scout_brief || true
    echo "error: could not restore scout $ID task context in the ship brief" >&2
    exit 1
  fi
  mv -- "$PROMOTE_SHIP_TMP" "$PROMOTE_BRIEF"
  PROMOTE_SHIP_TMP=
  rm -f -- "$PROMOTE_TASK_TMP"
  PROMOTE_TASK_TMP=
fi
if ! printf 'Target-project approved base: ref=%s; sha=%s\n' \
  "$PROMOTE_BASE_REF" "$PROMOTE_BASE_SHA" >> "$PROMOTE_BRIEF"; then
  promote_restore_scout_brief || true
  echo "error: could not record the approved target base in promoted scout $ID's brief" >&2
  exit 1
fi
TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^review_base_ref=' -e '^review_base_sha=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "review_base_ref=$PROMOTE_BASE_REF"
  echo "review_base_sha=$PROMOTE_BASE_SHA"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$TMP"
if ! mv "$TMP" "$META"; then
  if promote_restore_scout_brief; then
    echo "error: could not publish promoted scout $ID metadata; the scout brief was restored" >&2
  else
    echo "error: could not publish promoted scout $ID metadata or restore the scout brief; recovery backup remains at $PROMOTE_BRIEF_BACKUP" >&2
  fi
  exit 1
fi
TMP=
PROMOTE_BRIEF_BACKED_UP=0
rm -f -- "$PROMOTE_BRIEF_BACKUP" 2>/dev/null || true
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; preserve only intended changes on approved base $PROMOTE_BASE_SHA; do not reset to a moving default branch; create branch fm/$ID; implement; report done>'"

promote_print_rechain_hint() {
  local consent_home=$1 work_home=$2 task_id=$3 id prefix
  prefix=
  [ "$consent_home" = "$FM_HOME" ] || prefix="FM_HOME=$(printf '%q' "$consent_home") "
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(fm_pf_registry_get "$consent_home/state" "$id" state)" = delivered ] || continue
    echo "next: ${prefix}bin/fm-public-followup.sh rechain <new-obligation-id> --from $id --work-home $work_home --work-id $task_id --expected pr-merged"
  done <<EOF
$(fm_pf_registry_ids_for_work "$consent_home/state" "$work_home" "$task_id")
EOF
}

promote_canonical_home() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  CDPATH='' cd -- "$home" 2>/dev/null && pwd -P
}

promote_resolve_primary_home() {
  local parent=$1 child=$2 mate_id=$3 parent_meta registry meta_home
  fm_pf_home_id_valid "secondmate:$mate_id" || return 1
  parent=$(promote_canonical_home "$parent") || return 1
  child=$(promote_canonical_home "$child") || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$mate_id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fmx_meta_get "$parent_meta" kind)" = secondmate ] || return 1
  meta_home=$(fmx_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$parent/data/secondmates.md"
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key \
    "$mate_id" "$child" || return 1
  printf '%s\n' "$parent"
}

promote_warn_parent_unresolved() {
  echo "warning: could not resolve the consent-holding parent home for secondmate $1; promotion succeeded, but any open public loop must be inspected and rechained from the parent." >&2
}

if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
  PROMOTE_MATE_ID=$(sed -n '1p' "$FM_HOME/.fm-secondmate-home" 2>/dev/null || true)
  PROMOTE_PARENT_RECORD=absent
  PROMOTE_PARENT_ROUTE=
  PROMOTE_DURABLE_PARENT=
  if [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ]; then
    PROMOTE_PARENT_RECORD=invalid
    if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent"; then
      PROMOTE_PARENT_RECORD=valid
      PROMOTE_PARENT_ROUTE=$FM_SECONDMATE_PARENT_ROUTE
      PROMOTE_DURABLE_PARENT=$FM_SECONDMATE_PARENT_HOME
    fi
  fi
  if [ "$PROMOTE_PARENT_RECORD" = invalid ]; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  elif [ "$PROMOTE_PARENT_ROUTE" = local ]; then
    PROMOTE_PARENT_CANDIDATE=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$PROMOTE_DURABLE_PARENT}
    PROMOTE_PARENT_BINDINGS_MATCH=1
    if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
      PROMOTE_LIVE_PARENT=$(promote_canonical_home "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      PROMOTE_RECORDED_PARENT=$(promote_canonical_home "$PROMOTE_DURABLE_PARENT") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
          && [ "$PROMOTE_LIVE_PARENT" != "$PROMOTE_RECORDED_PARENT" ]; then
        PROMOTE_PARENT_BINDINGS_MATCH=0
      fi
    fi
    if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
        && PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$PROMOTE_PARENT_CANDIDATE" "$FM_HOME" "$PROMOTE_MATE_ID"); then
      if fm_pf_relay_active "$PROMOTE_PARENT"; then
        promote_print_rechain_hint "$PROMOTE_PARENT" "secondmate:$PROMOTE_MATE_ID" "$ID"
      fi
    else
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ "$PROMOTE_PARENT_ROUTE" = remote ]; then
    PROMOTE_HOME_ENV_TOKEN=
    if [ -f "$FM_HOME/.env" ]; then
      PROMOTE_HOME_ENV_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$FM_HOME/.env")
    fi
    if [ -n "$PROMOTE_HOME_ENV_TOKEN" ]; then
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
    if fm_pf_relay_active "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME"; then
      if PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME" "$FM_HOME" "$PROMOTE_MATE_ID"); then
        promote_print_rechain_hint "$PROMOTE_PARENT" "secondmate:$PROMOTE_MATE_ID" "$ID"
      else
        promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
      fi
    fi
  elif fm_pf_relay_active "$FM_HOME"; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  fi
elif fm_pf_relay_active "$FM_HOME"; then
  promote_print_rechain_hint "$FM_HOME" main "$ID"
fi
