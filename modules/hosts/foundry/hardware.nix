{...}: {
  # Placeholder hardware module. During Phase 1 (nixos-anywhere), regenerate the
  # real hardware configuration at ../../../hosts/foundry/hardware-configuration.nix via:
  #
  #   nix run github:nix-community/nixos-anywhere -- \
  #     --flake .#foundry \
  #     --generate-hardware-config nixos-generate-config \
  #     ./hosts/foundry/hardware-configuration.nix \
  #     root@<rescue-ip>
  #
  # The generated file is a plain NixOS module (not a flake-parts module), so it
  # lives outside `modules/` to avoid being auto-imported by import-tree.
  flake.nixosModules.foundryHardware = ../../../hosts/foundry/hardware-configuration.nix;
}
