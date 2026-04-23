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
      self.nixosModules.foundryvtt
      self.nixosModules.caddy
      self.nixosModules.restic
      self.nixosModules.monitoring
      self.nixosModules.alerting
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

    # Phase 1c: public-but-hardened SSH. Key-only auth, root login off,
    # small AllowUsers list, MaxAuthTries=3 for brute-force noise. We
    # evaluated a Netbird mesh cutover (close public :22, SSH via mesh
    # only) and chose against it for this box: the security gain over
    # key-only SSH is marginal, while the mesh adds a third-party
    # coordinator dependency and an interactive enrollment step to every
    # fresh reinstall — both at odds with the "redeploy quickly if this
    # box crashes" goal. Admin-only internal services (Phase 4+) will be
    # protected at the HTTP layer via Caddy + Authentik ForwardAuth, not
    # at the network layer.
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        KbdInteractiveAuthentication = false;
        MaxAuthTries = 3;
        AllowUsers = ["simon" "deploy"];
      };
    };

    # Explicit firewall allow-list so the public surface is visible in
    # one place instead of implicit through `openFirewall` toggles on
    # individual modules.
    #   - 22   : SSH (added by `services.openssh` via its default
    #            openFirewall = true — listed here for documentation).
    #   - 2222 : initrd LUKS-unlock sshd. The main-system firewall is
    #            inactive during initrd, so this rule is a defensive
    #            no-op post-boot — but listing it makes the intent
    #            explicit for anyone reading the config.
    #   - 80/443 are added by self.nixosModules.caddy (Phase 4) so the
    #            port list lives next to the service that needs it.
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [22 2222];
    };

    # Phase 1c: unattended security updates. `operation = "boot"` stages
    # new generations into the bootloader without activating immediately,
    # so openssh/nginx don't restart mid-session — the next reboot picks
    # the new generation up. No `--update-input nixpkgs` here: the server
    # is a puller, the laptop (and later CI in Phase 3c) is the authority
    # on what's in flake.lock. When Phase 3c lands and CI starts bumping
    # the lock weekly, this stays unchanged.
    system.autoUpgrade = {
      enable = true;
      flake = "github:Riezebos/nix";
      flags = ["-L"];
      dates = "04:30";
      randomizedDelaySec = "45min";
      operation = "boot";
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
