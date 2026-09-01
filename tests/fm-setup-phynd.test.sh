#!/usr/bin/env bash
# Behavior tests for the hermetic Phynd workstation installer.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETUP="$ROOT/bin/fm-setup-phynd.sh"
TMP_ROOT=$(fm_test_tmproot fm-setup-phynd)
REAL_NODE=$(command -v node)

make_installer_stubs() {
  local dir=$1 protocol=${2:-14}
  mkdir -p "$dir"
  cat > "$dir/node" <<SH
#!/usr/bin/env bash
exec "$REAL_NODE" "\$@"
SH
  cat > "$dir/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) printf 'herdr 0.8.0\\n' ;;
  status) printf '{"client":{"version":"0.8.0","protocol":$protocol},"server":{"running":false,"status":"stopped","compatible":true,"protocol":$protocol}}\\n' ;;
  *) exit 0 ;;
esac
SH
  cat > "$dir/npm" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = prefix ] && [ "${2:-}" = --global ]; then
  printf '%s\n' /tmp/fm-setup-npm
fi
exit 0
SH
  cat > "$dir/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'pi 0.84.0\n' ;;
  install|update) exit 0 ;;
  *) exit 0 ;;
esac
SH
  cat > "$dir/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/node" "$dir/herdr" "$dir/npm" "$dir/pi" "$dir/gh"
}

run_installer() {
  local home=$1 fakebin=$2
  HOME="$home" SHELL=/bin/bash PATH="$fakebin:$PATH" \
    PI_CODING_AGENT_HOME="$home/.pi/agent" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" PHYND_PROJECT_DIR="$home/projects/phynd-cloud" \
    "$SETUP" 2>&1
}

test_settings_merge_and_backend_materialization() {
  local dir="$TMP_ROOT/healthy" home fakebin out before after
  home="$dir/home"
  fakebin="$dir/bin"
  mkdir -p "$home/projects/phynd-cloud/.git" "$home/config" "$home/.pi/agent"
  printf '{"unrelated":true,"defaultModel":"old","defaultThinkingLevel":"low"}\n' \
    > "$home/.pi/agent/settings.json"
  make_installer_stubs "$fakebin"
  out=$(run_installer "$home" "$fakebin") || fail "healthy installer failed: $out"
  [ "$(cat "$home/config/backend")" = herdr ] || fail "installer did not write config/backend=herdr"
  jq -e '.unrelated == true and .defaultModel == "gpt-5.6-sol" and .defaultThinkingLevel == "medium"' \
    "$home/.pi/agent/settings.json" >/dev/null || fail "installer settings merge lost captain defaults or unrelated data"
  before=$(cksum "$home/.pi/agent/settings.json" "$home/config/backend")
  out=$(run_installer "$home" "$fakebin") || fail "idempotent installer failed: $out"
  after=$(cksum "$home/.pi/agent/settings.json" "$home/config/backend")
  [ "$before" = "$after" ] || fail "installer was not idempotent"
  pass "installer merges Sol/medium captain settings and herdr backend idempotently"
}

test_installer_rejects_below_floor() {
  local dir="$TMP_ROOT/below-floor" home fakebin out rc
  home="$dir/home"
  fakebin="$dir/bin"
  mkdir -p "$home/projects/phynd-cloud/.git" "$home/config"
  make_installer_stubs "$fakebin" 13
  set +e
  out=$(run_installer "$home" "$fakebin")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "below-floor Herdr installer unexpectedly succeeded"
  assert_contains "$out" "Herdr readiness verification failed" "below-floor installer diagnostic"
  assert_contains "$out" "verify with 'herdr status --json'" "below-floor installer remediation"
  pass "installer fails closed on a below-floor Herdr protocol"
}

test_settings_merge_and_backend_materialization
test_installer_rejects_below_floor
echo "# all fm-setup-phynd tests passed"
