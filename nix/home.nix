{
  config,
  pkgs,
  user,
  homeDirectory,
  repoRoot,
  treehouse,
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
  };

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    initContent = ''
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
