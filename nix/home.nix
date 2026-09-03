{
  config,
  pkgs,
  user,
  homeDirectory,
  repoRoot,
  treehouse,
  lib,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  npmPrefix = "${homeDirectory}/.local/share/phynd-dev/npm";
  existingZshDir = "${homeDirectory}/.local/state/phynd-dev/existing-zsh";
in
{
  home.username = user;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "24.11";

  home.packages = with pkgs; [
    actionlint
    basedpyright
    fd
    fresh-editor
    fzf
    gh
    jq
    lua-language-server
    nerd-fonts.hack
    nodejs_24
    ripgrep
    rust-analyzer
    shellcheck
    starship
    treehouse.packages.${system}.default
    typescript-language-server
  ];

  fonts.fontconfig.enable = true;

  home.sessionPath = [
    "${homeDirectory}/.local/bin"
    "${npmPrefix}/bin"
  ];

  home.sessionVariables = {
    EDITOR = "fresh";
    FIRSTMATE_HOME = repoRoot;
    NPM_CONFIG_PREFIX = npmPrefix;
    ZDOTDIR = "${homeDirectory}/.config/zsh";
  };

  programs.zsh = {
    enable = true;
    dotDir = ".config/zsh";
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    envExtra = ''
      if [[ -r "${existingZshDir}/.zshenv" ]]; then
        source "${existingZshDir}/.zshenv"
      fi
      if [[ -r "$HOME/.zshenv" && ! -L "$HOME/.zshenv" && "$HOME/.zshenv" != "$ZDOTDIR/.zshenv" ]]; then
        source "$HOME/.zshenv"
      fi
    '';
    profileExtra = ''
      if [[ -r "$HOME/.zprofile" && "$HOME/.zprofile" != "$ZDOTDIR/.zprofile" ]]; then
        source "$HOME/.zprofile"
      fi
    '';
    loginExtra = ''
      if [[ -r "$HOME/.zlogin" && "$HOME/.zlogin" != "$ZDOTDIR/.zlogin" ]]; then
        source "$HOME/.zlogin"
      fi
    '';
    initContent = lib.mkBefore ''
      starship() {
        if [[ "${1-}:${2-}" == "init:zsh" ]]; then
          return 0
        fi
        command starship "$@"
      }
      if [[ -r "$HOME/.zshrc" && "$HOME/.zshrc" != "$ZDOTDIR/.zshrc" ]]; then
        source "$HOME/.zshrc"
      fi
      unset -f starship
      bindkey '^f' autosuggest-accept
    '';
    shellAliases = {
      ".." = "cd ..";
      ghf = "gnhf";
      phynd = "phynd-dev launch";
    };
  };

  programs.starship = {
    enable = true;
    settings = builtins.fromTOML (builtins.readFile "${repoRoot}/config/starship.toml");
  };

  home.file.".local/bin/phynd-dev" = {
    source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/bin/phynd-dev";
  };

}
