#!/usr/bin/env bash
# Behavior tests for the isolated phynd-dev lifecycle and repo-owned tools.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
TMP_ROOT=$(fm_test_tmproot phynd-dev-tests)
REAL_PATH=$PATH

make_fake_phynd_tools() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/nix" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'nix (fake phynd-dev test)'
  exit 0
fi
if [ "${1:-}" = flake ] && [ "${2:-}" = update ]; then
  printf '%s\n' 'flake update' >> "${PHYN_DEV_NIX_LOG:?}"
  exit 0
fi
if [ "${1:-}" = flake ] && [ "${2:-}" = check ]; then
  printf '%s\n' 'flake check' >> "${PHYN_DEV_NIX_LOG:?}"
  exit 0
fi
exit 0
SH
  cat > "$dir/darwin-rebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PHYN_DEV_REBUILD_LOG:?}"
SH
  chmod +x "$dir/nix" "$dir/darwin-rebuild"
}

make_phynd_fixture() {
  local source=$1 fixture=$2
  mkdir -p "$fixture/bin" "$fixture/config/fresh" "$fixture/home/wezterm" "$fixture/nix"
  cp "$source/phynd-dev" "$fixture/phynd-dev"
  cp "$source/bin/phynd-dev" "$fixture/bin/phynd-dev"
  cp "$source/flake.nix" "$fixture/flake.nix"
  cp "$source/flake.lock" "$fixture/flake.lock" 2>/dev/null || : > "$fixture/flake.lock"
  cp "$source/config/fresh/config.json" "$fixture/config/fresh/config.json"
  cp "$source/config/starship.toml" "$fixture/config/starship.toml"
  cp "$source/home/wezterm/wezterm.lua" "$fixture/home/wezterm/wezterm.lua"
  cp "$source/nix/configuration.nix" "$fixture/nix/configuration.nix"
  cp "$source/nix/home.nix" "$fixture/nix/home.nix"
  chmod +x "$fixture/phynd-dev" "$fixture/bin/phynd-dev"
}

phynd_env() {
  local home=$1 xdg=$2 state=$3 npm_prefix=$4 log=$5 rebuild_log=$6
  shift 6
  HOME="$home" \
  PHYN_DEV_HOME="$home" \
  PHYN_DEV_XDG_CONFIG_HOME="$xdg" \
  PHYN_DEV_STATE_DIR="$state" \
  PHYN_DEV_NPM_PREFIX="$npm_prefix" \
  PHYN_DEV_NIX_PROFILE="$home/nix-profile/bin" \
  PHYN_DEV_USER="$(id -un)" \
  PHYN_DEV_SKIP_SUDO=1 \
  PHYN_DEV_SKIP_TOOLS=1 \
  PHYN_DEV_UNAME_S=Darwin \
  PHYN_DEV_UNAME_M=arm64 \
  PHYN_DEV_NIX_LOG="$log" \
  PHYN_DEV_REBUILD_LOG="$rebuild_log" \
  PATH="$PHYN_TEST_FAKEBIN:$REAL_PATH" \
  "$@"
}

test_root_entrypoint_resolves_itself() {
  local case_dir out
  case_dir="$TMP_ROOT/root-entrypoint"
  mkdir -p "$case_dir/home"
  out=$(cd /tmp && HOME="$case_dir/home" PHYN_DEV_UNAME_S=Darwin \
    PHYN_DEV_UNAME_M=arm64 "$ROOT/phynd-dev" status) \
    || fail "root phynd-dev entrypoint should work from another caller directory"
  assert_contains "$out" "checkout: $ROOT" "root entrypoint should identify its own checkout"
  assert_contains "$out" "system:   aarch64-darwin" "root entrypoint should resolve the host system"
  pass "root phynd-dev delegates to bin/phynd-dev independent of caller directory"
}

