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
    initContent = lib.mkBefore ''
      if [[ -r "$HOME/.zshrc" && "$HOME/.zshrc" != "$ZDOTDIR/.zshrc" ]]; then
        source "$HOME/.zshrc"
      fi
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
