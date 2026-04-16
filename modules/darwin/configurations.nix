{
  self,
  inputs,
  ...
}: {
  flake.darwinConfigurations."Simons-MacBook-Air" = inputs.darwin.lib.darwinSystem {
    modules = [self.darwinModules.system];
  };
}