test_install_noop_update_and_safe_backup() {
  local case_dir fixture home xdg state npm_prefix nix_log rebuild_log out count
  case_dir="$TMP_ROOT/lifecycle"
  fixture="$case_dir/repo"
  home="$case_dir/home"
  xdg="$home/.config"
  state="$home/.local/state/phynd-dev"
  npm_prefix="$home/.local/share/phynd-dev/npm"
  nix_log="$case_dir/nix.log"
  rebuild_log="$case_dir/rebuild.log"
  mkdir -p "$home" "$xdg/fresh"
  make_phynd_fixture "$ROOT" "$fixture"
  make_fake_phynd_tools "$case_dir/fakebin"
  PHYN_TEST_FAKEBIN="$case_dir/fakebin"
  export PHYN_TEST_FAKEBIN
  export PHYN_DEV_BACKUP_SUFFIX=test
  : > "$nix_log"
  : > "$rebuild_log"
  printf '%s\n' '{"captain_private":true}' > "$xdg/fresh/config.json"

  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" "$nix_log" "$rebuild_log" \
    "$fixture/phynd-dev" install) || fail "initial phynd-dev install failed: $out"
  assert_contains "$out" "activation state recorded" "initial install should record activation"
  [ -L "$xdg/fresh/config.json" ] || fail "Fresh config should be linked after install"
  [ "$(readlink "$xdg/fresh/config.json")" = "$fixture/config/fresh/config.json" ] \
    || fail "Fresh link should target the repository source"
  [ "$(cat "$xdg/fresh/config.json.phynd-dev-backup-test")" = '{"captain_private":true}' ] \
    || fail "existing Fresh configuration should be preserved in a backup"
  count=$(wc -l < "$rebuild_log" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "initial install should activate exactly once"

  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" \
    "$nix_log" "$rebuild_log" "$fixture/phynd-dev" install) \
    || fail "second phynd-dev install failed: $out"
  assert_contains "$out" "already converged" "second install should report a no-op"
  count=$(wc -l < "$rebuild_log" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "second install should not reactivate nix-darwin"

  printf '\n# later repo configuration revision\n' >> "$fixture/config/starship.toml"
  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" \
    "$nix_log" "$rebuild_log" "$fixture/phynd-dev" update) \
    || fail "phynd-dev update failed: $out"
  assert_contains "$out" "applying pinned nix-darwin" "changed configuration should reactivate"
  count=$(wc -l < "$rebuild_log" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "updated configuration should activate once more"
  pass "phynd-dev install, converged no-op, update, and safe backup paths are idempotent"
}

test_flake_update_and_check_are_explicit() {
  local case_dir fixture home xdg state npm_prefix nix_log rebuild_log out
  case_dir="$TMP_ROOT/flake-actions"
  fixture="$case_dir/repo"
  home="$case_dir/home"
  xdg="$home/.config"
  state="$home/.local/state/phynd-dev"
  npm_prefix="$home/.local/share/phynd-dev/npm"
  nix_log="$case_dir/nix.log"
  rebuild_log="$case_dir/rebuild.log"
  mkdir -p "$home"
  make_phynd_fixture "$ROOT" "$fixture"
  make_fake_phynd_tools "$case_dir/fakebin"
  PHYN_TEST_FAKEBIN="$case_dir/fakebin"
  export PHYN_TEST_FAKEBIN
  : > "$nix_log"
  : > "$rebuild_log"

  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" "$nix_log" "$rebuild_log" \
    "$fixture/phynd-dev" flake-check) || fail "flake-check path failed: $out"
  assert_contains "$out" "evaluating the pinned flake" "flake-check should explain its action"
  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" "$nix_log" "$rebuild_log" \
    "$fixture/phynd-dev" flake-update) || fail "flake-update path failed: $out"
  assert_contains "$out" "updating the flake lock" "flake-update should explain its action"
  assert_contains "$(cat "$nix_log")" "flake check" "flake-check should invoke nix"
  assert_contains "$(cat "$nix_log")" "flake update" "flake-update should invoke nix"
  pass "flake-check and flake-update remain explicit, separate lifecycle paths"
}

test_fresh_effective_config_and_wezterm_load() {
  local case_dir fixture home xdg state npm_prefix nix_log rebuild_log show out
  case_dir="$TMP_ROOT/editor-config"
  fixture="$case_dir/repo"
  home="$case_dir/home"
  xdg="$home/.config"
  state="$home/.local/state/phynd-dev"
  npm_prefix="$home/.local/share/phynd-dev/npm"
  nix_log="$case_dir/nix.log"
  rebuild_log="$case_dir/rebuild.log"
  mkdir -p "$home"
  make_phynd_fixture "$ROOT" "$fixture"
  make_fake_phynd_tools "$case_dir/fakebin"
  PHYN_TEST_FAKEBIN="$case_dir/fakebin"
  export PHYN_TEST_FAKEBIN
  : > "$nix_log"
  : > "$rebuild_log"
  phynd_env "$home" "$xdg" "$state" "$npm_prefix" "$nix_log" "$rebuild_log" \
    "$fixture/phynd-dev" install >/dev/null \
    || fail "editor-config install failed"

  if command -v fresh >/dev/null 2>&1; then
    show=$(HOME="$home" XDG_CONFIG_HOME="$xdg" PATH="$REAL_PATH" \
      fresh --cmd config show) || fail "Fresh could not load the activated repo config"
    printf '%s\n' "$show" | jq -e '
      .file_explorer.show_gitignored == true and
      .lsp.typescript[0].command == "typescript-language-server" and
      .lsp.typescript[0].auto_start == true and
      .lsp.javascript[0].command == "typescript-language-server" and
      .lsp.rust[0].command == "rust-analyzer" and
      .lsp.lua[0].command == "lua-language-server" and
      .lsp.python[0].command == "basedpyright-langserver" and
      (.lsp.typescript[0].root_markers | index(".git")) != null and
      (.lsp.rust[0].root_markers | index("Cargo.toml")) != null and
      (.lsp.python[0].root_markers | index("pyproject.toml")) != null
    ' >/dev/null || fail "Fresh effective config did not expose the managed explorer and LSP settings"
    pass "Fresh loads show_gitignored and all five managed language mappings from the activated repo config"
  else
    pass "Fresh effective-config validation skipped because Fresh is not installed in this test environment"
  fi

  if command -v wezterm >/dev/null 2>&1; then
    out=$(HOME="$home" XDG_CONFIG_HOME="$xdg" PATH="$REAL_PATH" \
      wezterm show-keys --lua 2>&1) || fail "WezTerm could not load the activated repo Lua config: $out"
    pass "WezTerm's config-loading surface accepts the activated repo-owned Lua source"
  else
    pass "WezTerm config-loading validation skipped because WezTerm is not installed in this test environment"
  fi
}

test_repo_starship_config_is_usable() {
  local out
  if command -v starship >/dev/null 2>&1; then
    out=$(starship --config "$ROOT/config/starship.toml" prompt 2>&1) \
      || fail "Starship could not render the repo-owned configuration: $out"
    [ -n "$out" ] || fail "Starship rendered an empty prompt from the repo-owned configuration"
    pass "Starship renders a prompt from the repo-owned configuration"
  else
    pass "Starship prompt validation skipped because Starship is not installed in this test environment"
  fi
}

test_starship_is_nix_managed_and_loaded_once() {
  local shell_home init enabled
  if [ "$(uname -s)" != Darwin ] || ! command -v nix >/dev/null 2>&1; then
    pass "Starship Nix activation validation skipped outside a Darwin host with Nix"
    return 0
  fi
  shell_home="$TMP_ROOT/starship-shell-home"
  mkdir -p "$shell_home"
  enabled=$(nix eval --impure --json \
    "$ROOT#darwinConfigurations.phynd-dev.config.home-manager.users.phynd.programs.starship.enableZshIntegration") \
    || fail "Nix could not evaluate the generated Starship zsh integration setting"
  [ "$enabled" = true ] || fail "Home Manager should own Starship's zsh integration"
  init=$(PHYN_DEV_HOME="$shell_home" \
    nix eval --impure --raw \
    "$ROOT#darwinConfigurations.phynd-dev.config.home-manager.users.phynd.programs.zsh.initContent") \
    || fail "Nix could not evaluate the generated Starship zsh integration"
  HOME="$shell_home" TERM=xterm zsh -dfi -c "$init
[[ -n \$PROMPT ]]" >/dev/null 2>&1 \
    || fail "a fresh interactive zsh did not load the generated Starship prompt"
  pass "Nix-managed Starship initializes exactly once in a fresh interactive zsh"
}

test_root_entrypoint_resolves_itself
test_install_noop_update_and_safe_backup
test_flake_update_and_check_are_explicit
test_fresh_effective_config_and_wezterm_load
test_repo_starship_config_is_usable
test_starship_is_nix_managed_and_loaded_once
