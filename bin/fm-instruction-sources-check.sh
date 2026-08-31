#!/usr/bin/env bash
# Validate Firstmate's canonical instruction source and harness bridges.
#
# Usage:
#   bin/fm-instruction-sources-check.sh [--root <repo>]
#
# .agents/skills/ is the only tracked agent-loaded skill source.
# Harness skill directories are symlink bridges to that source.
# AGENTS.md owns policy; CLAUDE.md and GROK_BOT.md contain only their supported
# harness adapters.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

usage() {
  printf '%s\n' \
    'Usage: bin/fm-instruction-sources-check.sh [--root <repo>]' \
    'Validate canonical Firstmate instruction and harness skill bridges.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ROOT=$(cd "$2" 2>/dev/null && pwd -P) || {
        printf 'error: root is not an existing directory: %s\n' "$2" >&2
        exit 1
      }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  printf 'error: instruction sources: %s\n' "$1" >&2
  exit 1
}

canonical_skills="$ROOT/.agents/skills"
[ -d "$canonical_skills" ] && [ ! -L "$canonical_skills" ] \
  || fail '.agents/skills must be a real directory'

for bridge in .claude/skills .grok/skills; do
  path="$ROOT/$bridge"
  [ -L "$path" ] || fail "$bridge must be a symlink to ../.agents/skills"
  [ "$(readlink "$path")" = '../.agents/skills' ] \
    || fail "$bridge must point to ../.agents/skills"
  [ -d "$path" ] || fail "$bridge points to a dangling or non-directory target"
done

agents="$ROOT/AGENTS.md"
[ -f "$agents" ] && [ ! -L "$agents" ] \
  || fail 'AGENTS.md must be a real regular file'

claude="$ROOT/CLAUDE.md"
[ -f "$claude" ] && [ ! -L "$claude" ] \
  || fail 'CLAUDE.md must be a real @AGENTS.md pointer file'
claude_lines=$(wc -l < "$claude" | tr -d '[:space:]')
[ "$claude_lines" = 2 ] \
  || fail 'CLAUDE.md must contain only its canonical two-line adapter'
{ IFS= read -r comment && IFS= read -r import && [ -z "${comment#<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->}" ] && [ "$import" = '@AGENTS.md' ]; } < "$claude" \
  || fail 'CLAUDE.md must use Claude Code @AGENTS.md import'

grok="$ROOT/GROK_BOT.md"
[ -f "$grok" ] && [ ! -L "$grok" ] \
  || fail 'GROK_BOT.md must be a real Grok Bot adapter file'
grok_expected=$(cat <<'EOF'
<!-- Grok Bot uses file attachments, not repository instruction imports. -->
Attach `AGENTS.md` to this Bot profile before use.
Treat attached `AGENTS.md` as canonical Firstmate instructions.
This file is only a Grok Bot bootstrap adapter and contains no Firstmate policy.
EOF
)
[ "$(cat "$grok")" = "$grok_expected" ] \
  || fail 'GROK_BOT.md must remain the thin attachment adapter, not a policy copy or dangling pointer'

printf 'fm-instruction-sources-check: ok canonical=.agents/skills claude=pointer grok=attachment-adapter\n'
