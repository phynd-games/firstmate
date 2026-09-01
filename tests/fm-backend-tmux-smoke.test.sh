#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/lib.sh"
export FM_BACKEND_LIB_DIR="$ROOT/bin"
. "$ROOT/bin/backends/tmux.sh"
[ "$(fm_backend_tmux_classify_process_name /opt/bin/codex)" = agent ]
[ "$(fm_backend_tmux_classify_process_name -zsh)" = shell ]
[ "$(fm_backend_tmux_classify_process_name unrelated)" = other ]
printf 'ok - tmux adapter classification conformance (hermetic)\n'
