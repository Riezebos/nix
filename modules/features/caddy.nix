{...}: {
  flake.nixosModules.caddy = {...}: let
    commonHeaders = ''
      header {
        # 1 year; includeSubDomains is safe for every subdomain here.
        # `preload` intentionally omitted until the apex is ready for it.
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
      }
    '';

    mkAccessLog = name: ''
      log {
        output file /var/log/caddy/access-${name}.log {
          mode 0640
          roll_size 25MiB
          roll_keep 8
          roll_keep_for 720h
        }
        format json
      }
    '';
  in {
    services.caddy = {
      enable = true;

      # Let's Encrypt contact. Expiry + TOS change warnings land here.
      # Personal mailbox because a laptop/account outage shouldn't mute
      # the only heads-up we get before certs start 4xx'ing.
      email = "simon@datagiant.org";

      virtualHosts."foundry.simonito.com".extraConfig = ''
        encode zstd gzip
        ${mkAccessLog "foundry"}

        reverse_proxy 127.0.0.1:30012

        # Foundry's scene/journal editors render in same-origin iframes,
        # so DENY would break them. SAMEORIGIN is the tightest that keeps
        # the app functional.
        ${commonHeaders}
      '';

      virtualHosts."grafana.simonito.com".extraConfig = ''
        encode zstd gzip
        ${mkAccessLog "grafana"}

        reverse_proxy 127.0.0.1:3000

        ${commonHeaders}
      '';

      virtualHosts."auth.simonito.com".extraConfig = ''
        encode zstd gzip
        ${mkAccessLog "auth"}

        reverse_proxy 127.0.0.1:9000

        ${commonHeaders}

        # Future non-OIDC admin UIs should use Authentik's embedded proxy
        # outpost with Caddy forward_auth instead of growing their own auth:
        #
        # route {
        #   reverse_proxy /outpost.goauthentik.io/* 127.0.0.1:9000
        #   forward_auth 127.0.0.1:9000 {
        #     uri /outpost.goauthentik.io/auth/caddy
        #     copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Entitlements X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost X-Authentik-Meta-Provider X-Authentik-Meta-App X-Authentik-Meta-Version
        #     trusted_proxies private_ranges
        #   }
        #   reverse_proxy 127.0.0.1:<app-port>
        # }
      '';
    };

    # ACME HTTP-01 needs 80 reachable; the proxy needs 443. Added here
    # instead of the host config so the port list stays next to the
    # service that requires it.
    networking.firewall.allowedTCPPorts = [80 443];
  };
}
