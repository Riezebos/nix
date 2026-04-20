{
  description = "Hopefully this flake will become the flake for all my devices?";

  inputs = {
    # Server (and anything else that wants stability)
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    # Vanilla unstable for the odd server package that needs to track upstream
    # faster than 25.11 (e.g. netbird, which releases every few days and where
    # staying half a year behind is the bigger risk). Kept *separate* from
    # nixpkgs-devenv: devenv ships a patched nixpkgs whose `legacyPackages`
    # evaluation triggers an x86_64-linux IFD, which breaks laptop-driven
    # (aarch64-darwin) nixos-rebuild. Plain unstable has no such patch step.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Home Manager package pool (rolling, devenv-patched)
    nixpkgs-devenv.url = "github:cachix/devenv-nixpkgs/rolling";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-devenv";

    darwin.url = "github:LnL7/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs-devenv";

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";

    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake
    {inherit inputs;}
    (inputs.import-tree ./modules);
}
