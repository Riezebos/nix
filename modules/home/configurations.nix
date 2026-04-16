{
  self,
  inputs,
  ...
}: {
  flake.homeConfigurations = {
    "simon-darwin" = inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs-devenv.legacyPackages.aarch64-darwin;
      extraSpecialArgs = {flake = {inherit inputs;};};
      modules = [
        self.homeModules.shared
        {
          home.username = "simon";
          home.homeDirectory = "/Users/simon";
        }
      ];
    };
    "simon-m4" = inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs-devenv.legacyPackages.aarch64-darwin;
      extraSpecialArgs = {flake = {inherit inputs;};};
      modules = [
        self.homeModules.shared
        {
          home.username = "simon.riezebos";
          home.homeDirectory = "/Users/simon.riezebos";
        }
      ];
    };
    "simon-linux" = inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs-devenv.legacyPackages.x86_64-linux;
      extraSpecialArgs = {flake = {inherit inputs;};};
      modules = [
        self.homeModules.shared
        {
          home.username = "simon";
          home.homeDirectory = "/home/simon";
        }
      ];
    };
  };
}
