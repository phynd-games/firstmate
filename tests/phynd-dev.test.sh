#!/usr/bin/env bash
# Behavior tests for the isolated phynd-dev lifecycle and repo-owned tools.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
TMP_ROOT=$(fm_test_tmproot phynd-dev-tests)
REAL_PATH=$PATH

make_fake_phynd_tools() {
  local dir=$1 tool
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
mkdir -p "$PHYN_DEV_HOME/.local/bin"
mkdir -p "$PHYN_DEV_HOME/.local/state/phynd-dev/home-manager"
ln -sfn "$PHYN_DEV_ROOT/bin/phynd-dev" \
  "$PHYN_DEV_HOME/.local/state/phynd-dev/home-manager/phynd-dev"
ln -sfn "$PHYN_DEV_HOME/.local/state/phynd-dev/home-manager/phynd-dev" \
  "$PHYN_DEV_HOME/.local/bin/phynd-dev"
SH
  chmod +x "$dir/nix" "$dir/darwin-rebuild"
  for tool in actionlint basedpyright basedpyright-langserver fd fresh fzf gh git jq \
    lua-language-server node npm npx rg rust-analyzer shellcheck starship treehouse \
    typescript-language-server tmux curl; do
    cat > "$dir/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '❯'
SH
    chmod +x "$dir/$tool"
  done
  PHYN_TEST_NIX_PROFILE=$dir
  PHYN_TEST_GLOBALBIN=
  PHYN_TEST_SKIP_TOOLS=1
  export PHYN_TEST_NIX_PROFILE PHYN_TEST_GLOBALBIN PHYN_TEST_SKIP_TOOLS
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
  local home=$1 xdg=$2 state=$3 npm_prefix=$4 log=$5 rebuild_log=$6 path
  shift 6
  path="$PHYN_TEST_FAKEBIN:$REAL_PATH"
  if [ -n "${PHYN_TEST_GLOBALBIN:-}" ]; then
    path="$PHYN_TEST_FAKEBIN:$PHYN_TEST_GLOBALBIN:$REAL_PATH"
  fi
  HOME="$home" \
  PHYN_DEV_HOME="$home" \
  PHYN_DEV_XDG_CONFIG_HOME="$xdg" \
  PHYN_DEV_STATE_DIR="$state" \
  PHYN_DEV_NPM_PREFIX="$npm_prefix" \
  PHYN_DEV_USER="$(id -un)" \
  PHYN_DEV_SKIP_SUDO=1 \
  PHYN_DEV_SKIP_TOOLS="${PHYN_TEST_SKIP_TOOLS:-1}" \
  PHYN_DEV_UNAME_S=Darwin \
  PHYN_DEV_UNAME_M=arm64 \
  PHYN_DEV_NIX_LOG="$log" \
  PHYN_DEV_REBUILD_LOG="$rebuild_log" \
  PHYN_DEV_NIX_PROFILE="${PHYN_TEST_NIX_PROFILE:-$home/nix-profile/bin}" \
  PATH="$path" \
  "$@"
}

