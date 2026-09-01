#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/lib.sh"
. "$ROOT/bin/backends/cmux.sh"
[ "$(fm_backend_cmux_normalize_key Enter)" = enter ]
[ "$(fm_backend_cmux_normalize_key Escape)" = escape ]
[ "$(fm_backend_cmux_normalize_key C-c)" = ctrl-c ]
fm_backend_cmux_parse_target workspace:surface
[ "$FM_BACKEND_CMUX_WORKSPACE" = workspace ]
[ "$FM_BACKEND_CMUX_SURFACE" = surface ]
printf 'ok - cmux adapter key and target conformance (hermetic)\n'
