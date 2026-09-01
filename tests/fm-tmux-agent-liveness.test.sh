#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/lib.sh"
export FM_BACKEND_LIB_DIR="$ROOT/bin"
. "$ROOT/bin/backends/tmux.sh"
[ "$(fm_backend_tmux_classify_process_name /opt/claude)" = agent ]
[ "$(fm_backend_tmux_classify_process_name /bin/bash)" = shell ]
[ "$(fm_backend_tmux_classify_process_name node)" = other ]
printf 'ok - tmux agent liveness classification conformance (hermetic)\n'
