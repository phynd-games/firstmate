#!/usr/bin/env bash
# fm-operational-input.sh - canonical Firstmate operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
#
# The landed U+2063 + "FIRSTMATE_OP: " prefix is permanent compatibility.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-firstmate routing
# marker remains a current compatibility carrier because already-running
# secondmates have its leading label in their charter context.
#
# CLI:
#   fm-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   fm-operational-input.sh kind           # current input on stdin, kind stdout
#   fm-operational-input.sh classify       # current or legacy input on stdin
#   fm-operational-input.sh body           # current input body on stdin
#   fm-operational-input.sh inspect        # structural trust report on stdin
#   fm-operational-input.sh schema         # versioned inspection JSON Schema
#   fm-operational-input.sh --help
#
# Current bodies are non-empty and bounded to the schema-owned maximum.
# Inspection binds exact body bytes with SHA-256 but explicitly grants no
# authorization and verifies no provenance; structure is never authority.
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

FM_OPERATIONAL_MARK=$'\xE2\x81\xA3'
FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "
FM_OPERATIONAL_VERSION=v1
FM_OPERATIONAL_SCHEMA=firstmate.agent-interchange.v1
FM_OPERATIONAL_MAX_BODY_BYTES=1048576
FM_OPERATIONAL_HEADER_PREFIX="${FM_OPERATIONAL_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome'

# Compatibility name retained for the away-mode owner and its tests.
# shellcheck disable=SC2034 # Public source-library variable used by callers.
FM_INJECT_MARK=$FM_OPERATIONAL_MARK

# The from-firstmate carrier stays byte-compatible with live secondmate charter
# context while this owner supplies its construction and structural kind.
FM_FROMFIRST_LABEL='[fm-from-firstmate]'
FM_FROMFIRST_SEPARATOR=$FM_OPERATIONAL_MARK
FM_FROMFIRST_MARK="${FM_FROMFIRST_LABEL}${FM_FROMFIRST_SEPARATOR}"

fm_operational_kind_is_current() {  # <kind>
  case " $FM_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_body_byte_count() {  # <body> <result-var>
  local body=${1-} result_var=${2-} measured LC_ALL
  [ -n "$result_var" ] || return 2
  LC_ALL=C
  measured=${#body}
  printf -v "$result_var" '%s' "$measured"
}

fm_operational_body_is_valid() {  # <body>
  local body=${1-} count
  [ -n "$body" ] || return 1
  fm_operational_body_byte_count "$body" count || return 1
  [ "$count" -le "$FM_OPERATIONAL_MAX_BODY_BYTES" ]
}

fm_operational_input_encode() {  # <generic-kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  fm_operational_kind_is_current "$kind" || return 2
  fm_operational_body_is_valid "$body" || return 2
  printf -v "$result_var" '%s%s: %s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}

fm_operational_input_construct() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && [ -n "$body" ] || return 2
  if [ "$kind" = from-firstmate ]; then
    fm_message_mark_from_firstmate "$body" "$result_var"
    return
  fi
  fm_operational_input_encode "$kind" "$body" "$result_var"
}

fm_operational_generic_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} remainder parsed_kind body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$FM_OPERATIONAL_HEADER_PREFIX"*': '?*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$FM_OPERATIONAL_HEADER_PREFIX"}
  parsed_kind=${remainder%%': '*}
  fm_operational_kind_is_current "$parsed_kind" || return 1
  body=${remainder#"${parsed_kind}: "}
  [ "$body" != "$remainder" ] || return 1
  fm_operational_body_is_valid "$body" || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

fm_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} current_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    printf -v "$result_var" '%s' "$current_kind"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      fm_operational_body_is_valid "${message#"$FM_FROMFIRST_MARK"}" || return 1
      printf -v "$result_var" '%s' from-firstmate
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    parsed_body=${message#"${FM_OPERATIONAL_HEADER_PREFIX}${current_kind}: "}
    printf -v "$result_var" '%s' "$parsed_body"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      parsed_body=${message#"$FM_FROMFIRST_MARK"}
      fm_operational_body_is_valid "$parsed_body" || return 1
      printf -v "$result_var" '%s' "$parsed_body"
      return 0
      ;;
  esac
  return 1
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup.
FM_LEGACY_SESSIONSTART='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
FM_LEGACY_WATCHER_PREFIX='FIRSTMATE WATCHER WAKE: '
FM_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.'
FM_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n'
FM_LEGACY_AWAY_PREFIX="${FM_OPERATIONAL_MARK}Supervisor escalate ("

fm_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2

  # PR 899 landed an untyped FIRSTMATE_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$message" in
    "$FM_OPERATIONAL_PREFIX"?*)
      printf -v "$result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$message" = "$FM_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi
  case "$message" in
    "$FM_LEGACY_AWAY_PREFIX"*)
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
    "$FM_LEGACY_WATCHER_PREFIX"*"$FM_LEGACY_WATCHER_SUFFIX")
      [ "${#message}" -gt "$(( ${#FM_LEGACY_WATCHER_PREFIX} + ${#FM_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$FM_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_classify() {  # <message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  # A malformed current-version envelope never downgrades into the broad
  # pre-version FIRSTMATE_OP compatibility parser.
  case "$message" in
    "$FM_OPERATIONAL_PREFIX"v*) return 1 ;;
  esac
  if fm_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

