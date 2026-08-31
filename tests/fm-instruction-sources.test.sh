#!/usr/bin/env bash
# Regression tests for canonical Firstmate instructions and harness skill bridges.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-instruction-sources-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-instruction-sources)

write_fixture() {
  local repo=$1
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.grok"
  printf '%s\n' '---' 'name: example' 'description: fixture' '---' > "$repo/.agents/skills/example/SKILL.md"
  ln -s ../.agents/skills "$repo/.claude/skills"
  ln -s ../.agents/skills "$repo/.grok/skills"
  printf '%s\n' '# Canonical instructions' > "$repo/AGENTS.md"
  printf '%s\n' \
    '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->' \
    '@AGENTS.md' > "$repo/CLAUDE.md"
  printf '%s\n' \
    '<!-- Grok Bot uses file attachments, not repository instruction imports. -->' \
    "Attach \`AGENTS.md\` to this Bot profile before use." \
    "Treat attached \`AGENTS.md\` as canonical Firstmate instructions." \
    'This file is only a Grok Bot bootstrap adapter and contains no Firstmate policy.' \
    > "$repo/GROK_BOT.md"
}

run_expect_failure() {
  local expected=$1 root=$2 out rc
  set +e
  out=$($CHECK --root "$root" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected instruction-source check failure containing '$expected'"
  assert_contains "$out" "$expected" "instruction-source failure did not identify '$expected'"
}

test_repository_sources_pass() {
  local out
  out=$($CHECK)
  assert_contains "$out" 'canonical=.agents/skills' \
    'canonical skill source was not reported'
  assert_contains "$out" 'claude=pointer' \
    'Claude pointer was not reported'
  assert_contains "$out" 'grok=attachment-adapter' \
    'Grok adapter was not reported'
  [ -f "$ROOT/.agents/skills/ahoy/SKILL.md" ] \
    || fail 'canonical skill source is missing a tracked skill'
  [ -f "$ROOT/.claude/skills/ahoy/SKILL.md" ] \
    || fail 'Claude skill bridge does not resolve canonical skill source'
  [ -f "$ROOT/.grok/skills/ahoy/SKILL.md" ] \
    || fail 'Grok skill bridge does not resolve canonical skill source'
  pass 'canonical skill source and Claude/Grok instruction bridges pass'
}

test_duplicate_skill_entrypoint_fails() {
  local repo="$TMP_ROOT/duplicate-skill"
  write_fixture "$repo"
  rm "$repo/.grok/skills"
  mkdir -p "$repo/.grok/skills"
  cp "$repo/.agents/skills/example/SKILL.md" "$repo/.grok/skills/SKILL.md"
  run_expect_failure '.grok/skills must be a symlink' "$repo"
  pass 'duplicate Grok skill directory is rejected'
}

test_dangling_skill_entrypoint_fails() {
  local repo="$TMP_ROOT/dangling-skill"
  write_fixture "$repo"
  rm "$repo/.claude/skills"
  ln -s ../missing-skills "$repo/.claude/skills"
  run_expect_failure '.claude/skills must point to ../.agents/skills' "$repo"
  pass 'dangling Claude skill bridge is rejected'
}

test_duplicate_instruction_entrypoint_fails() {
  local repo="$TMP_ROOT/duplicate-instructions"
  write_fixture "$repo"
  cp "$repo/AGENTS.md" "$repo/GROK_BOT.md"
  run_expect_failure 'GROK_BOT.md must remain the thin attachment adapter' "$repo"
  pass 'duplicated Grok instruction policy is rejected'
}

test_dangling_instruction_import_fails() {
  local repo="$TMP_ROOT/dangling-instructions"
  write_fixture "$repo"
  printf '%s\n' \
    '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->' \
    '@MISSING.md' > "$repo/CLAUDE.md"
  run_expect_failure 'CLAUDE.md must use Claude Code @AGENTS.md import' "$repo"
  pass 'dangling Claude instruction import is rejected'
}

test_unterminated_instruction_content_fails() {
  local repo="$TMP_ROOT/unterminated-instructions"
  write_fixture "$repo"
  printf '%s' 'unexpected trailing content' >> "$repo/CLAUDE.md"
  run_expect_failure 'CLAUDE.md must contain only its canonical two-line adapter' "$repo"
  pass 'unterminated Claude trailing content is rejected'
}

test_repository_sources_pass
test_duplicate_skill_entrypoint_fails
test_dangling_skill_entrypoint_fails
test_duplicate_instruction_entrypoint_fails
test_dangling_instruction_import_fails
test_unterminated_instruction_content_fails
