{
  self,
  inputs,
  lib,
  ...
}: let
  # deploy-rs exposes `lib.<system>.activate.nixos` as the profile-path
  # builder and `lib.<system>.deployChecks` as the flake-check generator.
  # Everything we deploy is x86_64-linux, so pin to that here.
  deployPkgs = inputs.deploy-rs.lib.x86_64-linux;
in {
  # deploy-rs does the one thing `nixos-rebuild --target-host switch` does
  # not: "magic rollback" — it activates the new
  # generation, health-checks it, and if the box doesn't respond within a
  # timeout it auto-reverts to the previous generation. Critical when
  # pushing to a remote box with live sessions on it.
  flake.deploy = {
    # Shared across every node we ever add here.
    sshUser = "deploy";
    user = "root";

    # `StrictHostKeyChecking=accept-new` — TOFU on first contact from a
    # fresh CI runner, then fail if the remote key changes. The CI
    # workflow seeds known_hosts explicitly before this runs, so this is
    # mostly a safety net.
    # `Port=62222` — main-system sshd runs here (see
    # `services.openssh.ports` in modules/hosts/foundry/configuration.nix).
    # Applies to both the nix-copy-closure step and deploy-rs's magic-
    # rollback confirm hook, so confirmation over ssh reaches the new
    # sshd after the firewall reload.
    sshOpts = ["-o" "StrictHostKeyChecking=accept-new" "-o" "Port=62222"];

    nodes.foundry = {
      # Placeholder. The real hostname/IP is not in this public repo; the
      # deploy workflow overrides it at runtime with
      #   `deploy --hostname ${{ secrets.FOUNDRY_HOST }} .#foundry`
      # and local invocations from the laptop resolve `foundry` via
      # ~/.ssh/config (see docs/foundry/operations.md).
      hostname = "foundry";

      # FoundryVTT's installer zip is a personal-license file and is seeded
      # into the target host's Nix store, not GitHub Actions. Build the system
      # profile on foundry so deploys can use that local requireFile input.
      remoteBuild = true;

      profiles.system = {
        path = deployPkgs.activate.nixos self.nixosConfigurations.foundry;
      };
    };
  };

  # Wire deploy-rs's schema + activator-path checks into `nix flake check`.
  # Scoped to x86_64-linux because the checks want to build the activator
  # script and that derivation is x86_64-linux-only; other systems (our
  # aarch64-darwin laptop) simply skip them.
  perSystem = {system, ...}: {
    # Same binary revision as `inputs.deploy-rs` / `flake.lock` — so CI can
    # `nix run .#deploy-rs` instead of duplicating a `?rev=` URL.
    apps = {
      deploy-rs = inputs.deploy-rs.apps.${system}.deploy-rs;
    };
    checks = lib.optionalAttrs (system == "x86_64-linux") (deployPkgs.deployChecks self.deploy);
  };
}
