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

      # Build on foundry, not on the deploying machine.
      #
      # This is expensive and we have measured the alternative. deploy-rs's
      # remote path first ships the entire derivation closure (~6600 .drv
      # files) over a round-trip-bound ssh-ng connection, which costs 32-45
      # min per deploy and is immune to a warm store on foundry.
      #
      # `remoteBuild = false` was tried on 2026-08-04 and is worse. The
      # runner could not substitute enough of the system closure, and two
      # attempts of 45 and 30 min expired without finishing. The retired
      # launcher and curated sandbox store made that measurement especially
      # expensive, so it should be re-measured before using it as a current
      # performance comparison.
      #
      # Foundry has most inputs warm from previous deploys, which is why its
      # own `nixos-rebuild` finishes in minutes. Keep the build there.
      # (See .github/workflows/diagnose-deploy-build.yml to re-measure.)
      #
      # A secondary reason it must stay true: FoundryVTT's installer zip is
      # a personal-license file that exists only in foundry's store, so the
      # `requireFile` input is unbuildable anywhere else.
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
