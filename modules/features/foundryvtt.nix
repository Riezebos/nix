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
      # `foundryvtt_12` alone auto-resolves to the latest v12 stable entry
      # in reckenrode's versions.json, so a flake.lock bump could silently
      # advance us to 12.344 and fail activation if we haven't downloaded
      # the new zip. Bump this and the seeded zip together, on purpose.
      package = inputs.foundryvtt.packages.${pkgs.stdenv.hostPlatform.system}.foundryvtt_12.overrideAttrs (_: {
        build = "343";
      });

      hostName = "foundry.simonito.com";

      # Foundry binds on 0.0.0.0 unconditionally; the host firewall only
      # exposes 80/443 (Caddy) and 22/2222 (SSH), so 30012 is reachable
      # only via the reverse proxy. Port choice: server_plan.md Phase 4
      # uses 30012 to leave room for parallel versions (v13 → 30013).
      port = 30012;
      dataDir = "/var/lib/foundryvtt/v12";

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
