**The phased plan**

Each phase leaves you with a working system. Don't move to the next until the current one is solid.

**Hardware inventory (Hetzner auction server, surveyed April 2026)**

This section records the concrete hardware reality this plan is tailored to. If any of this changes (replacement box, hardware upgrade, moving to a different provider), revisit every decision in Phase 1.

- **Chassis / board**: ASUS WS C246 DC workstation board (AMI BIOS v0803, 2021-05-12). No BMC / no iDRAC — BIOS access requires paid Hetzner KVM/remote-hands.
- **CPU**: Intel Xeon E-2176G (Coffee Lake, 6C/12T, 3.7 GHz).
- **RAM**: 4× 16 GB DDR4 ECC = 64 GB.
- **Disks**: 2× Samsung PM983 U.2 NVMe 960 GB (MZQLB960HAJR), enterprise-grade with power-loss protection. Stable `by-id` paths:
  - `/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501871`
  - `/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501883`
- **NIC**: Intel I219-LM 1 GbE (onboard), interface name TBD after NixOS install.
- **Firmware mode**: BIOS reports "UEFI is supported" in characteristics, but the unit is currently configured and booted in **Legacy/CSM mode**. Switching to UEFI requires BIOS access → KVM session.
- **TPM**: motherboard has a TPM header (SMBIOS port designator "TPM"), but no TPM device is present or active (`modprobe tpm_crb` / `tpm_tis` find nothing; `/dev/tpm*` does not exist). Intel PTT (firmware TPM, supported by the C246 chipset) is disabled in BIOS. Without BIOS access, no TPM.
- **Conclusion**: this plan commits to **Legacy BIOS + GRUB + LUKS + SSH-in-initrd unlock** (no TPM auto-unlock). See Phase 1. A future BIOS-toggling session (UEFI + PTT + Secure Boot + TPM-bound unlock) is recorded as an optional upgrade path but not required.

**Rollout progress (as of 2026-04-20)**

- **Phase 0** (repo restructure + local tooling): done. Repo uses import-tree / flake-parts; gitleaks pre-commit active.
- **Phase 1** (bare NixOS install + mdraid RAID1 + LUKS + SSH-initrd unlock): done. Box boots and reboots clean.
- **Phase 1b** (Keychain-integrated `foundry-unlock`): done. Helper lives in `modules/home/shared.nix`.
- **Phase 1c** (SSH hardening + firewall + unattended upgrades): deployed 2026-04-20 (commit `cbb089e`). Netbird mesh approach was evaluated and reverted — see the "Decision: no network mesh" note in Phase 1c.
- **Phase 2** (sops-nix): done. Smoke-test secret is provisioned and decrypting at activation time.
- **Phase 3** (GitHub Actions CI + deploy-rs + weekly flake-lock PR): workflows and `modules/deploy.nix` landed 2026-04-20. Goes live on push to main once the repo secrets/vars listed under "Phase 3 — required repo config" are set.
- **Phase 4 and beyond** (Foundry migration, backups, monitoring, extras): pending.

Keep this block current — one line per phase, updated when a phase flips from pending → deployed or when the approach changes.

**Phase 0: Restructure existing repo + foundations**

Goals: migrate your existing `nix` GitHub repo to the `import-tree` module pattern, add server tooling locally, generate keys.

**0a: Local tooling**

