# AGENTS.md

This is the short orientation file for coding agents working in this repository.
Use it to find the right source of truth, not as a replacement for the docs.

## Start here

- Repo architecture and module rules: [`docs/architecture.md`](docs/architecture.md)
- New laptop or Linux user bootstrap: [`docs/bootstrap-new-machine.md`](docs/bootstrap-new-machine.md)
- Current `foundry` server state: [`docs/foundry/overview.md`](docs/foundry/overview.md)
- Routine server operations: [`docs/foundry/operations.md`](docs/foundry/operations.md)
- Backups and restore drills: [`docs/foundry/backups.md`](docs/foundry/backups.md)
- Break-glass recovery: [`docs/foundry/recovery.md`](docs/foundry/recovery.md)
- Security model and tradeoffs: [`docs/foundry/security.md`](docs/foundry/security.md)
- Nice-to-have future work: [`docs/foundry/optional-roadmap.md`](docs/foundry/optional-roadmap.md)

## Common commands

```bash
home-manager switch --flake .#simon-darwin
nix flake check
nix develop
alejandra .
sops modules/hosts/foundry/secrets.yaml
foundry-unlock
```

## Working rules

- `flake.nix` is intentionally minimal: `mkFlake` plus `import-tree ./modules`.
- Every `.nix` file under `modules/` is auto-loaded and must be a valid
  flake-parts module. Do not drop plain NixOS modules there unwrapped.
- `hosts/foundry/hardware-configuration.nix` lives outside `modules/` because
  it is a generated plain NixOS module.
- Keep the server on the stable `nixpkgs` input. Home Manager and nix-darwin use
  `nixpkgs-devenv`; do not let rolling packages bleed onto `foundry`.
- The real server IP is not documented in this repo. Use `Host foundry` from
  `~/.ssh/config`.
- Prefer GitHub Actions deploys on `main`; use the laptop fallback only when the
  operations doc says that is the right path.
