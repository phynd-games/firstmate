#!/usr/bin/env bash
set -u
export FM_TEST_SKIP_ORPHAN_REAP=1
export TMPDIR="$PWD/.test-tmp"
EVIDENCE_DIR=/var/folders/8p/1k00gwfd1831jgf0f5f58g780000gn/T/no-mistakes-evidence/01M26CEVEQSBWS3JXTP7Q3DA3B
. tests/lib.sh
capture_evidence() {
  local label=$1 home f v
  {
    printf '\nOBSERVATION: %s\n' "$label"
    for v in out drain_out ack_out GEN22 SUCCESSOR22 GAP_GEN22 GAP_HOLDER22 HANG_ELAPSED probe_failure probe_elapsed FLOOR_ELAPSED; do
      if declare -p "$v" >/dev/null 2>&1; then printf '%s=%s\n' "$v" "${!v}"; fi
    done
    for home in "${TMP_ROOT:-}"/{no-server,hanging-cli,hang-version-status,hang-session-status,hang-session-list,session-list-fails,handling-successor,cleanup-absent,cleanup-absent-unreadable,cleanup-absent-other-server,cleanup-invalid-inventory,floor-sleep-signal}; do
      [ -d "$home" ] || continue
      printf '\nHOME %s\n' "$(basename "$home")"
      for f in state/.watcher-down state/.watch.lock/pid state/.watch-cycle-exits.log state/.herdr-supervisor state/.herdr-supervisor-pending-cleanup state/.herdr-supervisor-alarm state/.herdr-supervisor.log fakestate/closed-workspaces fakestate/workspace-closed; do
        printf '%s:\n' "$f"
        if [ -f "$home/$f" ]; then cat "$home/$f"; printf '\n'; else printf '(absent)\n'; fi
      done
    done
  } >> "$EVIDENCE_DIR/${OBS_FILE:-monitor-recovery-observations.log}"
}
pass() {
  printf 'ok - %s\n' "$1"
  case "$1" in
    *Herdr*server*|*CLI*bounded*|*native*deadline*|*handling*successor*|*exact*acknowledgement*|*verified*server*|*unreadable*|*different*server*|*inventories*|*target-absent*|*asleep*) capture_evidence "$1";;
  esac
}
fail() {
  printf 'not ok - %s\n' "$1" >&2
  capture_evidence "FAILURE: $1"
  exit 1
}
. "${TEST_SCRIPT:-tests/fm-herdr-supervisor.test.sh}"
