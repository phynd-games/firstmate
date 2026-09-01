#!/usr/bin/env bash
# Provision Pi and the Phynd engineering defaults for a new workstation.
# Usage: bin/fm-setup-phynd.sh
#
# Installs or updates Herdr, installs Pi, then installs the configured Pi packages,
# and finally merges the checked-in Phynd defaults into global Pi settings.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PI_HOME=${PI_CODING_AGENT_HOME:-"$HOME/.pi/agent"}
HOME_ROOT=${FM_HOME:-"$ROOT"}
CONFIG_DIR=${FM_CONFIG_OVERRIDE:-"$HOME_ROOT/config"}
DATA_DIR=${FM_DATA_OVERRIDE:-"$HOME_ROOT/data"}
PROJECTS_DIR=${FM_PROJECTS_OVERRIDE:-"$HOME_ROOT/projects"}
SETTINGS_SOURCE="$ROOT/defaults/pi-settings.json"
OPEN_TUI_SOURCE="$ROOT/defaults/pi-open-tui.json"
CONCISE_SOURCE="$ROOT/defaults/phynd-concise.md"
CLAUDE_HOME=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
PHYND_PROJECT_DIR=${PHYND_PROJECT_DIR:-"$PROJECTS_DIR/phynd-cloud"}
if [[ "$PHYND_PROJECT_DIR" != /* ]]; then
  PHYND_PROJECT_DIR="$HOME_ROOT/$PHYND_PROJECT_DIR"
fi

usage() {
  cat <<'USAGE'
Usage: bin/fm-setup-phynd.sh

Installs or updates Herdr, installs Pi, installs the configured Pi packages,
clones/registers the Phynd Cloud monorepo, and applies Phynd defaults.
USAGE
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
fi

PATH="$HOME/.local/bin:$PATH"
npm_prefix=""
if command -v npm >/dev/null 2>&1; then
  npm_prefix=$(npm prefix --global 2>/dev/null || true)
  if [ -n "$npm_prefix" ]; then
    PATH="$npm_prefix/bin:$PATH"
  fi
fi
export PATH

persist_path() {
  local path_entry=$1 profile=$2 line
  [ -n "$path_entry" ] || return 0
  line="export PATH=\"$path_entry:\$PATH\""
  [ -f "$profile" ] || touch "$profile"
  grep -Fqx "$line" "$profile" 2>/dev/null || printf '%s\n' "$line" >> "$profile"
}

case "${SHELL##*/}" in
  bash) SHELL_PROFILE="$HOME/.bash_profile" ;;
  *) SHELL_PROFILE="$HOME/.zprofile" ;;
esac
persist_path "$HOME/.local/bin" "$SHELL_PROFILE"
if [ -n "$npm_prefix" ]; then
  persist_path "$npm_prefix/bin" "$SHELL_PROFILE"
fi

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

herdr_live_handoff_if_needed() {
  local status protocol binary
  status=$(herdr status --json 2>/dev/null || true)
  [ -n "$status" ] || return 0
  if ! printf '%s' "$status" | node -e 'let s=""; process.stdin.on("data", c => s += c).on("end", () => { try { process.exit(JSON.parse(s).server?.restart_needed === true ? 0 : 1); } catch { process.exit(1); } });'; then
    return 0
  fi
  protocol=$(printf '%s' "$status" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).client?.protocol || ""')
  binary=$(command -v herdr)
  [ -n "$protocol" ] || fail 'Herdr reports an incompatible server but no client protocol for live handoff.'
  printf 'Updating the running Herdr server without stopping its panes...\n'
  herdr server live-handoff --import-exe "$binary" --expected-protocol "$protocol" --expected-version "$(herdr_version)" \
    || fail 'Herdr server live handoff failed; rerun setup after resolving the Herdr server state.'
}

install_or_update_herdr() {
  local version brew_prefix
  version=$(herdr_version || true)
  if [ -z "$version" ] || ! version_at_least "$version" 0.8.0; then
    printf 'Installing/updating Herdr to the latest release (minimum 0.8.0)...\n'
    if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
      if brew list --formula herdr >/dev/null 2>&1; then
        brew upgrade herdr || true
      else
        brew install herdr
      fi
      brew_prefix=$(brew --prefix 2>/dev/null || true)
      if [ -n "$brew_prefix" ]; then
        PATH="$brew_prefix/bin:$PATH"
        export PATH
      fi
    else
      curl -fsSL https://herdr.dev/install.sh | sh
      PATH="$HOME/.local/bin:$PATH"
      export PATH
    fi
  fi
  command -v herdr >/dev/null 2>&1 || fail 'Herdr installation completed but herdr is not on PATH.'
  version=$(herdr_version || true)
  version_at_least "${version:-0.0.0}" 0.8.0 || fail "Herdr ${version:-unknown} is below the required 0.8.0 minimum."
  herdr_live_handoff_if_needed
  printf 'Herdr: %s\n' "$version"
}

