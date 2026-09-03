{
  description = "Hopefully this flake will become the flake for all my devices?";

  inputs = {
    # Server (and anything else that wants stability)
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

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

    # reckenrode/nix-foundryvtt packages FoundryVTT for NixOS. The zip itself
    # is not redistributable (personal license) so the derivation uses
    # `requireFile` + pinned hashes from its own versions.json; we seed the
    # zip into the store once via `nix-store --add-fixed` on the build host.
    # Following stable nixpkgs because this input is only consumed by the
    # server build.
    foundryvtt.url = "github:reckenrode/nix-foundryvtt";
    foundryvtt.inputs.nixpkgs.follows = "nixpkgs";

    # agent-sandcastle.nix provides the CLI host and MicroVM sandbox runner.
    # Keep its nixpkgs independent in flake.lock so runners are built from the
    # exact upstream inputs the CLI host was tested with.
    agent-sandcastle.url = "github:Riezebos/agent-sandcastle.nix";

    # sterwerk-app-v2 is the Phoenix candidate tracker (private repo, fetched
    # over SSH). Its nixpkgs stays independent like agent-sandcastle's: the
    # package was built and tested against nixos-25.05's beam tooling, and
    # the release bundles its own erlang anyway.
    sterwerk.url = "git+ssh://git@github.com/Riezebos/sterwerk-app-v2.git";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake
    {inherit inputs;}
    (inputs.import-tree ./modules);
}
