# BOOTSTRAP.md

Break-glass runbook for `foundry`. Skim once when nothing's on fire; re-read when
something is. The "why" behind every choice lives in `server_plan.md` — this file is
just the "how".

Everything here runs from the laptop unless a step says otherwise.

## Where things live

| Thing | Location |
|---|---|
| LUKS passphrase (authoritative) | 1Password, item "foundry LUKS" |
| LUKS passphrase (daily cache) | macOS Keychain — `security=foundry-luks`, `account=foundry`; seeded via `foundry-unlock-seed` |
| Restic repo password (authoritative) | 1Password, item "foundry restic repo password" |
| Restic repo password (server-side copy) | sops → `restic/password` (encrypted in `modules/hosts/foundry/secrets.yaml`) |
| Append-only Storage Box SSH key | sops → `restic/ssh_key`; decrypted on the server only |
| Full-access (admin) Storage Box SSH key | `~/.config/foundry-bootstrap/storagebox_adm` on the laptop. **Never** on foundry, in sops, or in CI |
| Deploy SSH key (CI → foundry) | `~/.config/foundry-bootstrap/deploy_ed25519` on the laptop; mirrored as a GitHub Actions secret |
| Initrd SSH host key | `/etc/secrets/initrd/ssh_host_ed25519_key` on foundry, shipped via `nixos-anywhere --extra-files` during install |
| Hetzner Robot account SSH key | Uploaded separately in Robot's "key management" — controls rescue-system access only |
| Hetzner Robot 2FA recovery codes | 1Password |
| Age recipient for sops | `.sops.yaml` — `&simon` (laptop) + `&foundry` (server's host key → age) |

## Routine: unlock after a reboot

Initrd sshd on port 2222 drops straight into the LUKS passphrase prompt via
`ForceCommand systemd-tty-ask-password-agent --query`
(see `modules/hosts/foundry/configuration.nix`).

```
foundry-unlock                       # one-shot, reads the Keychain
```

Manual fallback if the Keychain item is missing or the helper breaks:

```
ssh -p 2222 -o StrictHostKeyChecking=accept-new root@foundry
# paste the LUKS passphrase from 1Password; session closes itself once the
# real system takes over
```

**SSH ports on this box:**

| Port | Service |
|---|---|
| 62222 | main-system sshd (`services.openssh.ports` in `modules/hosts/foundry/configuration.nix`). The `Host foundry` block in `~/.ssh/config` must set `Port 62222` — the `foundry-unlock` / `foundry-logs` helpers rely on that. |
| 22 | **transitional** — sshd currently dual-listens on 22 + 62222 so that deploy-rs's magic-rollback confirm hook (which opens a fresh SSH back to the server post-activation) doesn't time out during the port move. Phase 2 drops :22 once CI is updated to `--ssh-opts '-o Port=62222'` and `FOUNDRY_KNOWN_HOSTS` is regenerated at the new port. After phase 2, :22 is reachable **only** when the box is in Hetzner rescue mode — rescue PXE-boots its own kernel so the production firewall is bypassed there. |
| 2222 | initrd LUKS-unlock sshd (`boot.initrd.network.ssh`) |

User is `root` because initrd has no other accounts; authorisation is by key
(the keys on `users.users.simon.openssh.authorizedKeys.keys`). If port 2222's
host key has rotated since your last unlock, run
`ssh-keygen -R '[foundry]:2222'` first — the port-22 known_hosts entry is
separate and untouched.

## Re-keying sops after the server's SSH host key rotates

sops-nix decrypts on foundry using `/etc/ssh/ssh_host_ed25519_key`. If that
key changes (reinstall, leak, rotation), re-wrap every sops file for the new
age recipient before the next deploy — otherwise `/run/secrets/*` never
populate and activation stalls.

```
# 1. Derive the new age recipient from the live server host key
ssh-keyscan -t ed25519 -p 22 foundry 2>/dev/null | ssh-to-age
# prints age1...; copy it

# 2. In .sops.yaml, replace the &foundry value with the new recipient

# 3. Re-wrap every file matched by creation_rules
sops updatekeys modules/hosts/foundry/secrets.yaml

# 4. Commit .sops.yaml + the updated secrets.yaml, then deploy
```

The laptop's `&simon` age key stays in the recipient list throughout, so
decrypt-to-re-encrypt always works from the laptop.

## Restore from restic (full-access credential)

Storage Box External Reachability is off in normal operation. Either toggle it on
temporarily in the Storage Box console, or bounce through foundry:

```
# Option A — temporary direct access: toggle External Reachability ON, then OFF after.
# Option B — ProxyJump via foundry (leave External Reachability off):
SB_SSH='ssh -p 23 -i ~/.config/foundry-bootstrap/storagebox_adm \
        -o ProxyJump=deploy@foundry \
        u580408-sub2@u580408-sub2.your-storagebox.de'
```

Fetch the repo password and restore:

```
op read "op://Personal/foundry restic repo password/password" > /tmp/pw
chmod 600 /tmp/pw
trap 'shred -u /tmp/pw 2>/dev/null || rm -f /tmp/pw' EXIT

# List snapshots — pick one or use `latest`
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  --password-file /tmp/pw \
  snapshots

# Full restore to a scratch tree
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  --password-file /tmp/pw \
  restore latest --target /tmp/foundry-restore
```

Restored paths:

- `/tmp/foundry-restore/var/lib/foundryvtt`  — worlds + modules + systems
- `/tmp/foundry-restore/var/lib/victoriametrics/snapshots/<name>`  — frozen VM tree
- `/tmp/foundry-restore/var/lib/loki`  — tsdb chunks + index

The 15-min journal repo is a separate repository:

```
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry-journal \
  --password-file /tmp/pw \
  restore latest --target /tmp/foundry-journal-restore
```

## Crash analysis (no server required)

Journal is on the Storage Box with ≤15 min lag.

```
foundry-logs -u foundryvtt --since -1h        # any journalctl flags pass through
foundry-logs -p err -n 200
```

Metrics from the same window — restore the daily snapshot's VM tree and run
VictoriaMetrics locally against it (no install needed):

```
# Restore just the VM snapshot path
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  --password-file /tmp/pw \
  restore latest \
    --path /var/lib/victoriametrics/snapshots \
    --target /tmp/vm-restore

# Find the snapshot name and start VM against it
snap=$(ls /tmp/vm-restore/var/lib/victoriametrics/snapshots | head -1)
nix run nixpkgs#victoriametrics -- \
  -storageDataPath="/tmp/vm-restore/var/lib/victoriametrics/snapshots/$snap" \
  -retentionPeriod=12

# In another shell, query it
curl -s 'http://127.0.0.1:8428/api/v1/query?query=up' | jq .
```

Point a local Grafana at `http://127.0.0.1:8428` as a Prometheus datasource if you
want graphs; the stock node-exporter dashboard (Grafana.com ID 1860) works unchanged.

## Yearly restore drill

Run this once after landing Phase 5e, then every 12 months. Put the next date in
your calendar — don't rely on memory.

1. **Restore the daily repo** to `/tmp/foundry-restore` per "Restore from restic" above.
2. **Confirm FoundryVTT data is intact:**
   ```
   ls /tmp/foundry-restore/var/lib/foundryvtt/Data/worlds
   jq '.title, .system, .coreVersion' \
     /tmp/foundry-restore/var/lib/foundryvtt/Data/worlds/*/world.json
   ```
   Expect every world listed, with sane metadata.
3. **Confirm `foundry-logs` returns fresh journal entries:**
   ```
   foundry-logs --since -6h -n 50
   ```
   Expect entries dated within the last six hours. If it returns nothing, the
   15-min journal job is broken and you won't have crash forensics when you need
   them — fix before moving on.
4. **Confirm local VictoriaMetrics starts against the restored snapshot:**
   ```
   # (run the VM restore + spin-up from the previous section)
   curl -s 'http://127.0.0.1:8428/api/v1/query?query=up{job="node"}' | jq .
   ```
   Expect a non-empty `result` array with at least one `value`. A 200 with
   `"result": []` means the snapshot restored but the scrape labels don't match
   — still a red flag; VM started but the data path is wrong.
5. **Tear down:**
   ```
   pkill -f 'storageDataPath=.*vm-restore'    # kill local VM
   rm -rf /tmp/foundry-restore /tmp/vm-restore /tmp/foundry-journal-restore
   shred -u /tmp/pw 2>/dev/null || rm -f /tmp/pw
   ```
   If you toggled External Reachability on, toggle it off in the Storage Box
   console.

Passing all four is the whole drill. Anything that fails turns into a ticket
before you move on — a backup you can't restore is a backup that doesn't exist.

## Hetzner Robot rescue runbook (break-glass)

Use when **both** `ssh foundry` (port 22) and `ssh -p 2222 root@foundry` (initrd)
are unreachable. Rescue is PXE-booted over Hetzner's network, independent of
anything on the disks or in the NixOS config. It's free and always available;
paid KVM is only needed if the BIOS itself is unreachable (see "Optional upgrade
path" below).

1. **Activate rescue.** https://robot.hetzner.com → Server → the foundry row →
   Rescue tab.
   - OS: `linux`, arch: `64 bit`.
   - Public key: whichever key is currently in this Robot account (this is your
     laptop's key — see "Keeping the Robot SSH key in sync" below; if drift is
     suspected, upload the current laptop pubkey from "key management" *before*
     activating).
   - Click **Activate rescue system**. Rescue is **single-shot** — if you need to
     hard-reset a second time, re-activate first or the next boot hits the disks.

2. **Reboot into rescue.** Server tab → Reset → try "Send CTRL+ALT+DEL" first,
   then "Execute an automatic hardware reset" if the box is wedged. Wait ~2 min.

3. **SSH in.** Rescue runs on port 22; production sshd runs on 62222. Because
   known_hosts keys the entry by port, there's no collision with your existing
   `foundry` entry — the rescue host key lands under `[foundry]:22` (or under
   the raw IP) and the prod entry under `[foundry]:62222` stays untouched.
   ```
   ssh -o StrictHostKeyChecking=accept-new -p 22 root@foundry
   ```

4. **Assemble RAID + open LUKS + mount.** On this box the LUKS container sits on
   the mdraid array (not a GPT partition), so RAID assembly must come first:
   ```
   mdadm --assemble --scan
   cat /proc/mdstat                       # expect md/root, State: clean
   cryptsetup open /dev/md/root cryptroot
   # paste the LUKS passphrase from 1Password
   mkdir -p /mnt
   mount /dev/mapper/cryptroot /mnt
   mount /dev/nvme0n1p2 /mnt/boot-1       # only needed if touching GRUB
   mount /dev/nvme1n1p2 /mnt/boot-2
   ```

5. **Fix in place**, or **reinstall clean** via `nixos-anywhere` (the flake is
   declarative — reinstall is cheap) and restore data from restic afterwards:
   ```
   # From the laptop, with the Hetzner-registered key authorised on rescue:
   nix run github:nix-community/nixos-anywhere -- \
     --flake github:Riezebos/nix#foundry \
     --target-host root@foundry \
     --extra-files ~/.config/foundry-bootstrap/initrd-host-key-dir
   ```
   The `--extra-files` dir must contain `etc/secrets/initrd/ssh_host_ed25519_key`
   — otherwise the next boot's initrd has no host key and `ssh -p 2222` fails.
   After first unlock + deploy, run "Restore from restic" against the fresh box.

## Keeping the Robot SSH key in sync

Rescue authorises whatever key is in the Robot account **at the moment rescue is
activated**, not what's on the server. If those drift, rotating the laptop key
locks you out of rescue silently — there's no alert.

Every time you rotate the laptop's SSH key, do these in the same session:

- **Robot:** robot.hetzner.com → top-right user menu → "key management" → add the
  new pubkey, remove the old one.
- **Server `authorized_keys`:** update `users.users.simon.openssh.authorizedKeys.keys`
  in `modules/hosts/foundry/configuration.nix`, deploy.
- **GitHub:** add the new key under Settings → SSH keys (if the old one is
  there).
- **Storage Box Robot key:** normally identical to the Robot account key — same
  "key management" page covers both.

Paranoia list (things that would break the free rescue path):

- Removing the Robot key without adding a replacement first.
- Losing the Robot account (password + 2FA recovery codes). Keep those in 1Password
  alongside the LUKS passphrase. Test a login from your phone at least once.
- BIOS boot order breaking PXE — can't happen by accident on this box, we have
  no BIOS access.

## Optional future upgrade: UEFI + PTT (auto-unlock)

Lifts the ssh-in-initrd dance — the firmware TPM unseals the LUKS key on boot
and the box comes up without operator interaction. Not required; keep the legacy
path until it genuinely annoys you. Cost: one Hetzner KVM/remote-hands session
(~€25, one-time). **This is the only scenario where paid KVM enters the
picture** — rescue (free) handles everything short of "the BIOS itself is
unreachable".

1. **Robot → order KVM / remote-hands session** against foundry.
2. **In BIOS (during the KVM window):**
   - Advanced → CSM → **Disabled** (switches boot mode from Legacy/CSM to UEFI).
   - Advanced → Trusted Computing → TPM Device Selection → **Firmware TPM (PTT)**.
     Intel PTT is supported by the C246 chipset on this board.
   - Optional: Secure Boot → Enabled.
   - Save and reboot once to confirm UEFI comes up.
3. **Branch the flake** (can be prepared beforehand, merged after step 2):
   - Replace `boot.loader.grub` with `boot.loader.systemd-boot.enable = true;`,
     drop `mirroredBoots`.
   - In `modules/hosts/foundry/disko.nix`, swap the 1 MiB EF02 BIOS boot partition
     + ext4 `/boot-N` for a single 512 MiB EF00 EFI System Partition per disk.
   - Remove the `foundry-unlock` helpers from `modules/home/shared.nix` once
     auto-unlock is confirmed working.
4. **Reinstall from rescue via `nixos-anywhere`** — same procedure as step 5 of
   the rescue runbook, but against the UEFI-configured flake branch. This wipes
   the disks; restore from restic after.
5. **Enroll the LUKS slot to the TPM** (on the freshly installed system, after
   one SSH-initrd unlock to get in):
   ```
   systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/md/root
   ```
6. **Reboot** and confirm the box comes up without touching port 2222. Keep a
   recovery passphrase in 1Password — if PCR 7 changes (firmware update, Secure
   Boot signature change), TPM unsealing fails and you're back to typing the
   passphrase manually.
