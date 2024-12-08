# Nix/Home Manager flake configuration

This repository contains my personal Nix/Home Manager configuration. I currently use Nix mainly in Home Manager and am very happy with it.

Main features:

- Each machine has the same command line tools with the same configuration (zsh, starship, git, ...)
- Shared command history between multiple machines thanks to atuin

I tried using nix-darwin and NixOS, but at the moment they don't bring much value to me. I work with Python a lot, in various team structures, and for now I want to keep using regular virtual environments for my Python projects, which seems like a hassle in NixOS. Thanks to nix-darwin I can now do sudo using Touch ID on my Macbook, but I don't use it for much else.

## Very basic steps to set this up yourself

- Install Nix: https://nixos.org/download/
- Create a new folder and initialiase home-manager: `nix --experimental-features 'nix-command flakes' run home-manager/master -- init --switch`
- Add your configuration (similar to flake.nix and shared/home.nix from this repository)
- Enable your configuration: `home-manager switch --flake .#<config-name>` (in my case config-name is either simon-darwin or simon-linux)
- You will probably get some errors that either tell you what to do or you can solve them by googling (e.g. needing to run the command with  `--experimental-features 'nix-command flakes'` the first time or that you need to move `~/.zshrc` because it will now be managed by home-manager)

## Links that helped me

- [Setting up your dotfiles with home-manager as a flake · Chris Portela](https://www.chrisportela.com/posts/home-manager-flake/)
- [home-manager](https://nix-community.github.io/home-manager/)
- [Flakes - NixOS Wiki](https://nixos.wiki/wiki/Flakes)
- [GitHub - dminca/nix-config: My Nix configuration for setting up aarch64-darwin & x86\_64-darwin workstations](https://github.com/dminca/nix-config)
- [Code search results · GitHub](https://github.com/search?q=path%3Ahome.nix&type=code)