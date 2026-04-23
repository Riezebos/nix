# BOOTSTRAP.md

Break-glass runbook for `foundry`. Skim once when nothing's on fire; re-read when
something is. The "why" behind every choice lives in `server_plan.md` — this file is
just the "how".

Everything here runs from the laptop unless a step says otherwise.

## Where things live

| Thing | Location |
|---|---|
| LUKS passphrase (authoritative) | Bitwarden |
| LUKS passphrase (daily cache) | macOS Keychain — `security=foundry-luks`, `account=foundry`; seeded via `foundry-unlock-seed` |
| Restic repo password (authoritative) | Bitwarden |
| Restic repo password (server-side copy) | sops → `restic/password` (encrypted in `modules/hosts/foundry/secrets.yaml`) |
| Append-only Storage Box SSH key | sops → `restic/ssh_key`; decrypted on the server only |
| Full-access (admin) Storage Box SSH key | `~/.config/foundry-bootstrap/storagebox_adm` on the laptop. **Never** on foundry, in sops, or in CI |
| Deploy SSH key (CI → foundry) | `~/.config/foundry-bootstrap/deploy_ed25519` on the laptop; mirrored as a GitHub Actions secret |
| Initrd SSH host key | `/etc/secrets/initrd/ssh_host_ed25519_key` on foundry, shipped via `nixos-anywhere --extra-files` during install |
| Authentik secret key | `/var/lib/authentik/secrets/secret-key` on foundry; generated locally on first boot and reused |
| Grafana OIDC client secret | `/var/lib/grafana/secrets/grafana-oidc-client-secret` on foundry; generated locally on first boot and read by Grafana |
| PostgreSQL logical dumps | `/var/backup/postgresql` on foundry; generated daily by `services.postgresqlBackup` and then copied to restic |
| Hetzner Robot account SSH key | Uploaded separately in Robot's "key management" — controls rescue-system access only |
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
# paste the LUKS passphrase from Bitwarden; session closes itself once the
# real system takes over
```

**SSH ports on this box:**

| Port | Service |
|---|---|
| 62222 | main-system sshd (`services.openssh.ports` in `modules/hosts/foundry/configuration.nix`). The `Host foundry` block in `~/.ssh/config` must set `Port 62222` — everything in this file and the `foundry-unlock` / `foundry-logs` helpers relies on that. CI has its own copy of the port in `modules/deploy.nix` (`sshOpts`) and the `FOUNDRY_KNOWN_HOSTS` secret must be regenerated at this port if the host key ever rotates. |
| 2222 | initrd LUKS-unlock sshd (`boot.initrd.network.ssh`) |
| 22 | **only** reachable when the box is in Hetzner rescue mode — the production firewall keeps :22 closed on the running system. This is deliberate: rescue and prod live on different ports, so their host keys never collide in `known_hosts`. |

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
# 1. Derive the new age recipient from the live production host key.
# Main-system sshd lives on 62222; port 22 is Hetzner rescue only and would
# yield the wrong key here.
ssh-keyscan -t ed25519 -p 62222 foundry 2>/dev/null | ssh-to-age
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
#
# Keep this on ONE LINE. restic word-splits `rclone.program` on whitespace
# and does not run it through a shell — backslash-newlines stay literal and
# ssh then reads the split tokens as positional args, landing on e.g.
# "Could not resolve hostname serve".
SB_SSH='ssh -p 23 -i ~/.config/foundry-bootstrap/storagebox_adm -o ProxyJump=foundry u580408-sub2@u580408-sub2.your-storagebox.de'
```

Fetch the repo password and restore:

```
# zsh and bash disagree on `read`'s prompt flag — zsh uses `?prompt` in the
# variable argument, bash uses `-p prompt`. This form works in both.
printf 'Enter restic repo password: ' >&2
IFS= read -rs RESTIC_PASSWORD
echo
export RESTIC_PASSWORD

# List snapshots — pick one or use `latest`
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  snapshots

# `--path` and `--include` do DIFFERENT jobs and you need both:
#   --path <p>    = snapshot SELECTOR. `latest` picks the newest
#                   snapshot whose `paths` field contains <p>. Nothing
#                   about which files are restored.
#   --include <p> = file-tree FILTER. After a snapshot is chosen,
#                   extract only paths under <p>.
# The daily snapshot carries paths = [/var/lib/foundryvtt,
# /var/lib/victoriametrics/snapshots, /var/lib/loki] — so `--path` alone
# restores all 8 GB of it. Add `--include` to pick one subtree.
# Separately, the rclone URL's `<path>` segment is cosmetic: the Storage
# Box's forced command chroots every call to the same directory, so
# `foundry` and `foundry-journal` resolve to the same restic repo. The
# `--path` filter is what distinguishes daily from journal snapshots.
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  restore latest \
    --path /var/lib/foundryvtt \
    --include /var/lib/foundryvtt \
    --target /tmp/foundry-restore

unset RESTIC_PASSWORD
```