test_npm_tools_ignore_stale_path_commands() {
  local case_dir fixture home xdg state npm_prefix nix_log rebuild_log npm_log out count
  case_dir="$TMP_ROOT/npm-tools"
  fixture="$case_dir/repo"
  home="$case_dir/home"
  xdg="$home/.config"
  state="$home/.local/state/phynd-dev"
  npm_prefix="$home/.local/share/phynd-dev/npm"
  nix_log="$case_dir/nix.log"
  rebuild_log="$case_dir/rebuild.log"
  npm_log="$case_dir/npm.log"
  mkdir -p "$home"
  make_phynd_fixture "$ROOT" "$fixture"
  make_fake_phynd_tools "$case_dir/fakebin"
  PHYN_TEST_FAKEBIN="$case_dir/fakebin"
  export PHYN_TEST_FAKEBIN
  cat > "$case_dir/fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PHYN_DEV_NPM_LOG:?}"
mkdir -p "$NPM_CONFIG_PREFIX/bin"
for tool in pi gnhf gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi; do
  cat > "$NPM_CONFIG_PREFIX/bin/$tool" <<'TOOL'
#!/usr/bin/env bash
exit 0
TOOL
  chmod +x "$NPM_CONFIG_PREFIX/bin/$tool"
done
SH
  chmod +x "$case_dir/fakebin/npm"
  mkdir -p "$case_dir/globalbin"
  for tool in no-mistakes pi gnhf gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi; do
    cat > "$case_dir/globalbin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$case_dir/globalbin/$tool"
  done
  PHYN_TEST_GLOBALBIN="$case_dir/globalbin"
  PHYN_TEST_SKIP_TOOLS=0
  PHYN_DEV_NPM_LOG="$npm_log"
  export PHYN_TEST_GLOBALBIN PHYN_TEST_SKIP_TOOLS PHYN_DEV_NPM_LOG
  : > "$nix_log"
  : > "$rebuild_log"
  : > "$npm_log"

  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" "$nix_log" "$rebuild_log" \
    "$fixture/phynd-dev" install) || fail "npm-tool reconciliation failed: $out"
  count=$(wc -l < "$npm_log" | tr -d ' ')
  [ "$count" -eq 7 ] || fail "initial install should reconcile each npm tool once"
  rm "$npm_prefix/bin/"*
  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" "$nix_log" "$rebuild_log" \
    "$fixture/phynd-dev" install) || fail "npm-tool repair failed: $out"
  count=$(wc -l < "$npm_log" | tr -d ' ')
  [ "$count" -eq 14 ] || fail "stale global npm tools should not suppress repair"
  pass "npm-managed tools ignore stale commands outside the managed prefix"
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

  out=$(cd /tmp && HOME="$home" PHYN_DEV_HOME="$home" \
    PHYN_DEV_UNAME_S=Darwin PHYN_DEV_UNAME_M=arm64 \
    "$home/.local/bin/phynd-dev" status) \
    || fail "the Home Manager-installed phynd-dev command failed: $out"
  assert_contains "$out" "checkout: $fixture" \
    "the installed phynd-dev command should resolve its repository root"

  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" \
    "$nix_log" "$rebuild_log" "$fixture/phynd-dev" install) \
    || fail "second phynd-dev install failed: $out"
  assert_contains "$out" "already converged" "second install should report a no-op"
  count=$(wc -l < "$rebuild_log" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "second install should not reactivate nix-darwin"

  mkdir -p "$case_dir/globalbin"
  cp "$case_dir/fakebin/starship" "$case_dir/globalbin/starship"
  chmod +x "$case_dir/globalbin/starship"
  rm "$case_dir/fakebin/starship"
  PHYN_TEST_GLOBALBIN="$case_dir/globalbin"
  export PHYN_TEST_GLOBALBIN
  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" \
    "$nix_log" "$rebuild_log" "$fixture/phynd-dev" install) \
    || fail "phynd-dev should repair missing Nix-managed packages: $out"
  assert_contains "$out" "applying pinned nix-darwin" \
    "a missing managed package should invalidate the activation no-op"
  count=$(wc -l < "$rebuild_log" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "missing managed package should trigger one reactivation"
  cat > "$case_dir/fakebin/starship" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '❯'
SH
  chmod +x "$case_dir/fakebin/starship"

  printf '\n# later repo configuration revision\n' >> "$fixture/config/starship.toml"
  out=$(phynd_env "$home" "$xdg" "$state" "$npm_prefix" \
    "$nix_log" "$rebuild_log" "$fixture/phynd-dev" update) \
    || fail "phynd-dev update failed: $out"
  assert_contains "$out" "applying pinned nix-darwin" "changed configuration should reactivate"
  count=$(wc -l < "$rebuild_log" | tr -d ' ')
  [ "$count" -eq 3 ] || fail "updated configuration should activate once more"
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
  local shell_home zsh_dir zshrc enabled out
  if [ "$(uname -s)" != Darwin ] || ! command -v nix >/dev/null 2>&1 || \
    ! command -v zsh >/dev/null 2>&1; then
    pass "Starship Nix activation validation skipped outside a Darwin host with Nix"
    return 0
  fi
  shell_home="$TMP_ROOT/starship-shell-home"
  mkdir -p "$shell_home"
  enabled=$(nix eval --impure --json \
    "$ROOT#darwinConfigurations.phynd-dev.config.home-manager.users.phynd.programs.starship.enableZshIntegration") \
    || fail "Nix could not evaluate the generated Starship zsh integration setting"
  [ "$enabled" = true ] || fail "Home Manager should own Starship's zsh integration"
  zshrc=$(PHYN_DEV_HOME="$shell_home" \
    nix eval --impure --raw \
    "$ROOT#darwinConfigurations.phynd-dev.config.home-manager.users.phynd.home.file.\".zshrc\".text") \
    || fail "Nix could not evaluate the generated interactive zsh configuration"
  zsh_dir="$shell_home/zsh"
  mkdir -p "$zsh_dir"
  printf '%s\n' "$zshrc" > "$zsh_dir/.zshrc"
  out=$(HOME="$shell_home" ZDOTDIR="$zsh_dir" TERM=xterm PATH="$PATH" \
    zsh -di -c 'print -P -- "$PROMPT"' 2>&1) \
    || fail "a fresh interactive zsh could not load the generated configuration: $out"
  assert_contains "$out" "❯" \
    "a fresh interactive zsh should render the repo-owned Starship prompt"
  pass "Nix-managed Starship renders through the generated interactive zsh configuration"
}

test_root_entrypoint_resolves_itself
test_npm_tools_ignore_stale_path_commands
test_install_noop_update_and_safe_backup
test_flake_update_and_check_are_explicit
test_fresh_effective_config_and_wezterm_load
test_repo_starship_config_is_usable
test_starship_is_nix_managed_and_loaded_once
