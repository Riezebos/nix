{inputs, ...}: {
  imports = [
    inputs.home-manager.flakeModules.home-manager
  ];

  systems = ["aarch64-darwin" "x86_64-linux"];
}
