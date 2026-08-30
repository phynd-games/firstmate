#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pass "retained-backend regression suite retired; Herdr-only behavior is covered by fm-backend-herdr-only.test.sh"
