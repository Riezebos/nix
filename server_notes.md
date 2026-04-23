# foundry bootstrap notes

Working session notes from the first `nixos-anywhere` install onto the Hetzner
box (hostname `foundry`; real IP lives in `~/.ssh/config` under `Host foundry`
on the laptop, intentionally kept out of this public repo). Written during
Phase 1 of `PLAN.md`; meant to be merged into/superseded by `BOOTSTRAP.md`
(Phase 5, step 11) once the plan is further along.

## Current state

- Hardware: matches the inventory in `PLAN.md` exactly — ASUS WS C246 DC,
  Xeon E-2176G, 64 GiB DDR4 ECC, 2× PM983 NVMe, Intel I219-LM NIC, Legacy
  BIOS, no TPM.
- Disk: mdraid RAID1 across both NVMes → LUKS2 (`cryptroot`) → ext4 on `/`.
  `/boot-1` and `/boot-2` are separate ext4 partitions on each NVMe, with
  GRUB installed independently to both via `boot.loader.grub.mirroredBoots`.
- Unlock: initrd sshd on port 2222 with the baked-in ed25519 host key
  (fingerprint `SHA256:yFuOiGhMo/WznjqXKDL9ClkUqGN6Jn1uygpKqJdZPB8`). With
  the `ForceCommand` fix committed in `6777b94`, SSHing to that port
  drops straight into the LUKS passphrase prompt — no manual
  `systemd-tty-ask-password-agent` invocation needed.
- Accounts:
  - `simon` — SSH-key login only (`info@datagiant.org`), no password, in
    `wheel`. Cannot `sudo` (this is intentional — Phase 3b will tighten
    `deploy` user but we'd have to also grant `simon` a password or
    NOPASSWD otherwise).
  - `deploy` — SSH-key login (key lives at
    `~/.config/foundry-bootstrap/deploy_ed25519` on the laptop), in
    `wheel`, NOPASSWD `sudo`. This is the activation account for both
    laptop-driven `nixos-rebuild --target-host` and (eventually) CI.

## Bootstrap artifacts on the laptop (outside the repo)

```
~/.config/foundry-bootstrap/
├── deploy_ed25519           # deploy user private key (600)
├── deploy_ed25519.pub       # pubkey pasted into configuration.nix
└── extra-files/
    └── etc/secrets/initrd/
        ├── ssh_host_ed25519_key       # initrd host key (600)
        └── ssh_host_ed25519_key.pub
```

- These are **not** in the git repo and must not be. The private keys
  would end up world-readable in the nix store otherwise.
- The `extra-files/` tree is what `nixos-anywhere --extra-files` copies
  onto the target; its layout mirrors the target filesystem root, so
  `extra-files/etc/secrets/initrd/ssh_host_ed25519_key` lands at
  `/etc/secrets/initrd/ssh_host_ed25519_key` on the server, which is what
  `boot.initrd.network.ssh.hostKeys` points to.
- Back these files up (somewhere outside the laptop) before decommissioning
  the laptop. Losing them means: rotating the initrd host key (SSH host
  key warnings on every `ssh -p 2222`) and generating+deploying a new
  deploy keypair.

## Working install command (reference)

Run from the laptop, with the repo as cwd, while the target is in Hetzner
rescue mode (root SSH reachable on port 22):

```bash
cd ~/repos/nix

nix run github:nix-community/nixos-anywhere -- \
  --flake .#foundry \
  --target-host root@foundry \
  --build-on-remote \
  --kexec https://github.com/nix-community/nixos-images/releases/download/nixos-25.11/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz \
  --generate-hardware-config nixos-generate-config ./hosts/foundry/hardware-configuration.nix \
  --extra-files ~/.config/foundry-bootstrap/extra-files
```

Flags and why:

- `--build-on-remote` — the laptop is `aarch64-darwin` and can't
  cross-compile `x86_64-linux`. Target has 64 GiB RAM and 6C/12T, so
  remote builds finish in a few minutes.