Restored paths:

- `/tmp/foundry-restore/var/lib/foundryvtt`  — worlds + modules + systems

Repeat with matching `--path` + `--include` pairs for the other subtrees (VM snapshots, Loki). Drop `--target` and run `snapshots` to see what's available first:
```
nix run nixpkgs#restic -- -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry snapshots
```

The 15-min journal snapshots live in the same repo, filtered by path:

```
# Re-use the RESTIC_PASSWORD export from the previous block (or re-prompt).
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry-journal \
  restore latest \
    --path /var/log/journal \
    --target /tmp/foundry-journal-restore
```

PostgreSQL logical dumps live in the main repo too:

```
# Re-use the RESTIC_PASSWORD export from the previous block (or re-prompt).
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  restore latest \
    --path /var/backup/postgresql \
    --include /var/backup/postgresql \
    --target /tmp/foundry-pg-restore
```

Restored paths:

- `/tmp/foundry-pg-restore/var/backup/postgresql/all.sql.zstd`
- `/tmp/foundry-pg-restore/var/backup/postgresql/all.prev.sql.zstd`

Restore into a scratch cluster or disposable VM, not the live server:

```
zstd -dc /tmp/foundry-pg-restore/var/backup/postgresql/all.sql.zstd \
  | psql postgres
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
# Restore the entire VM data tree (RESTIC_PASSWORD must be exported).
# We back up all of /var/lib/victoriametrics because `snapshots/<name>/`
# is a structure of relative symlinks back into /var/lib/victoriametrics/
# data/<table>/snapshots/<name>/ — grabbing only `snapshots/` would
# restore dangling pointers.
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  restore latest \
    --path /var/lib/victoriametrics \
    --include /var/lib/victoriametrics \
    --target /tmp/vm-restore

# Point VM at the restored data dir directly. The live data + the
# snapshot-hardlink tree are both there; VM opens it like its own
# working dir.
nix run nixpkgs#victoriametrics -- \
  -storageDataPath=/tmp/vm-restore/var/lib/victoriametrics \
  -httpListenAddr=127.0.0.1:8428 \
  -retentionPeriod=12

# In another shell, query it. Use a `time=` inside the restored window
# (snapshot dir name = YYYYMMDDhhmmss-<hex>), since /query defaults to now.
curl -sG 'http://127.0.0.1:8428/api/v1/query' \
  --data-urlencode 'query=up' \
  --data-urlencode 'time=2026-04-23T02:00:00Z' | jq .
```

Point a local Grafana at `http://127.0.0.1:8428` as a Prometheus datasource if you
want graphs; the stock node-exporter dashboard (Grafana.com ID 1860) works unchanged.

## Authentik + Grafana bootstrap

Phase 5f wires up Authentik, Grafana OIDC, and the Caddy vhosts, but Authentik still
needs one one-time app/provider setup in the admin UI.

1. Deploy Phase 5f and wait for `authentik-server.service` + `authentik-worker.service`
   to go green.
2. Open the initial setup flow:
   ```
   https://auth.simonito.com/if/flow/initial-setup/
   ```
   Keep the trailing slash. Create the first admin user there.
3. Read the Grafana client secret from the server:
   ```
   ssh foundry sudo cat /var/lib/grafana/secrets/grafana-oidc-client-secret
   ```
4. In Authentik, create an application/provider pair for Grafana with:
   - client ID: `grafana`
   - client secret: the value from the previous step
   - redirect URI: `https://grafana.simonito.com/login/generic_oauth`
   - scopes: `openid`, `profile`, `email`
5. Group-to-role mapping is already baked into Grafana:
   - `grafana-admins` → `GrafanaAdmin`
   - `foundry-admins` → `Admin`
   - everything else → `Viewer`
