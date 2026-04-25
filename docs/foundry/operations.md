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
ssh foundry sudo systemctl status postgresqlBackup.service --no-pager
ssh foundry sudo ls -lh /var/backup/postgresql
ssh foundry sudo -u postgres zstd -dc /var/backup/postgresql/all.sql.zstd | head
```

Expected:

- the `authentik` database exists
- `postgresqlBackup.service` succeeds
- `all.sql.zstd` is recent
- the dump starts with roles and database DDL

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
