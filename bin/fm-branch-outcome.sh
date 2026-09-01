#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"adjudicate"|"captain","summary":"...","silent":true|false}
#     plus an optional "repeat":N on a coalesced row (see below).
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
#   fm-branch-outcome.sh append --task <id> --verdict routine|adjudicate|captain \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#     REPEAT COALESCING. An outcome whose task, verdict, and summary are
#     byte-identical to the immediately preceding row is the same outcome said
#     again, not a second thing that happened. It is still appended - the store
#     stays append-only and the evidence stays complete - but it carries
#     "repeat":N counting how many times in a row it has been said, and the
#     printed line becomes "<seq> repeat=<N>". The caller uses that to keep a
#     repeated captain outcome OFF the captain: the same finding relayed a
#     second time is a supervision failure to act, not news, so the branch
#     extension routes it to main to handle autonomously instead of opening
#     another captain turn. Nothing is lost: the row is durable either way.
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
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
LOCK="$STATE/.branch-outcomes.lock"

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|adjudicate|captain --summary <text> [--wake <text>] [--silent true|false] | unread | mark-read --through <seq> | list [--recent <n>] | startup-replay" >&2
  exit 2
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
        or (keys == ["epoch", "repeat", "seq", "silent", "summary", "task", "verdict", "wake"]
            and (.silent | type) == "boolean"
            and (.repeat | type) == "number" and .repeat >= 2 and .repeat == (.repeat | floor))
      )
    | select((.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor))
    | select((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
    | select((.task | type) == "string" and (.wake | type) == "string")
    | select((.summary | type) == "string" and (.verdict == "routine" or .verdict == "adjudicate" or .verdict == "captain"))
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
    case "$VERDICT" in routine|adjudicate|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store has a malformed final record" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    # Repeat detection reads the previous row through jq rather than comparing
    # the formatted line, so a difference in wake text or silence - neither of
    # which changes WHAT was reported - does not mask a repeat.
    REPEAT=0
    if [ -s "$STORE" ]; then
      if PREV=$(tail -n 1 "$STORE" | jq -er '[.task, .verdict, .summary, (.repeat // 1)] | @tsv' 2>/dev/null); then
        PREV_TASK=$(printf '%s' "$PREV" | cut -f1)
        PREV_VERDICT=$(printf '%s' "$PREV" | cut -f2)
        PREV_SUMMARY=$(printf '%s' "$PREV" | cut -f3)
        PREV_REPEAT=$(printf '%s' "$PREV" | cut -f4)
        if [ "$PREV_TASK" = "$TASK" ] && [ "$PREV_VERDICT" = "$VERDICT" ] \
          && [ "$PREV_SUMMARY" = "$SUMMARY" ]; then
          case "$PREV_REPEAT" in
            ''|*[!0-9]*) PREV_REPEAT=1 ;;
          esac
          REPEAT=$(( PREV_REPEAT + 1 ))
        fi
      fi
    fi
    if [ "$REPEAT" -ge 2 ]; then
      printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"repeat":%s}\n' \
        "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
        "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$REPEAT" >> "$STORE"
    else
      printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s}\n' \
        "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
        "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" >> "$STORE"
    fi
    fm_lock_release "$LOCK"
    if [ "$REPEAT" -ge 2 ]; then
      printf '%s repeat=%s\n' "$SEQ" "$REPEAT"
    else
      printf '%s\n' "$SEQ"
    fi
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
  *) usage ;;
esac
