{
  self,
  inputs,
  ...
}: {
  flake.nixosConfigurations.foundry = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {inherit inputs self;};
    modules = [
      self.nixosModules.foundryConfiguration
    ];
  };
}
