{inputs, ...}: {
  flake.nixosModules.foundryvtt = {
    pkgs,
    lib,
    ...
  }: {
    imports = [
      inputs.foundryvtt.nixosModules.foundryvtt
    ];

    services.foundryvtt = {
      enable = true;

      # Pin the build that matches the zip we've seeded into /nix/store.
      # `foundryvtt_14` alone auto-resolves to the latest v14 stable entry
      # in reckenrode's versions.json, so a flake.lock bump could silently
      # advance us past 14.359 and fail activation if we haven't downloaded
      # the new zip. Bump this and the seeded zip together, on purpose.
      package =
        (pkgs.callPackage "${inputs.foundryvtt}/pkgs/foundryvtt" {
          buildPackages =
            pkgs.buildPackages
            // {
              buildNpmPackage = pkgs.buildPackages.buildNpmPackage.override {
                nodejs = pkgs.nodejs_24;
              };
            };
        }).overrideAttrs (_: {
          majorVersion = "14";
          releaseType = "stable";
          build = "359";
        });

      hostName = "foundry.simonito.com";

      # Foundry binds on 0.0.0.0 unconditionally; the host firewall only
      # exposes 80/443 (Caddy) and 62222/2222 (SSH), so 30012 is reachable
      # only via the reverse proxy. Keep the public service on the existing
      # internal port so the Caddy vhost does not need to move.
      port = 30012;
      # Start v14 with fresh application data and leave the old v12 tree in
      # place for rollback/reference instead of migrating buggy module state.
      dataDir = "/var/lib/foundryvtt/v14";

      # Tell Foundry the public scheme/port so invite links and A/V ICE
      # candidates resolve against https://foundry.simonito.com:443
      # instead of the internal http://…:30012.
      proxyPort = 443;
      proxySSL = true;

      # Router-level port forwarding is irrelevant on a Hetzner box with
      # a static public IP; disable UPnP chatter.
      upnp = false;

      # Minify core + modules. Cuts cold-page weight for cellular players
      # without hurting debuggability for us (we don't patch the client).
      minifyStaticFiles = true;
    };

    # reckenrode's module restricts outbound traffic to localhost via
    # `IPAddressAllow = "localhost"`, which breaks Foundry's periodic
    # license check against foundryvtt.com and any A/V STUN lookups.
    # Relax it; the rest of the hardening (ProtectSystem=strict, syscall
    # filter, CapabilityBoundingSet, PrivateUsers) still applies.
    systemd.services.foundryvtt.serviceConfig.IPAddressAllow = lib.mkForce "any";
  };
}
