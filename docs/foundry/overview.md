# Foundry Overview

`foundry` is the finished NixOS server baseline. Future phases are optional
improvements, not blockers for the current operating model.

## Hardware

Hetzner auction server, surveyed April 2026:

| Component | Detail |
|---|---|
| Board | ASUS WS C246 DC workstation board |
| CPU | Intel Xeon E-2176G, 6 cores / 12 threads |
| RAM | 64 GiB DDR4 ECC |
| Disks | 2x Samsung PM983 U.2 NVMe, 960 GB |
| NIC | Intel I219-LM |
| Firmware | Legacy BIOS / CSM |
| TPM | No usable TPM device exposed |

The hardware reality drives the boot design: legacy BIOS, GRUB, mirrored boot
partitions, LUKS, and SSH-in-initrd unlock. UEFI + PTT auto-unlock is documented
as an optional future upgrade in
[`optional-roadmap.md`](optional-roadmap.md).

## Disk and boot

The server uses:

- mirrored `/boot` partitions, one on each NVMe
- mdraid RAID1 across the root partitions
- LUKS2 on top of mdraid
- ext4 on the decrypted root volume
- GRUB installed to both disks through `mirroredBoots`

Every reboot pauses in initrd until the LUKS passphrase is entered. The normal
unlock path is:

```bash
foundry-unlock
```

Manual fallback:

```bash
ssh -p 2222 root@foundry
```

## Services

| Service | Purpose | Exposure |
|---|---|---|
| Foundry VTT | Game server | Public through Caddy |
| Caddy | TLS and reverse proxy | Public ports 80/443 |
| Authentik | Admin identity provider | Public vhost |
| Grafana | Dashboards | Public vhost with OIDC |
| VictoriaMetrics | Metrics store | Loopback only |
| node_exporter | Host metrics | Loopback only |
| Loki | Log store | Loopback only |
| Alloy | Journal/log shipping | Local agent |
| CrowdSec | SSH/Caddy abuse detection | Local engine + firewall bouncer |
| PostgreSQL | Shared application database | Local service |
| restic | Backups to Hetzner Storage Box | Outbound only |
| Healthchecks.io pings | Failure/dead-man alerts | Outbound only |

`foundry` is built from `modules/hosts/foundry/configuration.nix`, which imports
the feature modules in `modules/features/`.

## Deploy model

Normal path:

1. Commit and push changes.
2. GitHub Actions builds checks and the `foundry` system closure.
3. A push to `main` deploys through deploy-rs.
4. deploy-rs activates the new generation and rolls back if the host fails its
   health check.

Manual fallback from the laptop is documented in
[`operations.md`](operations.md).

## Backup model

Backups use restic over rclone-over-SSH to a Hetzner Storage Box.

- The server has only the append-only credential.
- The laptop holds the full-access admin credential for restore and prune.
- Foundry data is staged locally before backup.
- VictoriaMetrics snapshot data, Loki data, PostgreSQL logical dumps, and
  systemd journals are backed up.
- Journal snapshots run every 15 minutes for crash analysis.

Restore details and the yearly restore drill live in
[`backups.md`](backups.md).

## Important files

- `modules/hosts/foundry/configuration.nix`: host config and service imports
- `modules/hosts/foundry/disko.nix`: disk layout
- `hosts/foundry/hardware-configuration.nix`: generated hardware module
- `modules/features/restic.nix`: backup jobs and integrity checks
- `modules/features/monitoring.nix`: metrics, logs, and Grafana plumbing
- `modules/features/alerting.nix`: Healthchecks.io wiring
- `modules/deploy.nix`: deploy-rs node config

The real public IP is deliberately not in this repo. The laptop resolves
`foundry` through `~/.ssh/config`.
