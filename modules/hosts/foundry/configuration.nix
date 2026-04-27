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
      self.nixosModules.authentik
      self.nixosModules.crowdsec
      self.nixosModules.postgresql
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
    # available on this box; see docs/foundry/overview.md.
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
    # since the box has no TPM; see docs/foundry/operations.md.
    #
    # The ed25519 host key must live at /etc/secrets/initrd/ssh_host_ed25519_key
    # on the installed system. Generate it locally once and ship it with
    # nixos-anywhere --extra-files during install.
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

    # Public-but-hardened SSH. Key-only auth, root login off,
    # small AllowUsers list, MaxAuthTries=3 for brute-force noise. We
    # evaluated a Netbird mesh cutover (close public :22, SSH via mesh
    # only) and chose against it for this box: the security gain over
    # key-only SSH is marginal, while the mesh adds a third-party
    # coordinator dependency and an interactive enrollment step to every
    # fresh reinstall — both at odds with the "redeploy quickly if this
    # box crashes" goal. Admin-only internal services are
    # protected at the HTTP layer via Caddy + Authentik ForwardAuth, not
    # at the network layer.
    services.openssh = {
      enable = true;
      # Non-standard port for the running system. Two reasons:
      #   1. Drops bot scan traffic to ~0 — opportunistic scanners hit 22.
      #   2. Leaves port 22 free for Hetzner Robot's rescue system, which is
      #      PXE-booted and always listens on 22. Keeping our sshd off 22
      #      means no host-key collisions in known_hosts when switching
      #      between the two (no more `ssh-keygen -R foundry` dance).
      # This is security-by-obscurity for bot noise only — the real gate
      # is still key-only auth + MaxAuthTries + AllowUsers. Port 2222 is
      # the initrd LUKS-unlock sshd; keep it distinct from this one.
      # deploy-rs must match via `sshOpts` in modules/deploy.nix.
      ports = [62222];
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        KbdInteractiveAuthentication = false;
        MaxAuthTries = 3;
        AllowUsers = ["simon" "deploy" "foundryvtt-manager"];
      };
    };

    # Explicit firewall allow-list so the public surface is visible in
    # one place instead of implicit through `openFirewall` toggles on
    # individual modules.
    #   - 62222: main-system sshd (see `services.openssh.ports` above).
    #            The openssh module's `openFirewall = true` already opens
    #            whatever is in `ports`; listed here explicitly so the
    #            public surface is visible in one place.
    #   - 2222 : initrd LUKS-unlock sshd. The main-system firewall is
    #            inactive during initrd, so this rule is a defensive
    #            no-op post-boot — but listing it makes the intent
    #            explicit for anyone reading the config.
    #   - 80/443 are added by self.nixosModules.caddy so the
    #            port list lives next to the service that needs it.
    # Port 22 is deliberately NOT opened. Hetzner rescue PXE-boots its
    # own kernel so the production firewall is bypassed while rescue
    # runs — :22 is reachable there regardless. On the running system,
    # :22 stays closed, which also means prod and rescue have disjoint
    # known_hosts entries and never collide.
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [62222 2222];
    };

    # Unattended security updates. `operation = "boot"` stages
    # new generations into the bootloader without activating immediately,
    # so openssh/nginx don't restart mid-session — the next reboot picks
    # the new generation up. No `--update-input nixpkgs` here: the server
    # is a puller; the laptop and CI are the authority on what's in
    # flake.lock.
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
    # laptop and by deploy-rs / CI. The matching private key lives at
    # ~/.config/foundry-bootstrap/deploy_ed25519 on the laptop and as a GitHub
    # Actions secret.
    users.users.deploy = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFS7GObQq49TYnrSmYBKp6hfVaVw2w0wroMsA1w2HNd3 foundry-deploy"
      ];
    };

    # Operator account for managing the Foundry VTT service without full admin
    # rights. Can restart/stop/start the service via the sudo rules below, and
    # can read/write files in the data directory via group membership.
    users.users.foundryvtt-manager = {
      isNormalUser = true;
      extraGroups = ["foundryvtt"];
      openssh.authorizedKeys.keys = [
        # SSH public key — add when available
      ];
    };

    # Passwordless sudo for deploy user — required by deploy-rs (and
    # `nixos-rebuild --use-remote-sudo`) to invoke switch-to-configuration.
    # foundryvtt-manager gets targeted rules: only the specific systemctl
    # verbs for the foundryvtt.service, nothing else.
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
      {
        users = ["foundryvtt-manager"];
        commands = [
          {
            command = "/run/current-system/sw/bin/systemctl start foundryvtt.service";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl stop foundryvtt.service";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl restart foundryvtt.service";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl reload foundryvtt.service";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl status foundryvtt.service";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # UMask 0002 makes all files/dirs created by the Foundry process
    # group-writable, so foundryvtt-manager (in the foundryvtt group) can
    # edit them. StateDirectoryMode opens the top-level state dir to the group.
    # The tmpfiles rule retrofits the existing v14 directory on upgrades.
    systemd.services.foundryvtt.serviceConfig.UMask = lib.mkForce "0002";
    systemd.services.foundryvtt.serviceConfig.StateDirectoryMode = lib.mkForce "0770";
    systemd.tmpfiles.rules = [
      "d /var/lib/foundryvtt/v14 0770 foundryvtt foundryvtt -"
    ];

    # sops-nix: use the server's SSH ed25519 host key as the age decryption
    # key. The default `sops.age.sshKeyPaths` already points here, but being
    # explicit makes it less surprising. The corresponding age recipient
    # (derived via `ssh-to-age`) lives in `.sops.yaml` at the repo root.
    sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    sops.defaultSopsFile = ./secrets.yaml;

    # sops-nix smoke-test secret. After activation, `cat /run/secrets/test`
    # as root should print "hello from sops-nix". Remove once we have a
    # real secret referencing `secrets.yaml`.
    sops.secrets.test = {};

    # Must be set to the first NixOS release installed on this machine.
    # Do not change without reading the NixOS release notes.
    system.stateVersion = "25.11";
  };
}
