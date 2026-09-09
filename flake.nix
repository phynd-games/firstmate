{
  description = "phynd-dev macOS/Linux workstation and Firstmate environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    determinate.url = "github:DeterminateSystems/determinate";
    determinate.inputs.nixpkgs.follows = "nixpkgs";

    # Darwin-only: wired into darwinConfigurations below, never evaluated on Linux.
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    treehouse.url = "github:kunchenguid/treehouse";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nix-darwin,
      determinate,
      nix-homebrew,
      home-manager,
      treehouse,
      ...
    }:
    let
      lib = nixpkgs.lib;
      envOr = name: fallback:
        let value = builtins.getEnv name;
        in if value == "" then fallback else value;
      # PHYN_DEV_SYSTEM is exported by bin/phynd-dev from detected uname/arch;
      # builtins.currentSystem covers direct `nix` invocations outside that script.
      system = envOr "PHYN_DEV_SYSTEM" builtins.currentSystem;
      isLinux = lib.hasSuffix "-linux" system;
      user = envOr "PHYN_DEV_USER" "phynd";
      homeDirectory = envOr "PHYN_DEV_HOME" (if isLinux then "/home/${user}" else "/Users/${user}");
      repoRoot = envOr "PHYN_DEV_ROOT" self.outPath;
    in
    {
      darwinConfigurations."phynd-dev" = nix-darwin.lib.darwinSystem {
        inherit system;
        specialArgs = {
          inherit inputs repoRoot user homeDirectory;
        };
        modules = [
          determinate.darwinModules.default
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          ./nix/configuration.nix
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "phynd-dev-backup";
            home-manager.extraSpecialArgs = {
              inherit repoRoot treehouse user homeDirectory;
            };
            home-manager.users.${user} = import ./nix/home.nix;
          }
        ];
      };

      # Ordinary Linux (not NixOS): standalone Home Manager applies only the
      # portable nix/home.nix profile. No Darwin modules, Homebrew, or
      # darwin-rebuild reach this path; `phynd-dev` activates it with
      # `home-manager switch`, never `darwin-rebuild`.
      homeConfigurations."phynd-dev" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        extraSpecialArgs = {
          inherit repoRoot treehouse user homeDirectory;
        };
        modules = [ ./nix/home.nix ];
      };

      packages = if isLinux then { } else {
        ${system}.darwin-rebuild = nix-darwin.packages.${system}.darwin-rebuild;
      };
      formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt;
    };
}