6. Test the full login flow at:
   ```
   https://grafana.simonito.com
   ```

Grafana keeps its local login form enabled as a break-glass path while you finish the
Authentik-side app setup.

## CrowdSec verification

After the first Phase 5f deploy, confirm both log sources and remediation work:

```
ssh foundry sudo cscli metrics
ssh foundry sudo cscli acquisitions list
ssh foundry sudo cscli decisions add --ip 198.51.100.23 --duration 10m --reason phase-5f-test
ssh foundry sudo nft list ruleset | rg crowdsec
ssh foundry sudo cscli decisions delete --ip 198.51.100.23
```

What you want to see:

- `cscli metrics` shows both `journalctl`/`syslog` and Caddy file ingestion.
- `cscli acquisitions list` includes the SSH journal and `/var/log/caddy/access-*.log`.
- `nft list ruleset` shows the CrowdSec tables/sets populated by the firewall bouncer.

## PostgreSQL verification

Phase 6 makes PostgreSQL shared infrastructure instead of an Authentik-only detail.
After the first deploy, verify both provisioning and the logical dump path:

```
ssh foundry sudo -u postgres psql -tAc '\l'
ssh foundry sudo systemctl status postgresqlBackup.service --no-pager
ssh foundry sudo ls -lh /var/backup/postgresql
ssh foundry sudo -u postgres zstd -dc /var/backup/postgresql/all.sql.zstd | head
```

What you want to see:

- the `authentik` database still exists in the shared cluster
- `postgresqlBackup.service` completes successfully
- `/var/backup/postgresql/all.sql.zstd` exists and is recent
- the decompressed dump starts with roles / database DDL from `pg_dumpall`

## Yearly restore drill

Run this once after landing Phase 5e, then every 12 months. Put the next date in
your calendar — don't rely on memory.

1. **Restore the FoundryVTT path** to `/tmp/foundry-restore` per "Restore from restic" above — always pass `--path /var/lib/foundryvtt`, otherwise `latest` returns a journal snapshot (all paths share one repo on the Storage Box).
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
4. **Confirm local VictoriaMetrics starts against the restored snapshot.**
   Two checks — "VM opened the data" and "there's real content in it":
   ```
   # (run the VM restore + spin-up from the previous section)

   # (a) Is the snapshot non-empty? This is time-independent.
   curl -s 'http://127.0.0.1:8428/api/v1/label/__name__/values' \
     | jq '.data | length'
   # expect a few hundred metric names

   # (b) Was scraping actually working at snapshot time? /api/v1/query
   # evaluates at `time=now` by default, and the snapshot's data ends at
   # the moment the snapshot was taken — so use a time INSIDE the window.
   # The snapshot dir name encodes the time: `YYYYMMDDhhmmss-<hex>`.
   # Pick something a few minutes before that.
   curl -sG 'http://127.0.0.1:8428/api/v1/query' \
     --data-urlencode 'query=up{job="node"}' \
     --data-urlencode 'time=2026-04-23T02:00:00Z' | jq .
   ```
   Expect (a) non-zero and (b) `data.result` non-empty with one entry per
   scrape target. Both empty = snapshot restored but VM isn't seeing the
   data — drill failed, investigate. Only (b) empty = scrape wasn't running
   at that time, pick a different `time=` value.
5. **Tear down:**
   ```
   pkill -f 'storageDataPath=.*vm-restore'    # kill local VM
   rm -rf /tmp/foundry-restore /tmp/vm-restore /tmp/foundry-journal-restore
   unset RESTIC_PASSWORD
   ```
   If you toggled External Reachability on, toggle it off in the Storage Box
   console.

Passing all four is the whole drill. Anything that fails turns into a ticket
before you move on — a backup you can't restore is a backup that doesn't exist.

## Hetzner Robot rescue runbook (break-glass)

Use when **both** `ssh foundry` (port 62222) and `ssh -p 2222 root@foundry` (initrd)
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
   # paste the LUKS passphrase from Bitwarden
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
- Losing the Robot account (password + 2FA recovery codes). Keep those in Bitwarden
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
   recovery passphrase in Bitwarden — if PCR 7 changes (firmware update, Secure
   Boot signature change), TPM unsealing fails and you're back to typing the
   passphrase manually.
