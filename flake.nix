{
  description = "Hopefully this flake will become the flake for all my devices?";

  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";

    darwin.url = "github:LnL7/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      # Import home-manager's flake module for proper homeConfigurations merging
      imports = [
        inputs.home-manager.flakeModules.home-manager
      ];

      # Systems for perSystem (used for devShells, packages, etc. if needed)
      systems = ["aarch64-darwin" "x86_64-linux"];

      # Flake-level outputs (not per-system)
      flake = {
        darwinConfigurations."Simons-MacBook-Air" = inputs.darwin.lib.darwinSystem {
          modules = [./darwin/system.nix];
        };

        homeConfigurations = {
          "simon-darwin" = inputs.home-manager.lib.homeManagerConfiguration {
            pkgs = inputs.nixpkgs.legacyPackages.aarch64-darwin;
            extraSpecialArgs = {flake = {inherit inputs;};};
            modules = [
              ./shared/home.nix
              {
                home.username = "simon";
                home.homeDirectory = "/Users/simon";
              }
            ];
          };
          "simon-m4" = inputs.home-manager.lib.homeManagerConfiguration {
            pkgs = inputs.nixpkgs.legacyPackages.aarch64-darwin;
            extraSpecialArgs = {flake = {inherit inputs;};};
            modules = [
              ./shared/home.nix
              {
                home.username = "simon.riezebos";
                home.homeDirectory = "/Users/simon.riezebos";
              }
            ];
          };
          "simon-linux" = inputs.home-manager.lib.homeManagerConfiguration {
            pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
            extraSpecialArgs = {flake = {inherit inputs;};};
            modules = [
              ./shared/home.nix
              {
                home.username = "simon";
                home.homeDirectory = "/home/simon";
              }
            ];
          };
        };
      };
    };
}
