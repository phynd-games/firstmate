{
  pkgs,
  user,
  homeDirectory,
  ...
}:

{
  determinateNix.enable = true;

  nixpkgs.config.allowUnfree = true;
  system.primaryUser = user;
  users.users.${user}.home = homeDirectory;
  system.stateVersion = 6;

  environment.systemPackages = with pkgs; [
    curl
    git
    jq
    tmux
  ];

  system.defaults = {
    NSGlobalDomain = {
      AppleInterfaceStyle = "Dark";
      AppleShowAllExtensions = true;
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
      _HIHideMenuBar = true;
    };
    dock.autohide = true;
    finder.CreateDesktop = false;
    finder.FXPreferredViewStyle = "Nlsv";
    trackpad.Clicking = true;
  };

  nix-homebrew = {
    enable = true;
    inherit user;
    autoMigrate = true;
    enableRosetta = pkgs.stdenv.hostPlatform.isAarch64;
  };

  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = false;
      cleanup = "none";
      upgrade = false;
    };
    brews = [
      {
        name = "herdr";
        restart_service = "changed";
      }
    ];
    casks = [
      "opensuperwhisper"
      "wezterm"
    ];
  };
}
