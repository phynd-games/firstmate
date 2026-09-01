#!/usr/bin/env bash
# Semantic regression coverage for the pinned Herdr installer.
#
# The fixture supplies release-shaped binaries and checksum results through the
# installer's executable dependencies, so tests exercise platform selection,
# checksum verification, and installation without inspecting script source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-herdr.sh"
HERDR_VERSION=0.8.0
HERDR_SHA_LINUX_X86_64=b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28
HERDR_SHA_LINUX_AARCH64=f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87

# fm_herdr_stub_uname <fakebin>: report the platform selected by each case.
fm_herdr_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

# fm_herdr_stub_curl <fakebin>: create a release-shaped binary and record URL.
fm_herdr_stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[ -n "${CURL_URL_LOG:-}" ] || exit 1
printf '%s\n' "$url" > "$CURL_URL_LOG"
cat > "$output" <<'HERDR'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'herdr 0.8.0\n' ;;
  status)
    [ "${2:-}" = --json ] || exit 1
    printf '{"client":{"protocol":19}}\n'
    ;;
  *) exit 1 ;;
esac
HERDR
chmod +x "$output"
SH
  chmod +x "$fakebin/curl"
}

# fm_herdr_stub_hasher <fakebin>: return checksum associated with downloaded asset.
fm_herdr_stub_hasher() {
  local fakebin=$1
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
file=$1
asset=${file##*/}
case "$asset" in
  herdr-linux-x86_64) digest=b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28 ;;
  herdr-linux-aarch64) digest=f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87 ;;
  *) exit 1 ;;
esac
if [ "${FM_TEST_WRONG_CHECKSUM:-0}" = 1 ]; then
  digest=0000000000000000000000000000000000000000000000000000000000000000
fi
printf '%s  %s\n' "$digest" "$file"
SH
  chmod +x "$fakebin/sha256sum"
}

run_installer() {
  local fakebin=$1 destination=$2 url_log=$3 os=$4 arch=$5
  FM_TEST_UNAME_S=$os FM_TEST_UNAME_M=$arch CURL_URL_LOG=$url_log \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination"
}

test_installer_selects_linux_assets_and_checksums() {
  local tmp fakebin destination url_log out os arch asset checksum expected_url
  tmp=$(fm_test_tmproot fm-herdr-platform)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/url.log"
  fm_herdr_stub_uname "$fakebin"
  fm_herdr_stub_curl "$fakebin"
  fm_herdr_stub_hasher "$fakebin"

  while IFS=$'\t' read -r os arch asset checksum; do
    [ -n "$os" ] || continue
    rm -rf "$destination"
    out=$(run_installer "$fakebin" "$destination" "$url_log" "$os" "$arch" 2>&1) \
      || fail "Herdr installer failed for ${os}/${arch}"$'\n'"$out"
    expected_url="https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/${asset}"
    [ "$(cat "$url_log")" = "$expected_url" ] \
      || fail "Herdr installer selected wrong asset or URL for ${os}/${arch}"
    assert_contains "$out" "installed herdr $HERDR_VERSION" \
      "Herdr installer did not report successful installation for ${os}/${arch}"
    [ -x "$destination/herdr" ] \
      || fail "Herdr installer did not install executable for ${os}/${arch}"
    case "$asset" in
      herdr-linux-x86_64) expected_checksum=$HERDR_SHA_LINUX_X86_64 ;;
      herdr-linux-aarch64) expected_checksum=$HERDR_SHA_LINUX_AARCH64 ;;
      *) fail "test fixture has unknown asset $asset" ;;
    esac
    [ "$checksum" = "$expected_checksum" ] \
      || fail "test fixture checksum is inconsistent for $asset"
  done <<EOF
Linux	x86_64	herdr-linux-x86_64	$HERDR_SHA_LINUX_X86_64
Linux	aarch64	herdr-linux-aarch64	$HERDR_SHA_LINUX_AARCH64
EOF
  pass "Herdr installer selects exact Linux assets and checksums for x86_64 and aarch64"
}

test_installer_rejects_wrong_checksum() {
  local tmp fakebin destination url_log out rc
  tmp=$(fm_test_tmproot fm-herdr-badsum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/url.log"
  fm_herdr_stub_uname "$fakebin"
  fm_herdr_stub_curl "$fakebin"
  fm_herdr_stub_hasher "$fakebin"

  rc=0
  out=$(FM_TEST_WRONG_CHECKSUM=1 run_installer \
    "$fakebin" "$destination" "$url_log" Linux x86_64 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Herdr installer accepted wrong checksum"$'\n'"$out"
  assert_contains "$out" "checksum mismatch" \
    "Herdr installer did not report wrong checksum"
  assert_contains "$out" "herdr-linux-x86_64" \
    "Herdr checksum failure did not name selected asset"
  assert_contains "$out" "$HERDR_SHA_LINUX_X86_64" \
    "Herdr checksum failure did not name pinned x86_64 checksum"
  assert_absent "$destination/herdr" \
    "Herdr installer installed binary after checksum failure"
  pass "Herdr installer refuses wrong checksum before installation"
}

test_installer_selects_linux_assets_and_checksums
test_installer_rejects_wrong_checksum
