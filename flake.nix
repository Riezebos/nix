{
  description = "Hopefully this flake will become the flake for all my devices?";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    darwin.url = "github:LnL7/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    darwin,
    home-manager,
    nixpkgs,
    ...
  }: {
    darwinConfigurations."Simons-MacBook-Air" = darwin.lib.darwinSystem {
      modules = [./darwin/system.nix];
    };

    homeConfigurations = {
      "simon-darwin" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        modules = [
          ./shared/home.nix
          {
            home.username = "simon";
            home.homeDirectory = "/Users/simon";
          }
        ];
      };
      "simon-m4" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        modules = [
          ./shared/home.nix
          {
            home.username = "simon.riezebos";
            home.homeDirectory = "/Users/simon.riezebos";
          }
        ];
      };
      "simon-linux" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
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
}
