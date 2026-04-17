{
  self,
  inputs,
  ...
}: {
  flake.nixosModules.foundryConfiguration = {
    config,
    pkgs,
    lib,
    ...
  }: {
    imports = [
      self.nixosModules.foundryHardware
      self.nixosModules.foundryDisko
      inputs.disko.nixosModules.disko
      inputs.sops-nix.nixosModules.sops
    ];

    networking.hostName = "foundry";
    networking.useDHCP = lib.mkDefault true;
    time.timeZone = "Europe/Amsterdam";

    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["root" "@wheel"];
    };

    # Legacy BIOS GRUB with mirrored /boot on both NVMes. No TPM, no UEFI
    # available on this box — see PLAN.md "Hardware inventory".
    boot.loader.grub = {
      enable = true;
      efiSupport = false;
      # Disko populates `grub.devices` from its disk list, which would otherwise
      # auto-generate a third `mirroredBoots` entry mounted at /boot and each
      # disk would end up listed twice, tripping the "duplicated devices"
      # assertion. We handle the install-to-both-disks ourselves via the
      # explicit `mirroredBoots` below, so force `devices` empty.
      devices = lib.mkForce [];
      mirroredBoots = [
        {
          devices = ["/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501871"];
          path = "/boot-1";
        }
        {
          devices = ["/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501883"];
          path = "/boot-2";
        }
      ];
    };
    boot.loader.efi.canTouchEfiVariables = false;

    # Modern systemd-based initrd — cleaner LUKS + networking handling.
    boot.initrd.systemd.enable = true;

    # Minimal mdmon config — avoids the "Neither MAILADDR nor PROGRAM has been
    # set" eval warning. When you want real monitoring, wire up `PROGRAM` to a
    # script that hits a Healthchecks.io-style alert URL.
    boot.swraid.mdadmConf = ''
      MAILADDR root
    '';

    # SSH-in-initrd for LUKS unlock. This is the primary unlock mechanism
    # since the box has no TPM (see Phase 1 of PLAN.md).
    #
    # The ed25519 host key must live at /etc/secrets/initrd/ssh_host_ed25519_key
    # on the installed system. Generate it locally once and ship it with
    # nixos-anywhere --extra-files during Phase 1.
    boot.initrd.network.enable = true;
    boot.initrd.network.ssh = {
      enable = true;
      port = 2222;
      hostKeys = ["/etc/secrets/initrd/ssh_host_ed25519_key"];
      authorizedKeys = config.users.users.simon.openssh.authorizedKeys.keys;
      # Drop the SSH session straight into the LUKS passphrase prompt instead
      # of a root shell. Without this, systemd-initrd leaves you at `ash` and
      # you have to run `systemd-tty-ask-password-agent` by hand. The binary is
      # available in initrd PATH; `--query` answers all pending prompts and exits.
      extraConfig = ''
        ForceCommand systemd-tty-ask-password-agent --query
      '';
    };
    # Intel I219-LM onboard NIC. Confirm from the generated
    # hosts/foundry/hardware-configuration.nix after first install and adjust
    # if the detected driver differs.
    boot.initrd.availableKernelModules = ["e1000e"];

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        KbdInteractiveAuthentication = false;
      };
    };

    users.users.simon = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDqYAISil8Imbq2p1wUZ3ULsuVJl8C7YIAJYnKeU4/2m info@datagiant.org"
      ];
    };

    # Dedicated activation user. Used by `nixos-rebuild --target-host` from the
    # laptop today, and by deploy-rs / CI once Phase 3b lands. The matching
    # private key lives at ~/.config/foundry-bootstrap/deploy_ed25519 on the
    # laptop; add it as a GitHub Actions secret during Phase 3b.
    users.users.deploy = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFS7GObQq49TYnrSmYBKp6hfVaVw2w0wroMsA1w2HNd3 foundry-deploy"
      ];
    };

    # Passwordless sudo for deploy user — required by deploy-rs (and
    # `nixos-rebuild --use-remote-sudo`) to invoke switch-to-configuration.
    security.sudo.extraRules = [
      {
        users = ["deploy"];
        commands = [
          {
            command = "ALL";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # sops-nix: use the server's SSH ed25519 host key as the age decryption
    # key. The default `sops.age.sshKeyPaths` already points here, but being
    # explicit makes it less surprising. The corresponding age recipient
    # (derived via `ssh-to-age`) lives in `.sops.yaml` at the repo root.
    sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    sops.defaultSopsFile = ./secrets.yaml;

    # Phase 2 smoke-test secret. After activation, `cat /run/secrets/test`
    # as root should print "hello from sops-nix". Remove once we have a
    # real secret referencing `secrets.yaml`.
    sops.secrets.test = {};

    # Must be set to the first NixOS release installed on this machine.
    # Do not change without reading the NixOS release notes.
    system.stateVersion = "25.11";
  };
}