fm_message_from_firstmate() {  # <message>
  local kind
  fm_operational_input_kind "${1-}" kind && [ "$kind" = from-firstmate ]
}

fm_message_mark_from_firstmate() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if fm_message_from_firstmate "$message"; then
    transformed=$message
  else
    case "$message" in "$FM_FROMFIRST_MARK"*) return 2 ;; esac
    fm_operational_body_is_valid "$message" || return 2
    transformed="${FM_FROMFIRST_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}

fm_operational_sha256_text() {  # <text> <result-var>
  local text=${1-} result_var=${2-} calculated_digest
  [ -n "$result_var" ] || return 2
  if command -v shasum >/dev/null 2>&1; then
    calculated_digest=$(printf '%s' "$text" | shasum -a 256 2>/dev/null | awk '{print $1}') || return 2
  elif command -v sha256sum >/dev/null 2>&1; then
    calculated_digest=$(printf '%s' "$text" | sha256sum 2>/dev/null | awk '{print $1}') || return 2
  else
    return 2
  fi
  case "$calculated_digest" in ''|*[!0-9a-f]*) return 2 ;; esac
  [ "${#calculated_digest}" -eq 64 ] || return 2
  printf -v "$result_var" '%s' "$calculated_digest"
}

fm_operational_input_inspect() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} kind body byte_count digest rendered
  [ -n "$result_var" ] || return 2
  fm_operational_input_kind "$message" kind || return 1
  fm_operational_input_body "$message" body || return 1
  fm_operational_body_byte_count "$body" byte_count || return 2
  fm_operational_sha256_text "$body" digest || return 2
  rendered=$(printf '{"authorization_granted":false,"body_byte_count":%s,"body_sha256":"%s","kind":"%s","provenance_evidence":"body-sha256-only","provenance_verified":false,"schema":"%s","structurally_valid":true,"wire_version":"%s"}' \
    "$byte_count" "$digest" "$kind" "$FM_OPERATIONAL_SCHEMA" "$FM_OPERATIONAL_VERSION") || return 2
  printf -v "$result_var" '%s' "$rendered"
}

fm_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value byte_count
  [ -n "$result_var" ] || return 2
  value=$(head -c "$((FM_OPERATIONAL_MAX_BODY_BYTES + 1))" && printf x) || return 2
  value=${value%x}
  fm_operational_body_byte_count "$value" byte_count || return 2
  [ "$byte_count" -le "$FM_OPERATIONAL_MAX_BODY_BYTES" ] || return 2
  printf -v "$result_var" '%s' "$value"
}

fm_operational_usage() {
  cat <<'EOF'
Usage:
  bin/fm-operational-input.sh encode <kind>  # body on stdin
  bin/fm-operational-input.sh kind           # current input on stdin
  bin/fm-operational-input.sh classify       # current or legacy input on stdin
  bin/fm-operational-input.sh body           # current input on stdin
  bin/fm-operational-input.sh inspect        # structural trust report on stdin
  bin/fm-operational-input.sh schema         # versioned inspection JSON Schema

Current construction kinds:
  session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief
  branch-outcome

The from-firstmate kind uses its established live-charter-compatible carrier.
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} input output script_dir
  case "$command" in
    -h|--help|help)
      fm_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_construct "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    inspect)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      if fm_operational_input_inspect "$input" output; then
        printf '%s\n' "$output"
      else
        return $?
      fi
      ;;
    schema)
      [ "$#" -eq 1 ] || return 2
      script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || return 2
      cat "$script_dir/../schemas/firstmate-agent-interchange-v1.json" || return 2
      ;;
    *)
      fm_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_operational_main "$@"
  exit $?
fi