1. You already have Nix with flakes enabled
2. You already have `sops`, `age`, `ssh-to-age` in your `home.packages` — verify they work: `sops --version`, `age --version`, `ssh-to-age --version`
3. Generate your personal age key (if you haven't already): `age-keygen -o ~/.config/sops/age/keys.txt`
4. **Add a `Host foundry` block to `~/.ssh/config` right now**, before any host-specific file exists in the repo. Everything that follows — Phase 1b's unlock helper, `server_notes.md` command examples, `nixos-rebuild --target-host` invocations — refers to the box as `foundry`. The real IP lives on the laptop and nowhere else. This repo is public; its production IP being published too hands an attacker an exact, unambiguous target to start probing, for zero operational benefit.

   ```
   Host foundry
       HostName <server-ip>
       User simon
       Port 22
       IdentityFile ~/.ssh/id_ed25519
   ```

   Anything that needs the real IP at runtime (e.g. `nc` port-probes, which don't honor SSH config) resolves it via `ssh -G foundry | awk '/^hostname /{print $2}'`. No script ever hardcodes the IP.

**0b: Restructure the repo to use import-tree**

Your current repo has a flat structure (`shared/home.nix`, `darwin/system.nix`) with explicit imports in `flake.nix`. The target is the vimjoyer flake-parts pattern where `import-tree` auto-loads everything under `modules/`.

Current structure:
```
flake.nix
shared/home.nix
darwin/system.nix
```

Target structure:
```
flake.nix                          # simplified: mkFlake + import-tree ./modules
.sops.yaml                         # new
modules/
  parts.nix                        # systems list
  home/
    configurations.nix             # homeConfigurations (simon-darwin, simon-m4, simon-linux)
    shared.nix                     # flake.homeModules.shared (your current shared/home.nix)
  darwin/
    configurations.nix             # darwinConfigurations."Simons-MacBook-Air"
    system.nix                     # flake.darwinModules.system (your current darwin/system.nix)
  hosts/
    foundry/
      default.nix                  # flake.nixosConfigurations.foundry
      configuration.nix            # flake.nixosModules.foundryConfiguration
      hardware.nix                 # flake.nixosModules.foundryHardware (generated during install)
      disko.nix                    # flake.nixosModules.foundryDisko
      secrets.yaml                 # sops-encrypted
  features/                        # reusable NixOS modules (empty for now)
```

Steps:

1. Create a branch for the restructure
2. Update `flake.nix` to use **two independent nixpkgs inputs** — stable for the server, devenv-rolling for Home Manager. Nothing has to share, and the `follows` graph routes each downstream input at the channel it belongs to. Full shape:

   ```nix
   {
     inputs = {
       # Server (and anything else that wants stability)
       nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

       # Home Manager package pool (rolling, devenv-patched)
       nixpkgs-devenv.url = "github:cachix/devenv-nixpkgs/rolling";

       home-manager.url = "github:nix-community/home-manager";
       home-manager.inputs.nixpkgs.follows = "nixpkgs-devenv";

       darwin.url = "github:LnL7/nix-darwin";
       darwin.inputs.nixpkgs.follows = "nixpkgs-devenv";

       flake-parts.url = "github:hercules-ci/flake-parts";
       import-tree.url = "github:vic/import-tree";

       disko.url = "github:nix-community/disko";
       disko.inputs.nixpkgs.follows = "nixpkgs";

       sops-nix.url = "github:Mic92/sops-nix";
       sops-nix.inputs.nixpkgs.follows = "nixpkgs";

       deploy-rs.url = "github:serokell/deploy-rs";
       deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
     };

     outputs = inputs: inputs.flake-parts.lib.mkFlake
       { inherit inputs; }
       (inputs.import-tree ./modules);
   }
   ```

   Key points:
   - **Don't add `nixos-anywhere`** as a flake input — it's a CLI tool, use it via `nix run github:nix-community/nixos-anywhere`.
   - **Don't use `nixos-unstable` or `devenv-nixpkgs/rolling` for the server.** Weekly auto-flake-update on a rolling channel can drag in kernel ABI changes, systemd behavior changes, or nginx/nodejs updates that break Foundry. Keep the server on `nixos-25.11`.
   - **Home Manager stays on `devenv-nixpkgs/rolling`** via the `follows` on `home-manager` (and `darwin`, since your Darwin config is also a laptop concern). You keep fresh packages + devenv compatibility on the laptop without that risk bleeding onto the server.
   - When you construct `homeConfigurations.*`, pass `pkgs = inputs.nixpkgs-devenv.legacyPackages.<arch>;`. When you construct `nixosConfigurations.foundry`, use `inputs.nixpkgs.lib.nixosSystem`. Each config's nixpkgs root is decided by what you pass it at construction time — individual modules don't have to care.
   - The server never evaluates `nixpkgs-devenv`, so no extra closure on the server. Your laptop evaluates both; the two nixpkgs source trees are small enough that the duplication is harmless.
3. Replace the explicit module list in `outputs` with `(inputs.import-tree ./modules)`.
4. Create `modules/parts.nix` with your systems list: `["aarch64-darwin" "x86_64-linux"]`
5. Move `shared/home.nix` → `modules/home/shared.nix`, wrapping it as a flake-parts module that exports `flake.homeModules.shared`
6. Create `modules/home/configurations.nix` — a flake-parts module that defines your three `homeConfigurations` using `self.homeModules.shared`. Pass `pkgs = inputs.nixpkgs-devenv.legacyPackages.<arch>;` on each config.
7. Move `darwin/system.nix` → `modules/darwin/system.nix`, wrapping it as `flake.darwinModules.system`
8. Create `modules/darwin/configurations.nix` — defines `darwinConfigurations."Simons-MacBook-Air"` importing `self.darwinModules.system`
9. Delete the old `shared/` and `darwin/` directories
10. Verify nothing is broken: `nix flake check`, then `home-manager switch --flake .#simon-darwin` (or whichever config you use)
11. Merge to main

**Important**: get this restructure working *before* touching any server stuff. If your Home Manager and Darwin configs break, fix them first.

**0c: Add the server skeleton (empty)**

1. Create `modules/hosts/foundry/` with placeholder files:
   - `default.nix` — defines `flake.nixosConfigurations.foundry` (importing the configuration module)
   - `configuration.nix` — minimal `flake.nixosModules.foundryConfiguration` (GRUB on legacy BIOS, SSH, your user, sops, initrd SSH for LUKS unlock). No TPM on this hardware (see Hardware inventory).
   - `disko.nix` — `flake.nixosModules.foundryDisko` (mdraid RAID1 mirror across both PM983s + LUKS + ext4). Use the `by-id` paths from the Hardware inventory verbatim.
   - `hardware.nix` — empty placeholder (will be generated by nixos-anywhere during install)
2. Create empty `modules/features/` directory (add a `.gitkeep` or a placeholder module)
3. Add `.sops.yaml` at repo root with your age public key as a recipient
4. **Generate the `deploy` SSH keypair now, and bake the pubkey into `configuration.nix` as `users.users.deploy.openssh.authorizedKeys.keys` with NOPASSWD sudo — *before* running nixos-anywhere.** We learned the hard way: `root` SSH is disabled, `simon` has no password, so without a pre-authorized `deploy` user there is no way to activate a new config after install short of re-running `nixos-anywhere` from rescue. Keypair:
   ```bash
   mkdir -p ~/.config/foundry-bootstrap
   ssh-keygen -t ed25519 -C foundry-deploy -N "" \
     -f ~/.config/foundry-bootstrap/deploy_ed25519
   ```
   Paste the `.pub` into `configuration.nix`. Private key stays outside the repo; it'll be reused in Phase 3b as the GitHub Actions secret.
5. Commit and push — `nix flake check` should still pass (the nixosConfiguration won't build without real hardware, but the flake structure should be valid)

**0d: Pre-commit hooks via git-hooks.nix**

Add this before the repo starts accumulating real content (sops files, zsh helpers that might reference an IP, hardware configs). `git-hooks.nix` is the flake-parts-native way to declare pre-commit hooks: one `modules/pre-commit.nix` defines them, the devShell installs them, and `nix flake check` runs the same hook set — so CI (Phase 3a) gets the exact same gate for free.

1. Add the input to `flake.nix`:
   ```nix
   git-hooks.url = "github:cachix/git-hooks.nix";
   git-hooks.inputs.nixpkgs.follows = "nixpkgs";
   ```
2. Create `modules/pre-commit.nix` as a flake-parts module that imports `inputs.git-hooks.flakeModule`. Set `pre-commit.settings.package = pkgs.prek;` — [prek](https://github.com/j178/prek) is a drop-in Rust reimplementation of `pre-commit` that git-hooks.nix supports first-class. Measured `git commit` wall-clock dropped from ~45 s to ~0.6 s on this repo; there's no reason to stay on the Python pre-commit. Then enable two hooks in `perSystem`:
   - `gitleaks` — git-hooks.nix has no built-in gitleaks hook, so wire one up explicitly: `entry = "${pkgs.gitleaks}/bin/gitleaks protect --staged --verbose --redact"`, `language = "system"`, `pass_filenames = false`. `--redact` keeps any finding out of terminal scrollback / screen shares.
   - `alejandra` — Nix formatter. **Exclude `hosts/foundry/hardware-configuration.nix`** (`excludes = ["^hosts/foundry/hardware-configuration\\.nix$"]`); that file is regenerated by `nixos-generate-config` on every reinstall, and you don't want a reformat/regen tug-of-war.
3. Expose `devShells.default = config.pre-commit.devShell;`. git-hooks.nix's shellHook writes `.git/hooks/pre-commit` on shell entry and keeps it fresh.
4. Add `.envrc` with `use flake` (direnv is already whitelisted for `~/repos` in your home-manager config, so `cd`ing into the clone auto-activates the shell) and a `.gitignore` covering `.direnv/`, `result*`, and the auto-generated `.pre-commit-config.yaml` symlink into the nix store.
5. Smoke-test: create a file containing a distinctive secret pattern (e.g. a 36-char string with a `ghp_` prefix) and run `git commit`. The hook must exit 1 with `RuleID: github-pat`. Then remove the file.

   **Don't test with AWS's documented `AKIAIOSFODNN7EXAMPLE`** — gitleaks' default rules allowlist it, the commit will go through, and you'll conclude the hook is broken when it isn't.

Note: gitleaks scans for high-entropy strings and known secret formats (tokens, private keys). It will **not** catch hostnames, IP addresses, MAC addresses, or internal URLs. Step 0a's "IP lives in `~/.ssh/config`, nowhere else" discipline is the only thing keeping those out of the repo — no tool will save you from a typo.

**Phase 1: Bare NixOS install via nixos-anywhere — LUKS + SSH-initrd-unlock, mdraid RAID1, Legacy BIOS**

Goal: server boots NixOS from your flake, both NVMes mirror the encrypted root, every boot pauses in initrd until you SSH in and type the LUKS passphrase.

Constraints imposed by the hardware inventory: **no TPM available**, **Legacy BIOS** (UEFI not currently accessible), no BMC for remote BIOS. Auto-unlock is therefore not on the table; unlock is a manual SSH-in-initrd step on every reboot. Acceptable cost: ~10–15 reboots/year × ~1 minute each.

1. Boot into Hetzner rescue system from Robot panel (default boots in legacy BIOS, matching our install target). Note the rescue IP.
2. Finalize `modules/hosts/foundry/disko.nix`. Target layout — **mdraid RAID1 + LUKS + ext4**, mirrored across both PM983s so either drive can die:
   - Both disks referenced by the exact `by-id` paths from the Hardware inventory (never `/dev/nvme0n1`).
   - Matching GPT partition table on each disk: a tiny 1 MiB BIOS boot partition (`ef02`), a 1 GiB `/boot` partition, the rest as the RAID member.
   - `md` RAID1 across the two large partitions, then LUKS2 on top of the `md` device, then ext4 on the decrypted volume.
   - GPT partition label `cryptroot` for the LUKS partition so later commands can use `/dev/disk/by-partlabel/cryptroot` instead of device numbers.
   - `/boot` as a **separate mdraid RAID1 mirror** of the `/boot` partitions on both disks (GRUB-readable, so no LUKS on `/boot`). Lets GRUB boot even if one NVMe is dead.
3. Finalize `modules/hosts/foundry/configuration.nix`. Required pieces:
   - **Legacy BIOS GRUB with mirrored boot**:
     ```nix
     boot.loader.grub = {
       enable = true;
       efiSupport = false;
       # Disko auto-populates grub.devices from its disk list, which then
       # conflicts with mirroredBoots (duplicated-devices assertion). Force
       # empty; mirroredBoots handles per-disk install itself.
       devices = lib.mkForce [];
       mirroredBoots = [
         { devices = [ "/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501871" ]; path = "/boot-1"; }
         { devices = [ "/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501883" ]; path = "/boot-2"; }
       ];
     };
     boot.loader.efi.canTouchEfiVariables = false;
     ```
   - `boot.initrd.systemd.enable = true;` (modern initrd; cleaner LUKS + networking handling).
   - SSH enabled on the booted system, your user with your SSH key, **the `deploy` user authorized from install time** (see Phase 0c step 4) with NOPASSWD sudo — tightened in Phase 3b.
   - **Initrd SSH for LUKS unlock — this is now the primary unlock mechanism, not a fallback**:
     ```nix
     boot.initrd.network.enable = true;
     boot.initrd.network.ssh = {
       enable = true;
       port = 2222;
       hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
       authorizedKeys = config.users.users.simon.openssh.authorizedKeys.keys;
       # Under systemd-initrd, an incoming ssh session would otherwise drop
       # you into a root `ash` shell and you'd have to run
       # systemd-tty-ask-password-agent by hand. ForceCommand makes the
       # session execute the agent immediately so `ssh -p 2222 root@...`
       # goes straight to the passphrase prompt.
       extraConfig = ''
         ForceCommand systemd-tty-ask-password-agent --query
       '';
     };
     boot.initrd.availableKernelModules = [ "e1000e" ];  # Intel I219-LM; confirm from hardware.nix
     ```
     The initrd ed25519 host key must exist on the target before first reboot. Generate it locally (once) under `~/.config/foundry-bootstrap/extra-files/etc/secrets/initrd/ssh_host_ed25519_key` and ship via `nixos-anywhere --extra-files`.
   - No `security.tpm2.enable`, no TPM kernel modules — not useful here.
4. Run from your laptop:
   ```bash
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#foundry \
     --target-host root@<rescue-ip> \
     --build-on-remote \
     --kexec https://github.com/nix-community/nixos-images/releases/download/nixos-25.11/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz \
     --generate-hardware-config nixos-generate-config ./hosts/foundry/hardware-configuration.nix \
     --extra-files ~/.config/foundry-bootstrap/extra-files
   ```
   - `--build-on-remote` — the laptop is `aarch64-darwin` and can't cross-build `x86_64-linux`. The target has 64 GiB RAM and finishes the build in a few minutes.
   - `--kexec <url>` is **mandatory on this hardware.** The default kexec image bundled with `nixos-anywhere` (a `25.05pre-git` build) reliably hung the handoff on this I219-LM NIC — kexec fires, SSH drops, NIC never comes back, box goes dark. This is a known `e1000e` PCI power-state class of bug ([nixos-anywhere#289](https://github.com/nix-community/nixos-anywhere/issues/289), [Proxmox/Hetzner thread](https://forum.proxmox.com/threads/proxmox-crashing-on-hetzner-server-with-intel-i219-lm-nic.57271/)). Pinning to the `nixos-25.11` release image from `nix-community/nixos-images` fixes it.
   - `--generate-hardware-config` writes `hardware-configuration.nix` back to the laptop. Drop it under `hosts/foundry/` (outside `modules/`), since it's a plain NixOS module not a flake-parts module and `import-tree` would otherwise choke on it.
   - `--extra-files` is how the initrd host key (and anything else outside the flake) gets onto the target before the build.

   **Pre-install cleanup** if the target has had a previous install (rescue won't auto-disassemble the old RAID/LUKS):
   ```bash
   ssh root@<rescue-ip> '
     mdadm --stop /dev/md127 2>/dev/null || true
     mdadm --zero-superblock /dev/nvme0n1p3 /dev/nvme1n1p3 2>/dev/null || true
     wipefs -a /dev/nvme0n1 /dev/nvme1n1
   '
   ```

   **Hetzner rescue is single-shot.** If the install goes sideways and you need to hard-reset, re-arm rescue in the Robot panel's Rescue tab *before* the reset — otherwise the next boot hits the (wiped) disks instead of rescue.
5. When the machine reboots into the real system, LUKS will wait. From your laptop:
   ```bash
   ssh -p 2222 root@<server-ip>
   # With ForceCommand in place, you land directly on the LUKS passphrase prompt —
   # no root ash shell, no manual systemd-tty-ask-password-agent.
   ```
   The SSH session closes itself once the real system takes over — that's expected.
6. Commit the generated `hardware-configuration.nix` and the confirmed NIC kernel module (adjust `boot.initrd.availableKernelModules` if it shows a different driver than `e1000e`).
7. Do one full reboot cycle (`ssh deploy@<server> sudo reboot`) and confirm you can unlock via `ssh -p 2222` and the box comes back up on port 22. This validates the whole boot path end-to-end before you put any secrets or services on it.
8. **Store the LUKS passphrase in your password manager** — there is no hardware-assisted recovery path. If you lose it, the disks are a brick and you reinstall.
9. Record the unlock procedure in `BOOTSTRAP.md` (Phase 5 step 11): the SSH command, the port, which user, where the passphrase lives.

**Phase 1b: macOS Keychain-integrated unlock helper (optional QoL)**

The initrd passphrase prompt lives at `ssh -p 2222 root@foundry` — using the `Host foundry` alias from Phase 0a, so the real IP never touches the flake. You can wrap it in a home-manager zsh function so reboots are a single command. Two pieces (see `modules/home/shared.nix`):

- `foundry-unlock-seed` — one-shot; stashes the passphrase in the macOS login keychain as a generic password (`account=foundry`, `service=foundry-luks`).
- `foundry-unlock` — reads it back and pipes it into `ssh -tt -p 2222 root@foundry`.

Implementation notes:
- **Address the box as `foundry`, never as a literal IP.** The helper still needs the real IP for `nc -z "$ip" 22` port probes (`nc` doesn't honor SSH config), so resolve it at runtime:
  ```
  ip=$(ssh -G foundry 2>/dev/null | awk '/^hostname /{print $2; exit}')
  [[ -z "$ip" || "$ip" == "foundry" ]] && { print -u2 "add a Host foundry block to ~/.ssh/config"; return 1; }
  ```
  `ssh -G` prints the effective config; if `HostName` is unset it echoes the alias back unchanged, which is how the guard detects a misconfigured laptop. No silent fallback to a hardcoded IP — that's the whole point.
- Use `ssh -tt` (force pty), not `-T`. `systemd-tty-ask-password-agent --query` reads the passphrase via `/dev/tty`, not stdin; piping into a pty is what makes the `/dev/tty` read succeed.
- Short-circuit when port 22 is already open so repeated invocation is harmless.
- On first invocation macOS asks whether `/usr/bin/security` may read the keychain item — click **Always Allow** for future silent unlocks.
- The keychain copy is a convenience cache, **not** a backup; your password manager is still the authoritative source.

**Future upgrade path (optional, not required):**

If SSH-unlock annoys you enough after a few months, you can buy one Hetzner KVM/remote-hands session (~€25 one-time), enter the BIOS, and:
- Switch boot mode from CSM/Legacy to UEFI.
- Enable "TPM Device Selection → Firmware TPM (PTT)" in the advanced BIOS menu (Intel PTT is supported by the C246 chipset).
- Optionally enable Secure Boot.

Then reinstall (the whole flake is declarative — reinstall is cheap) with `systemd-boot` instead of GRUB, enroll the LUKS slot to the TPM via `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/cryptroot`, and you get auto-unlock on reboot. Don't block on this — get the rest of the plan working first on the legacy path.

**Decision point before Phase 2:** at this stage you have a bare NixOS box that unlocks via SSH on every boot. Do two full reboot cycles and confirm both times you get back in cleanly. If yes, proceed.

**Phase 1c: Security hardening — SSH, firewall, unattended upgrades**

Goal: shrink the public attack surface without adding network-layer dependencies that get in the way of recovery. Public SSH stays reachable but key-only and hardened; Phase 4 adds an HTTP-layer auth gate (Authentik ForwardAuth via Caddy) for admin-only services rather than gating at the network layer.

**Decision: no network mesh (Netbird / Tailscale)**

We evaluated closing public :22 and routing admin SSH through a Netbird mesh. Rejected:

- For a single-admin homelab on ed25519-key-only SSH, the security delta over "public :22 + hardened config" is marginal. The realistic threats to this box are web-app RCE, kernel CVEs, and container escape — none of which a mesh prevents. SSH brute force is already defeated by key-only auth. An SSH 0-day is low-probability *and* a mesh daemon (Netbird/Tailscale) is itself a network-exposed daemon with its own potential 0-days.
- A managed-coordinator mesh introduces a third-party dependency (Netbird.io or Tailscale control plane). An outage there wouldn't lock us out — the initrd-unlock and Hetzner rescue paths stay — but it adds a class of "why is nothing working" debugging we'd rather not have.
- Mesh enrollment is interactive: `sudo netbird-foo up` → SSO in the browser → approve in the Netbird UI. That's a few seconds, but it is friction on every fresh reinstall, which is the exact scenario we're trying to keep fast.
- Admin-only internal services (Grafana, Uptime Kuma, Authentik's own admin UI) will be gated at the HTTP layer in Phase 4 via Caddy `forward_auth` → Authentik. Same effective outcome (admins authenticate; public internet does not reach the app at all) with one fewer system to operate.

The decision is reversible. A NixOS Netbird client is `services.netbird.clients.<name> = { ... };` plus a firewall swap — small to add later if a use case shows up (co-admin joining from an unstable IP, exposing a service to a phone that's not on a predictable IP). The repo briefly carried a working Netbird + firewall-cutover configuration on commits `3318c2c`, `488008d`, and `663ab97` before the revert; those remain in git history as a reference if we revisit.

**1c-1: Hardened public SSH**

In `modules/hosts/foundry/configuration.nix`:

```nix
services.openssh = {
  enable = true;
  settings = {
    PasswordAuthentication = false;
    PermitRootLogin = "no";
    KbdInteractiveAuthentication = false;
    MaxAuthTries = 3;
    AllowUsers = [ "simon" "deploy" ];
  };
};
```

Key-only auth, `root` login off, tight `AllowUsers` — the bare-minimum settings that retire SSH brute force and account probing as meaningful threats.

**1c-2: Explicit firewall allow-list**

```nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 22 2222 ];
};
```

- `22`: SSH. The `services.openssh` module also adds this via `openFirewall = true` by default — listed here explicitly so the public surface is visible in one place.
- `2222`: initrd LUKS-unlock sshd. The main-system firewall is inactive during initrd, so this rule is a defensive no-op post-boot — but listing it documents intent.
- Phase 4 will add `80` and `443` when Caddy goes up.

**1c-3: Unattended security updates**

```nix
system.autoUpgrade = {
  enable = true;
  flake = "github:Riezebos/nix";
  flags = [ "-L" ];
  dates = "04:30";
  randomizedDelaySec = "45min";
  operation = "boot";
};
```

`operation = "boot"` stages the new generation into the bootloader without live-activating it, so autoUpgrade never restarts openssh / Foundry / Postgres mid-session. A manual (or scheduled) reboot window actually applies the update. CI (Phase 3c) is authoritative for bumping `flake.lock`; the server is purely a puller — do not run `--update-input` here.

**Why no fail2ban (at this phase)**

Key-only SSH has no brute-forceable surface. The real rate-limit targets will be Foundry's HTTP login and Authentik's in Phase 4, handled at the proxy layer (Caddy `rate_limit`) plus CrowdSec (below) rather than fail2ban log-parsing.

**1c-4: Phase 4 security architecture (preview — implementation in Phase 4)**

Committing these choices *here*, before any Phase 4 code gets written, so the shape of the system is decided:

**Reverse proxy: Caddy.** Terminates TLS on 80/443, automatic ACME via Let's Encrypt. Reasons over nginx: automatic HTTPS with zero config, `forward_auth` directive for Authentik (one line per vhost), strong defaults (HSTS, HTTP/2, modern ciphers) out of the box, smaller config surface. Add HTTP security headers per vhost: `Strict-Transport-Security`, `Content-Security-Policy` (per app), `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`. Rate-limit login endpoints with `rate_limit` (5 req/min per IP is a reasonable start).

**Auth: Authentik in front of admin UIs only.**

- Foundry itself stays publicly accessible — players log in via Foundry's own auth.
- Grafana, Uptime Kuma, any future admin UI: Caddy `forward_auth` → Authentik outpost. The login form is Authentik, not the app. Enable TOTP + WebAuthn on the admin flow.
- Authentik runs in its own NixOS container (below), with its PostgreSQL + Redis bound to `127.0.0.1`.

**Service isolation: NixOS containers + per-service systemd hardening.**

Each public-facing service goes in a `containers.<name>` (systemd-nspawn-based): shared kernel with the host, but isolated filesystem, users, PID namespace, cgroups. Inside each container, the service runs under:

```nix
serviceConfig = {
  DynamicUser = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  NoNewPrivileges = true;
  RestrictNamespaces = true;
  SystemCallFilter = [ "@system-service" ];
  CapabilityBoundingSet = "";   # tighten per service — empty if possible
};
```

Defense in depth: nspawn handles coarse isolation (filesystem, PID, cgroup); systemd hardening handles fine-grained (syscalls, capabilities, namespaces). A handful of options are no-ops inside containers (`ProtectKernelModules`, `PrivateNetwork`) because nspawn already owns that boundary — the rest apply normally. Fully compatible.

**Data: localhost-only + per-service sops scoping.**

- PostgreSQL, Redis: bind to `127.0.0.1`. Never listen on the public interface.
- Each service's systemd unit only gets the secrets it needs via sops-nix's per-secret `owner` / `group` / `mode`. A Foundry RCE must not be able to read Authentik's DB password — different files, different owners, different `LoadCredential` entries.

**Reactive blocking: CrowdSec.**

`services.crowdsec.enable = true;`. Parses auth / web-server logs, detects bad behavior (SSH brute-force, HTTP scan patterns, known-abusive user agents) and adds IP-level bans via nftables. Modern fail2ban replacement; community threat intel blocks known-bad IPs proactively. Runs on the host, not in a container, so it can see all service logs.

**Recovery path (unchanged by Phase 1c)**

1. Normal: `ssh foundry`.
2. LUKS: `foundry-unlock` → `ssh -p 2222 root@<public IP>` (initrd).
3. Break-glass: Hetzner Robot rescue → `cryptsetup open /dev/disk/by-partlabel/cryptroot cryptroot` → `mdadm --assemble --scan` → mount → fix, *or* `nixos-anywhere --flake .#foundry` for a clean reinstall followed by a restic restore.

End-to-end reinstall to a fresh box: ~1-2 hours. No mesh enrollment, no SSO dance. This is the trade we made by keeping SSH public — recovery stays scripted and dependency-free.

**Explicitly deferred (not worth the maintenance tax for solo ops)**

- **Egress filtering** (iptables OUTPUT per-service). Limits exfil blast radius if a service gets RCEd, but maintenance cost is high. Revisit only if an actual incident exposes a gap.
- **Self-hosted WAF** (ModSecurity, Coraza). Massive ongoing tuning tax for marginal value on a small app set.
- **Auditd / kernel lockdown / full syscall logging.** Low signal-to-noise for a homelab — the journal + Grafana Cloud logs (Phase 5) cover 95% of forensic need.
- **Self-hosting an IdP instead of using Authentik's built-in.** Authentik is already an IdP; don't stack another.

**Phase 2: sops-nix integration**

Goal: your repo can hold encrypted secrets, the server can decrypt them at activation time.

1. Get the server's SSH host key (ed25519) and convert to an age recipient:
   ```bash
   ssh-keyscan -t ed25519 your-server | ssh-to-age
   ```
2. Add this age public key to `.sops.yaml` as a recipient for the server's secrets, alongside your personal age key. Use the `ssh-to-age` conversion path and tell sops-nix to use the same SSH host key for decryption:
   ```nix
   sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
   ```
   **Do not** use SOPS upstream's native SSH-key support — it produces a different age key than `ssh-to-age` and silently fails to decrypt ([sops-nix#824](https://github.com/Mic92/sops-nix/issues/824)).
3. `sops-nix` is already a flake input from Phase 0b — import the sops-nix NixOS module in `modules/hosts/foundry/configuration.nix`
4. Create your first test secret in `modules/hosts/foundry/secrets.yaml`:
   ```bash
   sops modules/hosts/foundry/secrets.yaml
   # add a dummy secret to verify it works
   ```
5. Reference it in config. Simplest is to set `sops.defaultSopsFile` for the host once and then declare secrets with an empty attrset — sops-nix picks up `./secrets.yaml` from the module's directory:
   ```nix
   sops.defaultSopsFile = ./secrets.yaml;
   sops.secrets.test = {};  # defaults to root:root 0400 at /run/secrets/test
   ```
   **Gotcha**: sops-nix computes `sopsFileHash` at eval time by reading `./secrets.yaml` from the flake source. Flakes filter the store copy through git's view of the tree, so a brand-new `secrets.yaml` that's only on disk will produce a `No such file or directory` eval error. `git add .sops.yaml modules/hosts/foundry/secrets.yaml` (no commit needed) *before* running `nix eval` / `nixos-rebuild`.
6. Deploy. Run from the laptop (via the `deploy` user baked in during Phase 0c/1):
   ```bash
   cd ~/repos/nix
   export NIX_SSHOPTS="-o IdentitiesOnly=yes -i $HOME/.config/foundry-bootstrap/deploy_ed25519"

   nix run nixpkgs#nixos-rebuild -- switch \
     --flake .#foundry \
     --target-host deploy@<server-ip> \
     --build-host  deploy@<server-ip> \
     --no-reexec \
     --sudo
   ```
   - `nix run nixpkgs#nixos-rebuild` — `nixos-rebuild` isn't packaged natively for macOS; run it through nix.
   - `NIX_SSHOPTS` is the canonical way to pass a custom SSH key; there is no `-i` / `-s` flag.
   - `--build-host` same as `--target-host` (no cross-compile).
   - `--sudo` replaces the deprecated `--use-remote-sudo`.
   - `--no-reexec` replaces the deprecated `--fast`.

   Verify on the target: `sudo cat /run/secrets/test` prints the decrypted value. During activation you should see a `sops-install-secrets: Imported /etc/ssh/ssh_host_ed25519_key as age key with fingerprint age1…` line matching the `&foundry` recipient in `.sops.yaml`.

**Phase 3: Forgejo Actions CI/CD**

Goal: push to main → repo auto-updates flake inputs, builds, and deploys.

Note: your repo is on GitHub, so you can use GitHub Actions instead of Forgejo Actions. Alternatively, if you want to self-host CI on the server, you can set up a Forgejo instance or Gitea runner later. The steps below assume GitHub Actions for simplicity since that's where your repo lives.

**3a: Build-only CI (safety net)**

1. Create `.github/workflows/build.yml`:
   - Trigger: on push, on PR
   - Steps (in order):
     1. `actions/checkout@v4`
     2. `gitleaks/gitleaks-action@v2` — fail the build if any plaintext secret is committed
     3. `DeterminateSystems/nix-installer-action@main`
     4. `cachix/cachix-action@v15` with your cache name + auth token
     5. `nix flake check`
     6. `nix build .#nixosConfigurations.foundry.config.system.build.toplevel`
     7. `nix build .#nixosConfigurations.foundry.config.system.build.vm` — a cheap pre-deploy sanity check that catches many activation-time errors `build.toplevel` misses (module eval is stricter here). Optionally boot it in-CI with a tiny smoke test.
     8. Once you have a Foundry service module, add a `nixosTest` that asserts the service starts and the port listens, and run it here.
2. Create a free Cachix cache, connect it in the workflow, cache builds.
3. The local pre-commit gate is already in place declaratively from Phase 0d, and `nix flake check` (step 5 above) re-runs the exact same hooks in CI. `gitleaks-action` stays as belt-and-braces — catches the case where someone pushes with `--no-verify`.
4. Verify: push a trivial change, watch it build.

**3b: Auto-deploy on main**

`nixos-rebuild switch --target-host` has no rollback on activation failure — a bad config merged to main can leave the server half-activated while a Foundry session is happening. Use a tool built for this instead.

**Recommended**: [deploy-rs](https://github.com/serokell/deploy-rs). It activates, health-checks, and auto-reverts to the previous generation if the new config isn't reachable ("magic rollback"). Works cleanly from GitHub Actions and from macOS.

1. `deploy-rs` is already a flake input from Phase 0b — nothing to add here.
2. Define a `deploy.nodes.foundry` entry pointing at `self.nixosConfigurations.foundry`
3. Generate a deploy SSH key pair; add the public key to the server's `deploy` user. Grant that user passwordless sudo for `/run/current-system/bin/switch-to-configuration` (deploy-rs and `nixos-rebuild --use-remote-sudo` both need this — easy to forget, and the failure mode is confusing).
4. Add the private key as a GitHub Actions secret
5. CI job on push to `main`: `nix run github:serokell/deploy-rs -- --skip-checks .#foundry` (skip-checks because the build job already ran them)
6. Add branch protection: main requires PR merges, build + gitleaks must pass

**Fallback options** if you don't want deploy-rs:

- `nixos-rebuild boot --target-host` instead of `switch` — activation happens on next reboot, so a bad config doesn't touch the running system. Combine with a scheduled reboot window.
- Minimum viable: `nixos-rebuild build --target-host` in CI and require a manual `switch` trigger. Loses full automation, gains a sanity gate.

**3c: Automated flake updates**

1. Add a scheduled workflow: weekly `nix flake update`, commit the lock file, open a PR
2. Use [`DeterminateSystems/update-flake-lock`](https://github.com/DeterminateSystems/update-flake-lock) action
3. PR runs the build workflow automatically
4. You review and merge, which triggers the deploy

**Phase 3 — required repo config**

Committed workflows: `.github/workflows/build.yml`, `deploy.yml`, `update-flake-lock.yml`. Deploy node config: `modules/deploy.nix`.

GitHub **secrets** (Settings → Secrets and variables → Actions → Secrets):

| Secret | Used by | What to put in it |
|---|---|---|
| `FOUNDRY_DEPLOY_KEY` | `deploy.yml` | Contents of `~/.config/foundry-bootstrap/deploy_ed25519` (the private half of the key baked into `configuration.nix` as `users.users.deploy.openssh.authorizedKeys.keys`). |
| `FOUNDRY_HOST` | `deploy.yml` | The real hostname or IP of `foundry`. Passed via `deploy --hostname …` so the public flake never names it. |
| `FOUNDRY_KNOWN_HOSTS` | `deploy.yml` | Output of `ssh-keyscan -t ed25519 <foundry-ip>`, run once from a trusted machine. Pins the host key so the CI runner can't TOFU an MITM. |
| `CACHIX_AUTH_TOKEN` | `build.yml`, `deploy.yml` | *(optional)* Cachix push token. Only consulted when the matching variable below is set. |

GitHub **variables** (same page, Variables tab):

| Variable | Used by | What to put in it |
|---|---|---|
| `CACHIX_CACHE_NAME` | `build.yml`, `deploy.yml` | *(optional)* Name of a Cachix cache. If unset, both workflows skip the Cachix step entirely and still function — just without cross-run caching. |

Enable branch protection on `main` once the workflows are green: require the `build` status, require PRs, and exempt the `update-flake-lock` bot if you want the weekly PR to land without a human approval (leave it gated if you'd rather eyeball each lock bump).

**Decision point before Phase 4:** you now have a fully automated deploy pipeline. Push to main = safe deploy via CI. Test it with a harmless change (add a comment somewhere).

**Phase 4: Migrate Foundry v12**

Goal: v12 runs on the new server with your old data.

1. On the **old** Ubuntu server, tar up the Foundry data dir **including all its subdirs** (`Data`, `Config`, and logs — Foundry stores user-uploaded assets inside each world's directory under `Data`, and sometimes config references absolute paths only found in `Config`). A common mistake is to tar the visible `Data` dir and miss `Config`:
   ```bash
   tar czf foundry-v12-data.tar.gz -C /path/to/foundrydata .
   ```
2. Copy to new server: `scp foundry-v12-data.tar.gz deploy@newserver:/tmp/`
3. Add a Foundry feature module at `modules/features/foundryvtt.nix`:
   - Export `flake.nixosModules.foundryvtt`
   - System user `foundryvtt`
   - systemd service pointing at `/var/lib/foundryvtt/v12/data`
   - Listening on `127.0.0.1:30012`
4. Import `self.nixosModules.foundryvtt` in `modules/hosts/foundry/configuration.nix`
5. Add the Foundry zip handling — two options:
   - **Option A (simpler)**: put the zip on the server manually, reference it by absolute path in your Nix config. Quick but not reproducible.
   - **Option B (cleaner)**: store the zip on your Hetzner Storage Box or S3, use `pkgs.fetchurl` with a hash, add the access credentials via sops. Fully reproducible.
   - Start with A, migrate to B later.
6. Add Caddy with automatic ACME for `foundry.simonito.com` — see the "Phase 4 security architecture" preview in Phase 1c-4 for the full reasoning (auto-HTTPS, `forward_auth` for Authentik on admin UIs, rate limiting, security headers). Either as part of the foundry module or a separate `modules/features/caddy.nix`.
7. Restore the data on the server: `cd /var/lib/foundryvtt/v12/data && tar xzf /tmp/foundry-v12-data.tar.gz` (pre-create dir, set ownership)
8. Review `options.json` in the restored data — might need to fix `dataPath` references
9. Deploy via CI: commit, push, watch it build and activate
10. Verify Foundry loads your worlds at `foundry.simonito.com`
11. **Keep the old Ubuntu server running for at least two weeks after cutover.** Open each world, check user-uploaded assets (tokens, maps, audio), run a real session if you can. If something's missing you'll want the old box's filesystem available, not deleted.

**Phase 5: Backups + monitoring**

Goal: data is protected, you know when things break.

1. Order Hetzner Storage Box (~€4/month for 1TB)
2. Add a restic feature module at `modules/features/restic.nix`, backing up `/var/lib/foundryvtt` to the Storage Box
3. Store restic password and Storage Box credentials in sops
4. Set retention via `pruneOpts` (`--keep-daily 7 --keep-weekly 4 --keep-monthly 6`) and make sure `forget` runs after each backup
5. Add a **separate monthly `restic check --read-data-subset=5%`** job (catches silent bitrot — plain backups won't). Use a second `services.restic.backups.<name>` entry or a standalone `systemd.timer`.
6. Add Healthchecks.io (free): one check for the backup job, **a second check for the `restic check` job**. A single check hides integrity failures.
7. Add Uptime Kuma — either as another service on the box or external free tier, for HTTP monitoring of `foundry.simonito.com`
8. Enable `services.prometheus.exporters.node` on the server and point a free Grafana Cloud tier (or a small self-hosted Grafana) at it. Disk/IO/memory trends catch slow-degrading problems before Uptime Kuma notices.
9. Use `systemd` `OnFailure=` hooks on critical units (foundry, restic, nginx, postgresql) to ping a Healthchecks.io "failure" URL — journalctl alerts without self-hosting anything.
10. **Test a restore to a temp directory** — don't skip this step. Do it once now, and schedule yourself a yearly reminder to do it again.
11. Document the bootstrap procedure in a `BOOTSTRAP.md` in your repo — include:
    - the SSH-initrd unlock command (`ssh -p 2222 root@<public-ip>`, or invoke `foundry-unlock` from the laptop) and where the LUKS passphrase lives;
    - how to re-encrypt sops secrets if the server's SSH host key rotates;
    - the restore-from-restic command;
    - the **free rescue-recovery runbook** — activate rescue in Robot → reset → SSH in with the Robot-registered key → `cryptsetup open /dev/disk/by-partlabel/cryptroot cryptroot` → `mdadm --assemble --scan` → mount → fix. This is the break-glass path from "What to watch for" written out as actual commands so you don't have to think at 2am;
    - a line reminding you to update the SSH key registered in Hetzner Robot whenever you rotate the laptop's key — rescue authorizes whatever is registered in Robot at activation time, not what's on the server;
    - the "optional upgrade path" steps from Phase 1 in case you ever flip the box to UEFI + PTT (this is the only scenario where paid KVM enters the picture).

**Phase 6: Database for the "more stuff"**

Goal: Postgres ready for future apps, with backups and encryption at rest (your disk encryption already handles at-rest).

1. Add `services.postgresql` — either in foundry's configuration or as a new `modules/features/postgresql.nix`
2. Create a database for your first app via `ensureDatabases` / `ensureUsers`
3. Add a separate restic job for `pg_dumpall` output (logical backup), running daily before the filesystem backup
4. Verify backup, verify restore to a scratch database

**Phase 7: v13 alongside v12**

Now you have all the machinery. Adding v13 is:

1. Parameterize the foundry module in `modules/features/foundry.nix` by version + data path + port (or create a second instance)
2. Add the conflict rules (or not, if you want both running) from our earlier conversation
3. Add second nginx vhost
4. Deploy

**Phase 8: Additional apps (whenever)**

With CI/CD, sops secrets, backups, and monitoring in place, adding any new app is: write a feature module in `modules/features/`, import it in the host configuration, add an nginx vhost, add secrets if needed, add it to the backup paths, push. You've built the foundation exactly once.

**What to watch for along the way**

- **Restructure carefully**: Phase 0b is the riskiest part for your daily workflow. Do it on a branch, test `home-manager switch` before merging. If something breaks, you can always revert.
- **import-tree gotcha**: every `.nix` file under `modules/` gets auto-imported, and every auto-imported file must be a valid **flake-parts module** (a function taking `{ self, inputs, lib, ... }`). A plain NixOS module (taking `{ config, pkgs, ... }`) dropped into `modules/` will eval-fail confusingly — wrap it as `flake.nixosModules.foo = { ... }: { ... };`. Also don't put scratch files in there.
- **nixpkgs split**: server is on `nixos-25.11` stable, Home Manager is on `devenv-nixpkgs/rolling` — two independent inputs, routed via `follows` in `flake.nix` (see Phase 0b). Don't let the rolling channel seep onto the server; audit `flake.lock` after any large change to confirm `nixosConfigurations.foundry` only pulls from `nixpkgs`.
- **No TPM, no auto-unlock**: this box has no TPM and legacy BIOS, so every boot requires `ssh -p 2222` to type the passphrase. The passphrase lives only in your password manager. Lose both and the disks are a brick. See the optional "Future upgrade path" in Phase 1 if you ever want to get off this merry-go-round.
- **nixos-anywhere first run**: it wipes the target. Triple-check which machine you're targeting.
- **CI runner**: GitHub Actions works out of the box for your public repo. If you later want self-hosted CI on the server, that's a Phase 8 add-on.
- **Secrets hygiene**: gitleaks runs as a pre-commit hook (Phase 0d, declarative via `git-hooks.nix`) and re-runs in CI via `nix flake check` (Phase 3a). After adding any secret also do a manual `git grep` for the value to be sure.
- **Machine identity stays on the laptop, not in the repo**: server IPs, MAC addresses, private internal URLs live in `~/.ssh/config` (`Host foundry` from Phase 0a) and in sops — never in `modules/` or the `.md` files. The flake refers to the box as `foundry`; `foundry-unlock` resolves the real IP via `ssh -G foundry` at runtime. This repo is public; anyone who clones it should not learn which IP to start probing. Gitleaks **won't** catch IPs or hostnames — this is a discipline thing, not a tooling thing.
- **Break-glass recovery**: the paths back into the box are (a) `ssh foundry` (public :22), (b) the initrd sshd on :2222 during a boot, (c) **Hetzner Robot's rescue system** if both of the above fail. Rescue is free and always available — PXE-booted over Hetzner's network, independent of anything on the disks or in the NixOS config. From rescue: `cryptsetup open /dev/disk/by-partlabel/cryptroot cryptroot` (passphrase from password manager) → `mdadm --assemble --scan` → mount → fix, or `nixos-anywhere --flake .#foundry` for a clean reinstall. Accept rescue as *the* fallback — don't try to engineer a "backup public SSH from my home IP" allow-rule, it'll rot. Make sure your Hetzner Robot login, its 2FA recovery codes, and the LUKS passphrase all live in a password manager you can reach from a phone. Paid KVM (~€25) is a different tool, needed only if the *BIOS itself* becomes unreachable — see Phase 1's "Future upgrade path".
- **Things that would break the free rescue path** (short list, for paranoia): (1) messing with BIOS boot order so network boot / PXE is disabled — we have no BIOS access on this box, so we literally can't do this by accident; (2) letting the SSH public key registered in Hetzner Robot drift out of sync with what's on the laptop — rescue authorizes whichever key is in Robot at activation time, so when you rotate the laptop's key, update Robot's copy at the same time; (3) losing access to the Robot account (password + 2FA). None of these are normal-operations risks; all three are checklist items for `BOOTSTRAP.md` (Phase 5 step 11).
- **Don't build Phase 3 before Phase 1 works end-to-end.** The temptation to "just set up CI first" is real, but you need a working server to deploy to.
- **Step by step means step by step**: after each phase, commit, push, and *actually wait a day* using the system before moving on. You'll catch issues you'd miss in a marathon setup.

**Where to find good examples**

- The [vimjoyer flake-parts template](https://github.com/vimjoyer/flake-parts-wrapped-template) and [his nixconf](https://github.com/vimjoyer/nixconf) for the import-tree pattern
- The [nix-community](https://github.com/nix-community) GitHub org has nixos-anywhere, disko, sops-nix all with READMEs
- [wrapper-modules docs](https://birdeehub.github.io/nix-wrapper-modules/md/intro.html) for when you want to wrap programs later
- NixOS Discourse and the NixOS wiki have pages specifically on TPM-LUKS and sops-nix
- Search GitHub for "nixos config" repos — many excellent ones are public
