# Nix configuration

Personal Nix flake for my laptops, development environments, and the `foundry`
NixOS server.

This repository currently manages:

- Home Manager configs for `simon-darwin`, `simon-m4`, and `simon-linux`
- a nix-darwin system config for `Simons-MacBook-Air`
- the `foundry` NixOS server, including Foundry VTT, Caddy, Authentik,
  monitoring, backups, alerting, CrowdSec, and PostgreSQL

## Common commands

```bash
# Apply Home Manager config on the primary Mac
home-manager switch --flake .#simon-darwin
# or:
hm-mac

# Validate the flake and pre-commit hooks
nix flake check

# Enter the dev shell
nix develop

# Format Nix files
alejandra .

# Edit sops-encrypted server secrets
sops modules/hosts/foundry/secrets.yaml

# Unlock foundry after a reboot
foundry-unlock
```

Normal server deploys happen through GitHub Actions after changes land on
`main`. The laptop-driven fallback is documented in
[`docs/foundry/operations.md`](docs/foundry/operations.md).

## Repository layout

```text
flake.nix
modules/
  parts.nix
  home/
  darwin/
  hosts/foundry/
  features/
  deploy.nix
hosts/foundry/hardware-configuration.nix
docs/
```

`flake.nix` is intentionally small: it calls `flake-parts.lib.mkFlake` and
auto-loads `modules/` through `import-tree`. Every `.nix` file under
`modules/` must therefore be a flake-parts module. Plain NixOS modules belong
outside that tree unless they are wrapped and exported from a flake-parts
module.

## Documentation

- [Architecture](docs/architecture.md): flake layout, nixpkgs split, module
  conventions, CI/pre-commit shape.
- [New machine bootstrap](docs/bootstrap-new-machine.md): setting up a laptop
  or Linux user environment from this flake.
- [Foundry overview](docs/foundry/overview.md): current server state and
  service map.
- [Foundry operations](docs/foundry/operations.md): routine unlock, deploy,
  verification, and key-rotation tasks.
- [Foundry backups](docs/foundry/backups.md): restic model, restore commands,
  PostgreSQL dumps, and restore drill.
- [Foundry recovery](docs/foundry/recovery.md): rescue mode, reinstall, sops
  re-keying, and bootstrap gotchas.
- [Foundry security](docs/foundry/security.md): public surface, secrets model,
  auth, and deliberate tradeoffs.
- [Optional roadmap](docs/foundry/optional-roadmap.md): nice-to-have future
  work now that the server baseline is finished.
