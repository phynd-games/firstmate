#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain","summary":"...","silent":true|false}.
#     Legacy rows without `silent` remain valid and are treated as visible.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     Pi as an append-only merge note, emitted by the locked session-start
#     replay, or silently consumed there because `silent` is true. Records
#     above the cursor are "unread": the branch stored them but
#     did not reach either handoff. A crash inside Pi's delivery window after
#     cursor advancement does not auto-replay the row; it remains durable and
#     available through the main session's fm_branch_outcomes tool.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the merge note is appended to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after handing the records to Pi.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print visible unread records under a labeled
#     header into the locked startup digest, skip rows whose `silent` field is
#     true, and mark every unread row read. Prints nothing when nothing visible
#     is unread, so a home that never ran the branch stays silent. Run it only
#     when the session holds the lock (fm-session-start.sh owns the call site).
#   fm-branch-outcome.sh note-render --task <id>
#     Deterministic duplicate coalescing for ROUTINE captain-facing merge
#     notes, so a task main already owns cannot accumulate repeated no-change
#     notes at the captain's tail. Prints "render" when the note carries new
#     information, or "coalesce <reason>" when it duplicates the last rendered
#     note. New information is a change in the task's durable novelty
#     signature: its last captain-relevant status line (a new failure,
#     decision, or terminal result), its recorded pr=/pr_head= (a PR/CI
#     change), or its recorded validation-loop stop. Watcher-health alarms are
#     main-only by dispatch construction, so this gate can never suppress
#     them. The signature rendered last is persisted in
#     $STATE/.branch-note-sig-<task> (removed by teardown); "render" records
#     the new signature. Only the caller's captain-facing rendering consults
#     this - durable store appends, the read cursor, leases, and
#     captain-verdict escalation are untouched, and a caller that cannot run
#     this gate must keep rendering (fail toward visible, never toward
#     silence). The task "fleet" and unsanitizable task ids always render.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
LOCK="$STATE/.branch-outcomes.lock"

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] | unread | mark-read --through <seq> | list [--recent <n>] | startup-replay | note-render --task <id>" >&2
  exit 2
}

# The durable novelty signature note-render compares and records: the task's
# captain-relevant status lines, its recorded PR identity, and its recorded
# validation-loop stop. Plain multi-line text, compared verbatim.
note_novelty_signature() { # <task>
  local statusf metaf journal line status meta loop_stop
  statusf="$STATE/$1.status"
  metaf="$STATE/$1.meta"
  journal="$STATE/$1.validation-loop"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  printf 'captain-relevant-status='
  if [ -e "$statusf" ] || [ -L "$statusf" ]; then
    [ -f "$statusf" ] && [ ! -L "$statusf" ] || return 1
    status=$(cat "$statusf") || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      if status_is_captain_relevant "$line"; then printf '%s\n' "$line"; fi
    done <<< "$status"
  fi
  printf '\n'
  printf 'pr='
  if [ -e "$metaf" ] || [ -L "$metaf" ]; then
    [ -f "$metaf" ] && [ ! -L "$metaf" ] || return 1
    meta=$(cat "$metaf") || return 1
    printf '%s\n' "$meta" | grep '^pr=' | tail -1 | cut -d= -f2- | tr -d '\n' || true
  fi
  printf '\n'
  printf 'pr_head='
  if [ -n "${meta:-}" ]; then
    printf '%s\n' "$meta" | grep '^pr_head=' | tail -1 | cut -d= -f2- | tr -d '\n' || true
  fi
  printf '\n'
  printf 'loop-stop='
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
    loop_stop=$(cat "$journal") || return 1
    printf '%s\n' "$loop_stop" | grep '^stop_reason=' | tail -1 | cut -d= -f2- | tr -d '\n' || true
  fi
  printf '\n'
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  value=$(head -n 1 "$CURSOR" 2>/dev/null | tr -cd '0-9' || true)
  printf '%s\n' "${value:-0}"
}

last_seq() {
  local value
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  value=$(tail -n 1 "$STORE" 2>/dev/null | jq -er '
    select(type == "object")
    | select(
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
      )
    | select((.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor))
    | select((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
    | select((.task | type) == "string" and (.wake | type) == "string")
    | select((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
    | .seq
  ') || return 1
  printf '%s\n' "$value"
}

record_seq() { # <jsonl-line>
  printf '%s\n' "$1" | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'
}

print_unread() {
  local cursor seq line
  cursor=$(read_cursor)
  [ -s "$STORE" ] || return 0
  while IFS= read -r line; do
    seq=$(record_seq "$line")
    [ -n "$seq" ] || continue
    [ "$seq" -gt "$cursor" ] || continue
    printf '%s\n' "$line"
  done < "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor tmp
  cursor=$(read_cursor)
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store has a malformed final record" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" >> "$STORE"
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    case "$THROUGH" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    advance_cursor "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    [ -s "$STORE" ] || exit 0
    tail -n "$RECENT" "$STORE"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      VISIBLE=$(printf '%s\n' "$UNREAD" | jq -c 'select(.silent != true)')
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$UNREAD" | tail -n 1)")
      [ -z "$LAST" ] || advance_cursor "$LAST"
    fi
    fm_lock_release "$LOCK"
    ;;
  note-render)
    [ "${1:-}" = --task ] || usage
    TASK=${2:-}
    [ "$#" -eq 2 ] || usage
    [ -n "$TASK" ] || usage
    # Fleet-wide notes keep their own silent contract, and an id this gate
    # cannot safely use as a marker filename is never coalesced: both render.
    case "$TASK" in
      fleet|*[!A-Za-z0-9._-]*)
        printf 'render\n'
        exit 0
        ;;
    esac
    MARKER="$STATE/.branch-note-sig-$TASK"
    fm_lock_acquire_wait "$LOCK"
    if ! SIG=$(note_novelty_signature "$TASK"); then
      fm_lock_release "$LOCK"
      printf 'render\n'
      exit 0
    fi
    LAST=$(cat "$MARKER" 2>/dev/null || true)
    if [ -n "$LAST" ] && [ "$SIG" = "$LAST" ]; then
      fm_lock_release "$LOCK"
      printf 'coalesce duplicate routine outcome for %s: no new failure, decision, terminal result, PR/CI change, or validation-loop stop since the last rendered note\n' "$TASK"
      exit 0
    fi
    TMP=$(mktemp "$STATE/.branch-note-sig.XXXXXX")
    printf '%s\n' "$SIG" > "$TMP"
    mv -f -- "$TMP" "$MARKER"
    fm_lock_release "$LOCK"
    printf 'render\n'
    ;;
  *) usage ;;
esac
