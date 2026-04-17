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

**Phase 0: Restructure existing repo + foundations**

Goals: migrate your existing `nix` GitHub repo to the `import-tree` module pattern, add server tooling locally, generate keys.

**0a: Local tooling**

1. You already have Nix with flakes enabled
2. You already have `sops`, `age`, `ssh-to-age` in your `home.packages` — verify they work: `sops --version`, `age --version`, `ssh-to-age --version`
3. Generate your personal age key (if you haven't already): `age-keygen -o ~/.config/sops/age/keys.txt`

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
4. Commit and push — `nix flake check` should still pass (the nixosConfiguration won't build without real hardware, but the flake structure should be valid)

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
       mirroredBoots = [
         { devices = [ "/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501871" ]; path = "/boot-1"; }
         { devices = [ "/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501883" ]; path = "/boot-2"; }
       ];
     };
     boot.loader.efi.canTouchEfiVariables = false;
     ```
   - `boot.initrd.systemd.enable = true;` (modern initrd; cleaner LUKS + networking handling).
   - SSH enabled on the booted system, your user with your SSH key, passwordless sudo for the `deploy` user (see Phase 3b).
   - **Initrd SSH for LUKS unlock — this is now the primary unlock mechanism, not a fallback**:
     ```nix
     boot.initrd.network.enable = true;
     boot.initrd.network.ssh = {
       enable = true;
       port = 2222;
       hostKeys = [ /etc/secrets/initrd/ssh_host_ed25519_key ];
       authorizedKeys = config.users.users.simon.openssh.authorizedKeys.keys;
     };
     boot.initrd.availableKernelModules = [ "e1000e" ];  # Intel I219-LM; confirm from hardware.nix
     ```
     The initrd ed25519 host key must exist on the target before first reboot; nixos-anywhere's `--extra-files` or an activation step can place it. Generate it locally once, copy as part of the install.
   - No `security.tpm2.enable`, no TPM kernel modules — not useful here.
4. Run from your laptop:
   ```bash
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#foundry \
     --generate-hardware-config nixos-generate-config ./modules/hosts/foundry/hardware.nix \
     root@<rescue-ip>
   ```
   The `--generate-hardware-config` flag writes `hardware.nix` back to your laptop so you don't have to `scp` it afterwards.
5. When the machine reboots into the real system, LUKS will wait. From your laptop:
   ```bash
   ssh -p 2222 root@<server-ip>
   # systemd-cryptsetup prompts for the passphrase here; type it
   ```
   The SSH session will drop once the real system takes over — that's expected.
6. Commit the generated `modules/hosts/foundry/hardware.nix` and the confirmed NIC kernel module (adjust `boot.initrd.availableKernelModules` if `hardware.nix` shows a different driver than `e1000e`).
7. Do one full reboot cycle from your laptop (`ssh root@server reboot`) and confirm you can unlock via `ssh -p 2222` and the box comes back up on the main port. This validates the whole boot path end-to-end before you put any secrets or services on it.
8. **Store the LUKS passphrase in your password manager** — there is no hardware-assisted recovery path. If you lose it, the disks are a brick and you reinstall.
9. Record the unlock procedure in `BOOTSTRAP.md` (Phase 5 step 11): the SSH command, the port, which user, where the passphrase lives.

**Future upgrade path (optional, not required):**

If SSH-unlock annoys you enough after a few months, you can buy one Hetzner KVM/remote-hands session (~€25 one-time), enter the BIOS, and:
- Switch boot mode from CSM/Legacy to UEFI.
- Enable "TPM Device Selection → Firmware TPM (PTT)" in the advanced BIOS menu (Intel PTT is supported by the C246 chipset).
- Optionally enable Secure Boot.

Then reinstall (the whole flake is declarative — reinstall is cheap) with `systemd-boot` instead of GRUB, enroll the LUKS slot to the TPM via `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/cryptroot`, and you get auto-unlock on reboot. Don't block on this — get the rest of the plan working first on the legacy path.

**Decision point before Phase 2:** at this stage you have a bare NixOS box that unlocks via SSH on every boot. Do two full reboot cycles and confirm both times you get back in cleanly. If yes, proceed.

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
5. Reference it in config with an explicit `sopsFile` (don't rely on `sops.defaultSopsFile` unless you've set it):
   ```nix
   sops.secrets.test = {
     sopsFile = ./secrets.yaml;
   };
   ```
   Then check `/run/secrets/test` after rebuild.
6. Verify you can `nixos-rebuild switch --flake .#foundry --target-host root@server` from your laptop

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
3. Install `gitleaks` locally as a pre-commit hook too, so you catch leaks before they hit CI.
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

**Decision point before Phase 4:** you now have a fully automated deploy pipeline. Push to main = safe deploy via CI. Test it with a harmless change (add a comment somewhere).

**Phase 4: Migrate Foundry v12**

Goal: v12 runs on the new server with your old data.

1. On the **old** Ubuntu server, tar up the Foundry data dir **including all its subdirs** (`Data`, `Config`, and logs — Foundry stores user-uploaded assets inside each world's directory under `Data`, and sometimes config references absolute paths only found in `Config`). A common mistake is to tar the visible `Data` dir and miss `Config`:
   ```bash
   tar czf foundry-v12-data.tar.gz -C /path/to/foundrydata .
   ```
2. Copy to new server: `scp foundry-v12-data.tar.gz deploy@newserver:/tmp/`
3. Add a Foundry feature module at `modules/features/foundry.nix`:
   - Export `flake.nixosModules.foundry`
   - System user `foundryvtt`
   - systemd service pointing at `/var/lib/foundryvtt/v12/data`
   - Listening on `127.0.0.1:30012`
4. Import `self.nixosModules.foundry` in `modules/hosts/foundry/configuration.nix`
5. Add the Foundry zip handling — two options:
   - **Option A (simpler)**: put the zip on the server manually, reference it by absolute path in your Nix config. Quick but not reproducible.
   - **Option B (cleaner)**: store the zip on your Hetzner Storage Box or S3, use `pkgs.fetchurl` with a hash, add the access credentials via sops. Fully reproducible.
   - Start with A, migrate to B later.
6. Add nginx with ACME for `foundry.simonito.com` — either as part of the foundry module or a separate `modules/features/nginx.nix`
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
11. Document the bootstrap procedure in a `BOOTSTRAP.md` in your repo — include the SSH-initrd unlock command (`ssh -p 2222 root@<server>`), where the LUKS passphrase lives, how to re-encrypt sops secrets if the host key rotates, the restore-from-restic command, and the "optional upgrade path" steps from Phase 1 in case you ever flip the box to UEFI + PTT.

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
- **Secrets hygiene**: gitleaks runs in CI (Phase 3a) and as a pre-commit hook. After adding any secret also do a manual `git grep` for the value to be sure.
- **Don't build Phase 3 before Phase 1 works end-to-end.** The temptation to "just set up CI first" is real, but you need a working server to deploy to.
- **Step by step means step by step**: after each phase, commit, push, and *actually wait a day* using the system before moving on. You'll catch issues you'd miss in a marathon setup.

**Where to find good examples**

- The [vimjoyer flake-parts template](https://github.com/vimjoyer/flake-parts-wrapped-template) and [his nixconf](https://github.com/vimjoyer/nixconf) for the import-tree pattern
- The [nix-community](https://github.com/nix-community) GitHub org has nixos-anywhere, disko, sops-nix all with READMEs
- [wrapper-modules docs](https://birdeehub.github.io/nix-wrapper-modules/md/intro.html) for when you want to wrap programs later
- NixOS Discourse and the NixOS wiki have pages specifically on TPM-LUKS and sops-nix
- Search GitHub for "nixos config" repos — many excellent ones are public
