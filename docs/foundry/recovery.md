# Foundry Recovery

Use this file when routine SSH and unlock paths are not enough.

## Recovery order

Try these in order:

1. Main system SSH: `ssh foundry`
2. Initrd unlock SSH during boot: `ssh -p 2222 root@foundry`
3. Hetzner Robot rescue mode
4. Clean reinstall with `nixos-anywhere`, then restore from restic

Rescue mode is free and PXE-booted by Hetzner. Paid KVM is only needed if BIOS
settings themselves need to change.

## Re-key sops after SSH host key rotation

sops-nix decrypts on `foundry` through `/etc/ssh/ssh_host_ed25519_key`. If that
key changes, re-wrap the secrets before the next deploy.

```bash
ssh-keyscan -t ed25519 -p 62222 foundry 2>/dev/null | ssh-to-age
```

Copy the new `age1...` recipient into `.sops.yaml`, replacing the `&foundry`
value. Then:

```bash
sops updatekeys modules/hosts/foundry/secrets.yaml
```

Commit `.sops.yaml` and `modules/hosts/foundry/secrets.yaml`, then deploy.

The laptop recipient stays in `.sops.yaml`, so the laptop can decrypt and
re-encrypt during rotation.

## Hetzner Robot rescue

Use when both the main sshd and initrd sshd are unreachable.

1. Open Hetzner Robot.
2. Activate rescue for the server.
   - OS: `linux`
   - architecture: `64 bit`
   - public key: current laptop key from Robot key management
3. Reboot the server from Robot.
4. Wait about two minutes.
5. SSH into rescue:

```bash
ssh -o StrictHostKeyChecking=accept-new -p 22 root@foundry
```

Rescue is single-shot. If you hard-reset again, re-activate rescue first.

## Mount the installed system from rescue

The LUKS container sits on mdraid, so assemble RAID before opening LUKS:

```bash
mdadm --assemble --scan
cat /proc/mdstat

cryptsetup open /dev/md/root cryptroot
mkdir -p /mnt
mount /dev/mapper/cryptroot /mnt

mount /dev/nvme0n1p2 /mnt/boot-1
mount /dev/nvme1n1p2 /mnt/boot-2
```

Paste the LUKS passphrase from Bitwarden when prompted.

From here, either fix the installed system in place or reinstall cleanly.

## Clean reinstall

Run from the laptop while the target is in rescue mode:

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#foundry \
  --target-host root@foundry \
  --build-on-remote \
  --kexec https://github.com/nix-community/nixos-images/releases/download/nixos-25.11/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz \
  --generate-hardware-config nixos-generate-config ./hosts/foundry/hardware-configuration.nix \
  --extra-files ~/.config/foundry-bootstrap/extra-files
```

The `--extra-files` tree must include:

```text
etc/secrets/initrd/ssh_host_ed25519_key
```

Without that file, the next boot's initrd SSH unlock path will not have its host
key.

After reinstall:

1. Unlock once through initrd SSH.
2. Let the normal deploy path converge the system.
3. Restore data from restic using [`backups.md`](backups.md).

## Pre-install cleanup

If the target has a previous install, old RAID/GPT metadata can confuse disko.
From rescue:

```bash
ssh root@foundry '
  mdadm --stop /dev/md127 2>/dev/null || true
  mdadm --zero-superblock /dev/nvme0n1p3 /dev/nvme1n1p3 2>/dev/null || true
  wipefs -a /dev/nvme0n1 /dev/nvme1n1
'
```

Triple-check the target before running wipe commands.

## Bootstrap artifacts on the laptop

These files live outside the repo:

```text
~/.config/foundry-bootstrap/
  deploy_ed25519
  deploy_ed25519.pub
  storagebox_adm
  extra-files/
    etc/secrets/initrd/
      ssh_host_ed25519_key
      ssh_host_ed25519_key.pub
```

Back them up somewhere private. Losing them means rotating keys, not losing data,
but it makes recovery noisier.

## Gotchas preserved from the first install

The default `nixos-anywhere` kexec image hung on this hardware after handoff:
SSH dropped, the NIC never came back, and the box stayed dark until a hard
reset. Use the pinned `nixos-25.11` kexec image in the reinstall command above.

Under systemd-initrd, initrd SSH needs:

```nix
boot.initrd.network.ssh.extraConfig = ''
  ForceCommand systemd-tty-ask-password-agent --query
'';
```

Without it, SSH lands in a root shell instead of the LUKS prompt.

`disko` auto-populates `grub.devices`; the host config forces it empty because
explicit `mirroredBoots` handles installing GRUB to both disks.

The `simon` user has SSH-key login but no password. Activation happens through
the `deploy` user, so any fresh bootstrap must authorize the deploy key from the
initial install.
