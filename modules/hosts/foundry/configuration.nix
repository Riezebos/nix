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

    # Public SSH is closed by the explicit `networking.firewall` allow-list
    # below; openFirewall = false stops the openssh module from adding port
    # 22 to allowedTCPPorts (which would undo that). Port 22 is opened only
    # on the netbird mesh interface further down.
    services.openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        KbdInteractiveAuthentication = false;
        # Phase 1c: tighten brute-force surface. The firewall cutover in this
        # commit closes public SSH entirely; these auth settings harden the
        # brief window during earlier steps. AllowUsers matches the two real
        # accounts on this box.
        MaxAuthTries = 3;
        AllowUsers = ["simon" "deploy"];
      };
    };

    # Phase 1c: Netbird mesh client. The laptop is already on the mesh via
    # the macOS GUI client; this brings foundry on too. Interactive enrollment
    # is a one-shot `sudo netbird-foundry up` from the server after first
    # activation — prints an SSO URL to open on the laptop.
    #
    # Pinned to `nixpkgs-unstable` (vanilla) rather than `nixpkgs-25.11`'s
    # 0.60.2. Netbird releases every few days and 25.11 sits many minor
    # versions behind — for a networking/security tool that moves this fast,
    # stale is the bigger risk than rolling surprises. We also want upstream
    # features that only land on newer releases (e.g. the reverse-proxy
    # workflow) without waiting for the next NixOS stable. Only this *package*
    # is on unstable; the NixOS module (systemd hardening, polkit, config
    # merge) stays on 25.11. Do NOT pull this from `nixpkgs-devenv` — its
    # patched nixpkgs triggers an x86_64-linux IFD during eval that breaks
    # laptop-driven (aarch64-darwin) `nixos-rebuild`.
    services.netbird.package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.netbird;

    # Defaults we're deliberately accepting:
    #   interface = "nb-foundry"   (module default: "nb-${name}")
    #   hardened = true            (dedicated system user, minimal caps)
    #   openFirewall = true        (adds 51820/udp to public firewall
    #                              for direct peer-to-peer hole-punching;
    #                              WireGuard's crypto rejects anything
    #                              without a valid key, so not a new
    #                              attack surface)
    services.netbird.clients.foundry.port = 51820;

    # Phase 1c firewall cutover. Explicit allow-list, not "defaults plus
    # openFirewall toggles". After activation:
    #   - Public TCP: only port 2222 (initrd LUKS unlock — must stay public,
    #     the netbird client can't run before root FS is decrypted).
    #   - Public UDP: 51820 (added automatically by the netbird client module
    #     for direct peer-to-peer). If you ever want to force all mesh
    #     traffic through netbird's relays instead, set
    #     services.netbird.clients.foundry.openFirewall = false.
    #   - Mesh-only: real SSH (port 22) on the nb-foundry interface. The
    #     netbird module also auto-adds 5353/udp and 22054/udp on nb-foundry
    #     for its DNS forwarder; our entry merges with those.
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [2222];
      interfaces."nb-foundry".allowedTCPPorts = [22];
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
