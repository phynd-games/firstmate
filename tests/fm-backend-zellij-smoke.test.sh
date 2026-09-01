#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/lib.sh"
. "$ROOT/bin/backends/zellij.sh"
[ "$(fm_backend_zellij_normalize_key Enter)" = Enter ]
[ "$(fm_backend_zellij_normalize_key Escape)" = Esc ]
[ "$(fm_backend_zellij_normalize_key C-c)" = 'Ctrl c' ]
fm_backend_zellij_parse_target lab:17
[ "$FM_BACKEND_ZELLIJ_SESSION" = lab ]
[ "$FM_BACKEND_ZELLIJ_PANE" = 17 ]
printf 'ok - zellij adapter key and target conformance (hermetic)\n'
