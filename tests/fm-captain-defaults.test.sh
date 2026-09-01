#!/usr/bin/env bash
# Pin one canonical Firstmate captain startup profile and every Pi import path.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
GLOBAL_SETTINGS="$ROOT/defaults/pi-settings.json"
HARNESS_SETTINGS="$ROOT/.pi/settings.json"

[ -L "$HARNESS_SETTINGS" ] || {
  printf '%s\n' "$HARNESS_SETTINGS must be a symlink to the global Firstmate defaults" >&2
  exit 1
}
[ "$(readlink "$HARNESS_SETTINGS")" = ../defaults/pi-settings.json ] || {
  printf '%s\n' "$HARNESS_SETTINGS must point to ../defaults/pi-settings.json" >&2
  exit 1
}
[ "$(cd -- "$(dirname -- "$HARNESS_SETTINGS")" && realpath "$(readlink "$HARNESS_SETTINGS")")" = "$(realpath "$GLOBAL_SETTINGS")" ] || {
  printf '%s\n' "$HARNESS_SETTINGS does not resolve to global Firstmate defaults" >&2
  exit 1
}

node - "$GLOBAL_SETTINGS" <<'NODE'
const fs = require("node:fs");
const [settingsPath] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
const expected = {
  defaultProvider: "openai-codex",
  defaultModel: "gpt-5.6-sol",
  defaultThinkingLevel: "medium",
};
for (const [key, value] of Object.entries(expected)) {
  if (settings[key] !== value) {
    throw new Error(`${settingsPath}: ${key} must be ${JSON.stringify(value)}`);
  }
}
NODE

printf 'ok - one global captain startup profile supplies Pi Sol/medium defaults\n'