install_or_update_herdr

install_or_update_pi() {
  local npm_prefix
  command -v npm >/dev/null 2>&1 || fail 'npm is required to install or update Pi.'
  printf 'Installing/updating Pi...\n'
  npm install --global @earendil-works/pi-coding-agent
  npm_prefix=$(npm prefix --global 2>/dev/null || true)
  if [ -n "$npm_prefix" ]; then
    PATH="$npm_prefix/bin:$PATH"
    export PATH
    persist_path "$npm_prefix/bin" "$SHELL_PROFILE"
  fi

  command -v pi >/dev/null 2>&1 || fail 'Pi installation completed but pi is not on PATH. Add npm global bin and ~/.local/bin to PATH, then re-run setup.'
  printf 'Pi: %s\n' "$(pi --version 2>/dev/null | head -n 1)"
}

install_or_update_pi

provision_phynd_project() {
  local fresh=0 today
  if [ -e "$PHYND_PROJECT_DIR" ]; then
    [ -d "$PHYND_PROJECT_DIR/.git" ] || fail "Phynd project path exists but is not a Git checkout: $PHYND_PROJECT_DIR"
  else
    command -v gh >/dev/null 2>&1 || fail 'gh is required to clone the Phynd Cloud monorepo.'
    mkdir -p "$(dirname "$PHYND_PROJECT_DIR")"
    printf 'Cloning Phynd Cloud monorepo...\n'
    gh repo clone phynd-games/phynd-cloud "$PHYND_PROJECT_DIR"
    fresh=1
  fi

  mkdir -p "$DATA_DIR"
  if [ ! -f "$DATA_DIR/projects.md" ]; then
    printf '# Registered projects\n\n' > "$DATA_DIR/projects.md"
  fi
  if ! grep -Fq -- '- phynd-cloud ' "$DATA_DIR/projects.md"; then
    today=$(date +%F)
    printf '%s\n' "- phynd-cloud [no-mistakes-prod-only] - Canonical Phynd Cloud product monorepo (added $today)" >> "$DATA_DIR/projects.md"
  fi

  if [ "$fresh" -eq 1 ] && command -v no-mistakes >/dev/null 2>&1; then
    printf 'Initializing the Phynd project validation gate...\n'
    (cd "$PHYND_PROJECT_DIR" && no-mistakes init && no-mistakes doctor)
  elif [ "$fresh" -eq 1 ]; then
    printf 'NOTICE: no-mistakes is unavailable; run no-mistakes init in %s before dispatching gated work.\n' "$PHYND_PROJECT_DIR" >&2
  fi
  printf 'Phynd project: %s\n' "$PHYND_PROJECT_DIR"
}

provision_phynd_project

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

printf 'Installing Pi packages...\n'
while IFS= read -r package; do
  [ -n "$package" ] || continue
  pi install "$package"
done < <(node -e 'for (const p of require(process.argv[1]).packages) console.log(p)' "$SETTINGS_SOURCE")
printf 'Refreshing installed Pi extensions...\n'
pi update --extensions

printf 'Phynd Pi setup complete.\n'
node - "$SETTINGS_SOURCE" <<'NODE'
const settings = require(process.argv[2]);
console.log(`Default model: ${settings.defaultProvider}/${settings.defaultModel} with ${settings.defaultThinkingLevel} thinking.`);
NODE
printf 'Default Firstmate backend: herdr.\n'
printf 'Herdr presentation spaces: on (one visible workspace per task).\n'
printf 'Theme: cosmic-lagoon.\n'
printf 'Next: from this directory run herdr, then launch pi inside the Herdr terminal.\n'
printf 'Claude concise prompt: %s\n' "$CLAUDE_HOME/phynd-concise.md"
printf 'Claude launch: claude --append-system-prompt-file %s\n' "$CLAUDE_HOME/phynd-concise.md"
printf 'If herdr or pi is not found in a new shell, add %s and your npm global bin to PATH.\n' "$HOME/.local/bin"
