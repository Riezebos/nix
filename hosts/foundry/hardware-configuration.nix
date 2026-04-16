{
  lib,
  modulesPath,
  ...
}: {
  # Placeholder — will be overwritten by `nixos-anywhere --generate-hardware-config`
  # during Phase 1 of PLAN.md. Do not edit by hand after that point.
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
  ];
  boot.initrd.kernelModules = [
    "dm-snapshot"
    "md_mod"
    "raid1"
  ];
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  # Placeholder root fs entry so eval succeeds before disko has written the
  # real fileSystems via its nixos module. Disko will override these at install
  # time; nixos-anywhere then replaces this entire file.
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  swapDevices = [];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
}
