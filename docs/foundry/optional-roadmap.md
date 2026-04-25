# Optional Roadmap

The server baseline is complete. Items here are nice-to-have improvements, not
unfinished phases.

## UEFI + PTT auto-unlock

Goal: remove the manual SSH-in-initrd unlock step by sealing the LUKS key to a
firmware TPM.

Cost:

- one Hetzner KVM or remote-hands session
- clean reinstall
- careful restore drill afterwards

Outline:

1. In BIOS, disable CSM and enable firmware TPM / Intel PTT.
2. Switch the flake from legacy GRUB to UEFI boot.
3. Change the disko layout from BIOS boot partitions to EFI System Partitions.
4. Reinstall with `nixos-anywhere`.
5. Enroll LUKS with:

   ```bash
   systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/md/root
   ```

Keep the recovery passphrase in Bitwarden. TPM unsealing can fail after firmware
or Secure Boot changes.

## Foundry v13 alongside v12

Possible shape:

- parameterize the Foundry module by version, port, and data directory
- run v12 on port 30012 and v13 on port 30013
- expose a second Caddy vhost if both need to be reachable
- keep separate data directories and backups

Do this only when an actual migration needs parallel testing.

## Additional apps

The foundation is in place:

- feature module under `modules/features/`
- import from `modules/hosts/foundry/configuration.nix`
- Caddy vhost if public
- sops secrets if needed
- PostgreSQL database/user if needed
- backup paths
- monitoring and alerting hooks

Prefer boring NixOS modules and native service options over custom packaging.

## Alertmanager

Healthchecks.io covers service failures and backup dead-man checks. Alertmanager
could be useful later for metric-based alerts such as disk-full, RAID degraded,
or high memory pressure.

Only add it when there are enough Prometheus-style alert rules to justify the
extra moving part.

## Service isolation

More systemd hardening or NixOS containers could be added around selected apps.
For now, the current service boundaries, loopback-only data stores, Caddy,
Authentik, CrowdSec, and backups are the practical security baseline.

