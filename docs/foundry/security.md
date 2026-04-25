# Foundry Security

This file records the current security model and the tradeoffs behind it.

## Public surface

Allowed inbound ports:

| Port | Purpose |
|---|---|
| 80 | Caddy HTTP / ACME redirect |
| 443 | Caddy HTTPS |
| 62222 | main-system SSH |
| 2222 | initrd LUKS unlock SSH |

Port 22 is deliberately left for Hetzner rescue mode and is not open on the
running system.

The real server IP is not stored in this repo. Use `Host foundry` in
`~/.ssh/config`; helpers resolve it at runtime.

## SSH

The running system uses:

- key-only authentication
- no root login
- small `AllowUsers` list
- non-standard port 62222 to reduce bot noise
- CrowdSec watching SSH logs

The initrd SSH service on port 2222 exists only to unlock LUKS. It runs
`systemd-tty-ask-password-agent --query` directly through `ForceCommand`.

## Disk encryption

Root is encrypted with LUKS2 on top of mdraid RAID1. There is no usable TPM on
the current BIOS configuration, so every reboot needs a manual unlock.

The LUKS passphrase lives in Bitwarden. The macOS Keychain item used by
`foundry-unlock` is a convenience cache, not the authoritative backup.

## Secrets

sops secrets live in `modules/hosts/foundry/secrets.yaml`.

Recipients:

- laptop personal age key
- `foundry` SSH host key converted with `ssh-to-age`

Use `ssh-to-age` for the server recipient. Do not switch to upstream sops SSH
recipient syntax unless the NixOS config is changed accordingly; sops-nix expects
the age key derived from the SSH host key.

New `secrets.yaml` changes must be `git add`-ed before Nix evaluation because
flakes read the git-filtered source tree.

## Backups

`foundry` only holds the append-only Storage Box key. The full-access admin key
is laptop-only and is used for restores and pruning.

This means a server compromise should not be able to prune or rewrite backup
history.

Details live in [`backups.md`](backups.md).

## HTTP auth model

Foundry VTT remains public behind Caddy and uses Foundry's own authentication.
Do not put Foundry itself behind Authentik unless the player workflow changes.

Grafana uses native OIDC against Authentik. Loki and VictoriaMetrics stay bound
to loopback and are reached through Grafana's server-side datasource proxy.

Future admin UIs that do not support native auth should use an Authentik/Caddy
auth layer.

## CrowdSec

CrowdSec watches SSH and Caddy logs. The firewall bouncer enforces decisions
through nftables.

The Caddy-specific CrowdSec bouncer and AppSec path are intentionally deferred:
they add Nix maintenance cost and are not needed for the current threat model.

## Deliberate non-goals

- No mesh VPN dependency for basic server access.
- No public raw VictoriaMetrics or Loki endpoint.
- No full syscall/audit logging stack for a solo homelab.
- No TPM auto-unlock until a deliberate UEFI/PTT migration is worth the effort.
