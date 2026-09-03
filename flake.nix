{
  description = "phynd-dev macOS workstation and Firstmate environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    determinate.url = "github:DeterminateSystems/determinate";
    determinate.inputs.nixpkgs.follows = "nixpkgs";

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
      envOr = name: fallback:
        let value = builtins.getEnv name;
        in if value == "" then fallback else value;
      system = envOr "PHYN_DEV_SYSTEM" "aarch64-darwin";
      user = envOr "PHYN_DEV_USER" "phynd";
      homeDirectory = envOr "PHYN_DEV_HOME" "/Users/phynd";
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

      packages.${system}.darwin-rebuild = nix-darwin.packages.${system}.darwin-rebuild;
      formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt;
    };
}
