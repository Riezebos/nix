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
    # `ServerAliveInterval`/`ServerAliveCountMax` — a `remoteBuild` deploy
    # holds a long-lived `nix-daemon --stdio` session over this connection.
    # Without keepalives a silently dropped TCP flow leaves both ends
    # blocked in a read forever: the runner waits for build output, the
    # server sleeps in `pipe_read`, and CI hangs until the 6h job limit.
    # Fail the connection after ~2min of no response instead.
    sshOpts = [
      "-o"
      "StrictHostKeyChecking=accept-new"
      "-o"
      "Port=62222"
      "-o"
      "ServerAliveInterval=30"
      "-o"
      "ServerAliveCountMax=4"
    ];

    nodes.foundry = {
      # Placeholder. The real hostname/IP is not in this public repo; the
      # deploy workflow overrides it at runtime with
      #   `deploy --hostname ${{ secrets.FOUNDRY_HOST }} .#foundry`
      # and local invocations from the laptop resolve `foundry` via
      # ~/.ssh/config (see docs/foundry/operations.md).
      hostname = "foundry";

      # Build on the deploying machine, not on foundry.
      #
      # `remoteBuild = true` was hugely expensive: deploy-rs's remote path
      # (deploy-rs src/push.rs) first runs
      #   nix copy -s --to ssh-ng://… --derivation <drv>
      # which ships the *entire derivation closure* — ~6600 .drv files — over
      # a round-trip-bound ssh-ng connection. Measured 32-45 min per deploy,
      # and a warm store on foundry does not help, because the drvs are
      # shipped regardless. Building the same toplevel directly on foundry
      # takes ~2 min, so essentially all of that was protocol overhead.
      #
      # The only reason it was ever on: FoundryVTT's installer zip is a
      # personal-license file that exists solely in foundry's store, so a
      # GitHub runner cannot build the `requireFile` input. The CI workflow
      # now sidesteps that by copying the four already-built foundryvtt
      # outputs *from* foundry before deploying (see the "Seed FoundryVTT"
      # step in .github/workflows/ci.yml), so the runner never needs the zip
      # and never rebuilds the package.
      #
      # With this false, deploy-rs instead copies the built profile with
      # `--substitute-on-destination`, so foundry pulls the bulk of the
      # closure straight from cache.nixos.org at ~88 MB/s and only
      # runner-built paths are pushed over ssh. `--no-check-sigs` is passed
      # by default and `deploy` is in `trusted-users` (wheel), so unsigned
      # runner-built paths are accepted.
      remoteBuild = false;

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
