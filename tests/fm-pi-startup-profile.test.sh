#!/usr/bin/env bash
# Regression coverage for canonical Pi captain startup settings and setup import.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE_BIN_DIR=$(dirname "$(command -v node)")
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

canonical="$ROOT/defaults/pi-settings.json"
project_settings="$ROOT/.pi/settings.json"

[ -L "$project_settings" ] || fail '.pi/settings.json is not a symlink'
[ "$(readlink "$project_settings")" = ../defaults/pi-settings.json ] \
  || fail '.pi/settings.json is not the tracked relative canonical import'

node - "$canonical" "$project_settings" <<'NODE' || fail 'canonical Pi captain startup tuple or import is wrong'
const fs = require("node:fs");
const [canonicalPath, projectPath] = process.argv.slice(2);
const canonical = JSON.parse(fs.readFileSync(canonicalPath, "utf8"));
const project = JSON.parse(fs.readFileSync(projectPath, "utf8"));
const expected = ["openai-codex", "gpt-5.6-sol", "medium"];
const tuple = [canonical.defaultProvider, canonical.defaultModel, canonical.defaultThinkingLevel];
if (JSON.stringify(tuple) !== JSON.stringify(expected)) process.exit(1);
if (fs.realpathSync(projectPath) !== fs.realpathSync(canonicalPath)) process.exit(1);
if (JSON.stringify(project) !== JSON.stringify(canonical)) process.exit(1);
for (const key of ["theme", "packages"]) {
  if (canonical[key] === undefined) process.exit(1);
}
NODE

if command -v pi >/dev/null 2>&1; then
  pi_agent="$TMP_ROOT/pi-agent"
  pi_output="$TMP_ROOT/pi-startup.out"
  mkdir -p "$pi_agent"
  printf '%s\n' '{"defaultProvider":"openai-codex","defaultModel":"gpt-5.6-luna","defaultThinkingLevel":"xhigh"}' > "$pi_agent/settings.json"
  printf '%s\n' '{"providers":{"openai-codex":{"baseUrl":"http://127.0.0.1:1/v1","api":"openai-completions","apiKey":"fixture","models":[{"id":"gpt-5.6-sol","reasoning":true},{"id":"gpt-5.6-luna","reasoning":true}]}}}' > "$pi_agent/models.json"
  if ! printf '%s\n' '{"type":"get_state"}' | \
    HOME="$TMP_ROOT/home" PI_CODING_AGENT_DIR="$pi_agent" PI_OFFLINE=1 \
    pi --approve --mode rpc --no-session --no-tools --no-context-files --no-extensions > "$pi_output"; then
    fail 'trusted-clone Pi startup failed'
  fi
  node - "$pi_output" <<'NODE' || fail 'trusted-clone Pi startup ignored the canonical project import'
const fs = require("node:fs");
const lines = fs.readFileSync(process.argv[2], "utf8").trim().split("\n");
const state = lines.map((line) => JSON.parse(line)).find(
  (item) => item.type === "response" && item.command === "get_state",
);
if (!state?.success) process.exit(1);
const tuple = [state.data.model.provider, state.data.model.id, state.data.thinkingLevel];
if (JSON.stringify(tuple) !== JSON.stringify(["openai-codex", "gpt-5.6-sol", "medium"])) process.exit(1);
NODE
  pass 'trusted-clone Pi startup selects canonical Sol/medium profile over harness-local Luna/xhigh settings'
else
  printf 'SKIP: pi not found for trusted-clone startup behavior check\n'
fi

make_mock() {
  local path=$1 body=$2
  printf '#!/usr/bin/env bash\nset -eu\n%s\n' "$body" > "$path"
  chmod +x "$path"
}

run_setup() {
  local repo=$1 home=$2 output=$3
  local mock_bin="$home/.local/bin"
  mkdir -p "$mock_bin" "$home/project/.git" "$home/pi-agent"
  # Mock bodies expand only when their generated scripts execute.
  # shellcheck disable=SC2016
  make_mock "$mock_bin/herdr" 'case "${1:-}" in --version) echo "herdr 0.8.0" ;; status) echo "{}" ;; *) exit 0 ;; esac'
  # shellcheck disable=SC2016
  make_mock "$mock_bin/npm" 'if [ "${1:-}" = prefix ]; then printf "%s\\n" "$HOME/.local"; fi'
  # shellcheck disable=SC2016
  make_mock "$mock_bin/pi" 'case "${1:-}" in --version) echo "pi fixture" ;; *) exit 0 ;; esac'
  printf '%s\n' '{"unrelated":{"keep":true},"defaultModel":"obsolete"}' > "$home/pi-agent/settings.json"
  HOME="$home" SHELL=/bin/zsh PATH="$mock_bin:$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    PI_CODING_AGENT_HOME="$home/pi-agent" PHYND_PROJECT_DIR="$home/project" \
    "$repo/bin/fm-setup-phynd.sh" > "$output"
}

home="$TMP_ROOT/home"
output="$TMP_ROOT/setup.out"
run_setup "$ROOT" "$home" "$output"
node - "$canonical" "$home/pi-agent/settings.json" <<'NODE' || fail 'setup did not merge canonical settings while preserving unrelated keys'
const fs = require("node:fs");
const [sourcePath, targetPath] = process.argv.slice(2);
const source = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
const target = JSON.parse(fs.readFileSync(targetPath, "utf8"));
for (const [key, value] of Object.entries(source)) {
  if (JSON.stringify(target[key]) !== JSON.stringify(value)) process.exit(1);
}
if (target.unrelated?.keep !== true) process.exit(1);
NODE
grep -Fq 'Default model: openai-codex/gpt-5.6-sol with medium thinking.' "$output" \
  || fail 'setup did not display canonical captain profile'
pass 'workstation setup merges and displays canonical profile without deleting unrelated settings'

fixture="$TMP_ROOT/fixture"
mkdir -p "$fixture/bin" "$fixture/defaults"
cp "$ROOT/bin/fm-setup-phynd.sh" "$fixture/bin/"
cp "$ROOT/defaults/"* "$fixture/defaults/"
node - "$fixture/defaults/pi-settings.json" <<'NODE'
const fs = require("node:fs");
const path = process.argv[2];
const settings = JSON.parse(fs.readFileSync(path, "utf8"));
settings.defaultProvider = "fixture-provider";
settings.defaultModel = "fixture-model";
settings.defaultThinkingLevel = "low";
fs.writeFileSync(path, `${JSON.stringify(settings, null, 2)}\n`);
NODE
fixture_home="$TMP_ROOT/fixture-home"
fixture_output="$TMP_ROOT/fixture-setup.out"
run_setup "$fixture" "$fixture_home" "$fixture_output"
grep -Fq 'Default model: fixture-provider/fixture-model with low thinking.' "$fixture_output" \
  || fail 'setup profile output is hard-coded instead of derived from canonical settings'
pass 'setup profile output derives from canonical source'