- `--kexec <url>` — **mandatory on this hardware** (see "What went
  wrong" below). The default kexec image bundled with `nixos-anywhere`
  did not survive the handoff on this box. The pinned `nixos-25.11`
  release image from `nix-community/nixos-images` does.
- `--generate-hardware-config nixos-generate-config <path>` — after
  `disko` partitions the target, this runs `nixos-generate-config` on
  the installed system and copies `hardware-configuration.nix` back to
  the laptop. Do a `git diff` on it afterwards; small deltas (e.g.
  `nixos-generate-config` output changes across nixpkgs versions) are
  expected and fine to re-commit.
- `--extra-files` — places the initrd host key on the target before
  the build starts. Because the build happens on the target
  (`--build-on-remote`), the initrd-building step can read
  `/etc/secrets/initrd/ssh_host_ed25519_key` and embed it into the
  initrd.

## Pre-install cleanup (if the target has had a previous install)

After booting rescue on a box that already had the previous disko
layout, wipe the old RAID/GPT metadata before re-running
`nixos-anywhere`. Without this, `disko` can trip on a still-assembled
`/dev/md127`:

```bash
ssh root@foundry '
  mdadm --stop /dev/md127 2>/dev/null || true
  mdadm --zero-superblock /dev/nvme0n1p3 /dev/nvme1n1p3 2>/dev/null || true
  wipefs -a /dev/nvme0n1 /dev/nvme1n1
'
```

## Unlock procedure on every boot

The box pauses in the initrd after every reboot until the LUKS
passphrase is entered.

### One-time setup on the laptop

After the initial install, seed the passphrase into the macOS login
keychain:

```bash
foundry-unlock-seed
# prompts for the passphrase (hidden), writes it as a generic password
# item (account=foundry, service=foundry-luks).
```

This defines two zsh functions (see
`modules/home/shared.nix` → `programs.zsh.initContent`):

- `foundry-unlock-seed` — `security add-generic-password …` wrapper.
- `foundry-unlock` — `security find-generic-password …` → pipe over
  `ssh -tt -p 2222 root@foundry`.

On first invocation, macOS will ask whether `/usr/bin/security` can
read the keychain item. Click **Always Allow** so subsequent unlocks
are non-interactive. (Later we can gate this on Touch ID — see
"Future upgrade path" below.)

### Daily usage

```bash
foundry-unlock
# foundry: passphrase accepted, waiting for sshd on :62222...
# foundry: up.
```

The function pipes the passphrase into `systemd-tty-ask-password-agent
--query` (which is what our initrd sshd runs as `ForceCommand`). The
agent reads from `/dev/tty`, not stdin, so the function uses `ssh -tt`
(force pty allocation even without a local terminal); piped stdin then
lands in the pty and the agent's `/dev/tty` read picks it up. After
the prompt is accepted it polls port 62222 for up to 120 s and returns
when the real sshd is reachable. It also short-circuits with a "nothing
to do" message if port 62222 is already open, so running it twice by
accident is harmless.

### Manual fallback

If anything about the keychain path is broken and you need to unlock
by hand:

```bash
ssh -p 2222 root@foundry
# prompt appears automatically — type the passphrase, hit enter
# the SSH session closes itself; the real system takes over on port 62222
```

Any machine with `~/.ssh/id_ed25519` (the `info@datagiant.org` key)
can do this — the initrd authorized_keys is populated from
`users.users.simon.openssh.authorizedKeys.keys`.

**The authoritative copy of the LUKS passphrase lives in Bitwarden**
(or whatever password manager — update this line once confirmed). The
keychain copy is a convenience cache, not a backup. If both go away,
the disks are a brick — no hardware-assisted recovery path on this
box (no TPM, no PTT, legacy BIOS). See "Future upgrade path" in
`PLAN.md` Phase 1.

## Deploying config changes from the laptop

Until CI is in place (Phase 3), deploys are laptop-driven via the
`deploy` user. `nixos-rebuild` isn't shipped for macOS, so run it via
`nix run nixpkgs#nixos-rebuild`:

```bash
cd ~/repos/nix
export NIX_SSHOPTS="-o IdentitiesOnly=yes -i $HOME/.config/foundry-bootstrap/deploy_ed25519"

nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#foundry \
  --target-host deploy@foundry \
  --build-host deploy@foundry \
  --no-reexec \
  --sudo
```

- `NIX_SSHOPTS` picks up the deploy private key for every SSH that
  `nixos-rebuild` fires internally. There is no `-i` / `-s` CLI flag
  for that; `NIX_SSHOPTS` is the canonical way.
- `--build-host` is the same as `--target-host` because the laptop
  (aarch64-darwin) can't cross-build `x86_64-linux` and the target has
  plenty of CPU + ECC RAM.
- `--sudo` (previously `--use-remote-sudo`, now deprecated) makes the
  activation step run under `sudo` on the target — required because
  `deploy` activates but activation itself needs root.
- `--no-reexec` (previously `--fast`, now deprecated) skips the
  self-reexec that `nixos-rebuild` does after building; not required
  but saves a few seconds.
- `deploy` has NOPASSWD `sudo` scoped to `ALL` (tighten to
  `switch-to-configuration` only during Phase 3b when `deploy-rs`
  lands).
- Magic-rollback / health-check is **not** wired up yet; a bad config
  merged to main *will* break the running system. Don't deploy unreviewed
  changes until `deploy-rs` is in place.

Validated end-to-end on 2026-04-17 — running the above against the
currently-active config was a clean no-op switch, confirming the
laptop → deploy@foundry path works without further bootstrap.

## What went wrong during this bootstrap (for future me)

### Minor: no auto-prompt on initrd SSH

First install used
`boot.initrd.network.ssh` with no `extraConfig`. Under systemd-initrd
(the default since we set `boot.initrd.systemd.enable = true`), SSHing
to port 2222 drops you into a root `ash` shell — not the LUKS prompt.
You had to run `systemd-tty-ask-password-agent` by hand.

Fix (committed in `6777b94`):

```nix
boot.initrd.network.ssh.extraConfig = ''
  ForceCommand systemd-tty-ask-password-agent --query
'';
```

The scripted-initrd option `boot.initrd.network.ssh.shell` doesn't
apply here because `systemd` owns the initrd — hence the `ForceCommand`
route.

### Major: kexec handoff hangs on this hardware with the default image

`nixos-anywhere` by default downloads its own pinned kexec image
(we saw `nixos-system-nixos-installer-kexec-25.05pre-git` in the logs).
On this box, this image succeeded the **first** install, then hung
silently on **both** subsequent attempts — classic black-screen pattern
(kexec fires, SSH session closes, the new kernel is up but the NIC
never comes back). No ICMP, no TCP, fully dark until a Hetzner
hard-reset.

This is a well-documented class of issue:
- [`nixos-anywhere#289`](https://github.com/nix-community/nixos-anywhere/issues/289)
  — same symptom trace.
- [old LKML thread](https://lkml.iu.edu/0901.2/00169.html) on
  `e1000`/`e1000e` PCI power-state across kexec: on some boards the new
  kernel can't recover the NIC after the handoff.
- [Proxmox on Hetzner thread](https://forum.proxmox.com/threads/proxmox-crashing-on-hetzner-server-with-intel-i219-lm-nic.57271/)
  — same I219-LM NIC on Hetzner, same driver, same flakiness, with
  "disable C1E in BIOS" as a suggested mitigation (requires paid
  Hetzner KVM to apply).

Fix that worked: swap `nixos-anywhere`'s default kexec image for the
pinned `nixos-25.11` release build from
`nix-community/nixos-images`. Its kernel is ~1 year newer than the
default and has several `e1000e` fixes. Passed via
`--kexec https://github.com/nix-community/nixos-images/releases/download/nixos-25.11/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz`.

**Keep using this `--kexec` flag for any future re-install of this
box.** The default image has now failed twice in a row.

### Hetzner rescue is single-shot

Armed rescue is consumed on first boot — if the kexec'd installer
hangs and you hard-reset, the next boot tries to boot from disk (which
might be wiped) rather than rescue. If the box goes dark and stays
dark after a reset, re-arm rescue in the Robot panel's Rescue tab
before the next reset. Figured this out the hard way.

### Gotcha: `disko`-generated `grub.devices` clashes with `mirroredBoots`

Left for the record because the comment in
`modules/hosts/foundry/configuration.nix` is terse:

> Disko populates `grub.devices` from its disk list, which would
> otherwise auto-generate a third `mirroredBoots` entry mounted at
> /boot and each disk would end up listed twice, tripping the
> "duplicated devices" assertion.

Hence `boot.loader.grub.devices = lib.mkForce [];` in the config — the
install-to-both-disks behavior is handled by our explicit
`mirroredBoots` list, not by disko auto-filling `grub.devices`.

### `simon` has no password

SSH-key login works; `sudo` does not. This is by design, but it bit us
during bootstrap: the first install had no `deploy` key authorized,
`root` SSH is disabled, and `simon` can't sudo, so there was literally
**no way to activate a new config** without going back through rescue
+ `nixos-anywhere`. This is why the `deploy` public key is now baked
into the initial config — see `6777b94`. Any future bootstrap of a new
box should have a deploy key authorized from install time one.

## Still to do before Phase 2

- [ ] Re-commit the regenerated `hosts/foundry/hardware-configuration.nix`
  (the `nixos-25.11` kexec image's `nixos-generate-config` produced a
  slightly different file — dropped the `networking.useDHCP` stanza,
  which is harmless because `configuration.nix` already sets it).
- [ ] Second full reboot cycle from the laptop
  (`ssh deploy@foundry sudo reboot`) and confirm unlock + real
  system come up cleanly — validates Phase 1's exit criterion.
- [ ] Store the LUKS passphrase in the password manager (if not done
  already during the install prompt) and run `foundry-unlock-seed` on
  the laptop.
- [ ] Verify laptop → target deploy works end-to-end with a no-op
  change (bump a comment, `nixos-rebuild switch --target-host
  deploy@...`).
