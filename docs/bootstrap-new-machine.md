# New Machine Bootstrap

This file covers laptops and user environments. Server bootstrap and recovery
live under [`docs/foundry/`](foundry/overview.md).

## Primary Mac

Apply the Home Manager profile:

```bash
home-manager switch --flake .#simon-darwin
```

The shell alias is:

```bash
hm-mac
```

If Home Manager is not available yet, bootstrap it through Nix:

```bash
nix run home-manager/master -- switch --flake .#simon-darwin
```

Then log into Atuin:

```bash
atuin login
```

## M4 Mac

Use the separate Home Manager profile:

```bash
nix run home-manager/master -- switch --flake .#simon-m4
atuin login
```

## Linux user environment

On a fresh Linux machine:

```bash
nix --experimental-features 'nix-command flakes' run home-manager/master -- \
  --experimental-features 'nix-command flakes' \
  switch --flake .#simon-linux

atuin login
```

If Nix complains about an existing shell file such as `~/.zshrc`, move the file
aside and re-run the switch. Home Manager owns those files after activation.

## Development shell

Enter the repo shell:

```bash
nix develop
```

The shell installs the pre-commit hooks declared in `modules/pre-commit.nix`.
With direnv enabled, entering the repository should do this automatically.

## Local checks

```bash
alejandra .
nix flake check
```

`nix flake check` runs the same pre-commit hook set used by CI. It is the right
default before pushing anything non-trivial.
