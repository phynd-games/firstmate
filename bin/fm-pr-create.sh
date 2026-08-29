#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -lt 1 ]; then
  echo "error: usage: fm-pr-create.sh <task-id> [gh-axi pr create arguments...]" >&2
  exit 2
fi
ID=$1
shift
[ "$#" -gt 0 ] || {
  echo "error: gh-axi pr create arguments are required" >&2
  exit 2
}
"$SCRIPT_DIR/fm-pr-self-review-check.sh" "$ID" direct-PR
command -v gh-axi >/dev/null 2>&1 || {
  echo "error: gh-axi is required to create a pull request" >&2
  exit 1
}
exec gh-axi pr create "$@"
