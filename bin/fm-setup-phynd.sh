#!/usr/bin/env bash
# Provision Pi and the Phynd engineering defaults for a new workstation.
# Usage: bin/fm-setup-phynd.sh
#
# Installs or updates Herdr, installs Pi, then installs the configured Pi packages,
# and finally merges the checked-in Phynd defaults into global Pi settings.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PI_HOME=${PI_CODING_AGENT_HOME:-"$HOME/.pi/agent"}
CONFIG_DIR=${FM_HOME:-"$ROOT"}/config
SETTINGS_SOURCE="$ROOT/defaults/pi-settings.json"
OPEN_TUI_SOURCE="$ROOT/defaults/pi-open-tui.json"
CONCISE_SOURCE="$ROOT/defaults/phynd-concise.md"
CLAUDE_HOME=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || fail 'node is required.'
command -v curl >/dev/null 2>&1 || fail 'curl is required to install Herdr.'

version_at_least() {
  node - "$1" "$2" <<'NODE'
const [actual, minimum] = process.argv.slice(2).map((value) =>
  value.replace(/^v/, "").split(/[+-]/, 1)[0].split(".").map((part) => Number(part) || 0));
for (let index = 0; index < 3; index += 1) {
  if ((actual[index] ?? 0) !== (minimum[index] ?? 0)) process.exit((actual[index] ?? 0) > (minimum[index] ?? 0) ? 0 : 1);
}
NODE
}

herdr_version() {
  herdr --version 2>/dev/null | awk '{print $2; exit}'
}

install_or_update_herdr() {
  local version
  version=$(herdr_version || true)
  if [ -z "$version" ] || ! version_at_least "$version" 0.8.0; then
    printf 'Installing/updating Herdr to the latest release (minimum 0.8.0)...\n'
    curl -fsSL https://herdr.dev/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  command -v herdr >/dev/null 2>&1 || fail 'Herdr installation completed but herdr is not on PATH.'
  version=$(herdr_version || true)
  version_at_least "${version:-0.0.0}" 0.8.0 || fail "Herdr ${version:-unknown} is below the required 0.8.0 minimum."
  printf 'Herdr: %s\n' "$version"
}

install_or_update_herdr

if ! command -v pi >/dev/null 2>&1; then
  command -v npm >/dev/null 2>&1 || fail 'pi is missing and npm is not installed.'
  printf 'Installing Pi...\n'
  npm install --global @earendil-works/pi-coding-agent
fi

command -v pi >/dev/null 2>&1 || fail 'Pi installation completed but pi is not on PATH.'

printf 'Installing Pi packages...\n'
while IFS= read -r package; do
  [ -n "$package" ] || continue
  pi install "$package"
done < <(node -e 'for (const p of require(process.argv[1]).packages) console.log(p)' "$SETTINGS_SOURCE")

mkdir -p "$PI_HOME" "$CONFIG_DIR" "$CLAUDE_HOME"
printf 'herdr\n' > "$CONFIG_DIR/backend"
printf 'on\n' > "$CONFIG_DIR/herdr-presentation-spaces"
chmod 600 "$CONFIG_DIR/backend" "$CONFIG_DIR/herdr-presentation-spaces"
cp "$CONCISE_SOURCE" "$CLAUDE_HOME/phynd-concise.md"
chmod 600 "$CLAUDE_HOME/phynd-concise.md"

node - "$SETTINGS_SOURCE" "$PI_HOME/settings.json" <<'NODE'
const fs = require("node:fs");
const [sourcePath, targetPath] = process.argv.slice(2);
const source = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
let current = {};
try {
  current = JSON.parse(fs.readFileSync(targetPath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const merged = { ...current, ...source };
fs.writeFileSync(targetPath, `${JSON.stringify(merged, null, 2)}\n`, { mode: 0o600 });
NODE

node - "$OPEN_TUI_SOURCE" "$PI_HOME/open-tui.json" <<'NODE'
const fs = require("node:fs");
const [sourcePath, targetPath] = process.argv.slice(2);
const source = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
let current = {};
try {
  current = JSON.parse(fs.readFileSync(targetPath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const merge = (left, right) => {
  const result = { ...left };
  for (const [key, value] of Object.entries(right)) {
    result[key] = value && typeof value === "object" && !Array.isArray(value)
      ? merge(result[key] && typeof result[key] === "object" ? result[key] : {}, value)
      : value;
  }
  return result;
};
fs.writeFileSync(targetPath, `${JSON.stringify(merge(current, source), null, 2)}\n`, { mode: 0o600 });
NODE

printf 'Phynd Pi setup complete.\n'
printf 'Default model: openai-codex/gpt-5.6-luna with xhigh thinking.\n'
printf 'Default Firstmate backend: herdr.\n'
printf 'Herdr presentation spaces: on (one visible workspace per task).\n'
printf 'Theme: cosmic-lagoon.\n'
printf 'Launch with: pi\n'
printf 'Claude concise prompt: %s\n' "$CLAUDE_HOME/phynd-concise.md"
printf 'Claude launch: claude --append-system-prompt-file %s\n' "$CLAUDE_HOME/phynd-concise.md"
