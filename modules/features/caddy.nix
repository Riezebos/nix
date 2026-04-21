{...}: {
  flake.nixosModules.caddy = {...}: {
    services.caddy = {
      enable = true;

      # Let's Encrypt contact. Expiry + TOS change warnings land here.
      # Personal mailbox because a laptop/account outage shouldn't mute
      # the only heads-up we get before certs start 4xx'ing.
      email = "simon@datagiant.org";

      virtualHosts."foundry.simonito.com".extraConfig = ''
        encode zstd gzip

        reverse_proxy 127.0.0.1:30012

        header {
          # 1 year; includeSubDomains is safe — simonito.com is only
          # hosting this vhost. `preload` intentionally omitted until
          # the apex is on the HSTS preload list.
          Strict-Transport-Security "max-age=31536000; includeSubDomains"
          # Foundry's scene/journal editors render in same-origin iframes,
          # so DENY would break them. SAMEORIGIN is the tightest that
          # keeps the app functional.
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          Referrer-Policy "strict-origin-when-cross-origin"
          # Strip the Caddy version banner.
          -Server
        }
      '';
    };

    # ACME HTTP-01 needs 80 reachable; the proxy needs 443. Added here
    # instead of the host config so the port list stays next to the
    # service that requires it.
    networking.firewall.allowedTCPPorts = [80 443];
  };
}
