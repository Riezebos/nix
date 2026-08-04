# Foundry Operations

Routine commands for the finished `foundry` server.

## Unlock after reboot

Normal path from the laptop:

```bash
foundry-unlock
```

The helper reads the LUKS passphrase from the macOS Keychain and SSHes into the
initrd on port 2222. It waits until the real system SSH port comes back.

Seed the Keychain item once:

```bash
foundry-unlock-seed
```

Manual fallback:

```bash
ssh -p 2222 root@foundry
```

Paste the LUKS passphrase from Bitwarden. The SSH session closes once the real
system takes over.

SSH ports:

| Port | Meaning |
|---|---|
| 62222 | main-system sshd |
| 2222 | initrd LUKS unlock sshd |
| 22 | Hetzner rescue mode only |

## Deploys

Preferred path: merge to `main` and let GitHub Actions deploy through deploy-rs.

Manual fallback from the laptop:

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#foundry \
  --target-host deploy@foundry \
  --build-host deploy@foundry \
  --no-reexec \
  --sudo
```

Use the fallback for emergencies, CI outages, or deliberate local activation.
It does not have deploy-rs magic rollback.

## FoundryVTT upgrades

The installer zip is a personal-license file and is not available to GitHub
Actions. Deploys build on foundry (`remoteBuild = true` in
`modules/deploy.nix`) precisely so the `requireFile` input resolves against
the copy seeded into foundry's own store.

To bump the pinned build, seed the new zip first, then update the pin:

```bash
scp FoundryVTT-Linux-<version>.zip foundry:/tmp/
ssh foundry sudo nix-store --add-fixed sha256 /tmp/FoundryVTT-Linux-<version>.zip
ssh foundry rm /tmp/FoundryVTT-Linux-<version>.zip
```

Then update `majorVersion` / `build` in `modules/features/foundryvtt.nix` and
merge. If the zip is missing, the deploy fails on foundry at build time,
before any activation.

Do not move this build to the runner without re-measuring it and solving the
licensed installer input. The 2026-08-04 runner-side measurements predate the
removal of the launcher and curated sandbox store, so they no longer represent
the current closure. See the comment in `modules/deploy.nix` and
`.github/workflows/diagnose-deploy-build.yml`.

## Local verification

Basic service checks:

```bash
ssh foundry systemctl --failed
ssh foundry sudo systemctl status foundryvtt caddy authentik-server authentik-worker grafana
ssh foundry sudo systemctl status victoriametrics loki alloy
```

Backup timers:

```bash
ssh foundry systemctl list-timers 'restic*' 'postgresqlBackup*'
```

Firewall and listening ports:

```bash
ssh foundry sudo ss -tulpn
ssh foundry sudo nft list ruleset
```

## Authentik and Grafana

Grafana uses native OIDC through Authentik.

The Grafana client secret lives on the server:

```bash
ssh foundry sudo cat /var/lib/grafana/secrets/grafana-oidc-client-secret
```

Authentik application/provider values:

- client ID: `grafana`
- redirect URI: `https://grafana.simonito.com/login/generic_oauth`
- scopes: `openid`, `profile`, `email`

Grafana role mapping is configured declaratively:

- `grafana-admins` -> `GrafanaAdmin`
- `foundry-admins` -> `Admin`
- everyone else -> `Viewer`

Grafana keeps local login enabled as a break-glass path.

## CrowdSec verification

```bash
ssh foundry sudo cscli metrics
ssh foundry sudo cscli acquisitions list
ssh foundry sudo cscli decisions add --ip 198.51.100.23 --duration 10m --reason manual-test
ssh foundry sudo nft list ruleset | rg crowdsec
ssh foundry sudo cscli decisions delete --ip 198.51.100.23
```

Expected:

- SSH journal and Caddy access logs are acquired.
- CrowdSec decisions appear in nftables.
- The test decision can be added and removed cleanly.

## PostgreSQL verification

```bash
ssh foundry sudo -u postgres psql -tAc '\l'
ssh foundry sudo systemctl status pgbouncer.service --no-pager
ssh foundry sudo ss -tulpn | rg ':6432'
ssh foundry sudo systemctl status postgresqlBackup.service --no-pager
ssh foundry sudo ls -lh /var/backup/postgresql
ssh foundry sudo -u postgres zstd -dc /var/backup/postgresql/all.sql.zstd | head
```

Expected:

- the `authentik` and `deliverable` databases exist
- PgBouncer is listening on public port `6432`
- `postgresqlBackup.service` succeeds
- `all.sql.zstd` is recent
- the dump starts with roles and database DDL

## Sandbox verification

Development sandboxes are managed with the `sandcastle` CLI over SSH. There is
no web UI; the retired Phoenix launcher is no longer deployed.

```bash
ssh foundry sudo sandcastle list
ssh foundry sudo sandcastle create scratch --packages node python
ssh foundry sudo sandcastle start scratch
ssh foundry sudo sandcastle status scratch
ssh -t foundry sudo sandcastle ssh scratch
ssh foundry sudo sandcastle logs scratch -n 50
ssh foundry sudo sandcastle rebuild scratch
ssh foundry sudo sandcastle stop scratch
ssh foundry sudo sandcastle delete scratch --yes
```

Expected:

- `create` reserves an address in `10.88.0.16`-`10.88.0.99`, builds a runner,
  and leaves the sandbox stopped.
- `start` returns only once the guest has held a running state for a few
  seconds. `microvm@<name>.service` is `Type=simple` with `Restart=always`, so
  a silent boot failure would otherwise look like success.
- `sandcastle ssh` lands in the guest as `dev` over AF_VSOCK. No guest SSH
  port is opened, so nothing new appears in the host firewall.
- The guest TAP device is `sc-` plus a hash and is attached to
  `br-sandboxes`: `ssh foundry ip link show master br-sandboxes`.
- `rebuild` installs a new runner and rolls `current` back if the guest fails
  to come up.
- `delete` removes the disks and specification but keeps
  `/var/lib/sandcastle/credentials/<name>` unless `--delete-credentials` is
  passed.

Sandbox egress currently still goes through the launcher-era nftables
allowlist, so a sandbox reaches DNS and the allowlisted destinations only.
General public-internet egress with private-range blocking is upstream M3.

Sandbox disks are not backed up. Commit and push work from inside the sandbox.

## Robot SSH key sync

Rescue mode authorizes the SSH key registered in Hetzner Robot at rescue
activation time. When rotating the laptop SSH key, update all of these in the
same session:

- Hetzner Robot key management
- `users.users.simon.openssh.authorizedKeys.keys` in the server config
- GitHub SSH keys, if needed
- Storage Box Robot key, if it uses the same key

Keep the Robot account credentials, 2FA recovery codes, and the LUKS passphrase
in Bitwarden.
