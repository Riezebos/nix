{inputs, ...}: {
  flake.nixosModules.sterwerkFeature = {config, ...}: let
    domain = "sterwerk.datagiant.org";
    port = 4400;
  in {
    imports = [inputs.sterwerk.nixosModules.sterwerk];

    services.sterwerk = {
      enable = true;
      hostName = domain;
      inherit port;

      # app binds 127.0.0.1 only; caddy is the only client that can speak
      # the identity headers (SterwerkWeb.Auth trusts x-authentik-username).
      environmentFile = config.sops.templates."sterwerk-env".path;
    };

    # The release ships without a bundled release cookie (nixpkgs
    # `removeCookie`) and refuses to boot without SECRET_KEY_BASE, so both
    # ride in one sops template consumed as the unit's EnvironmentFile.
    sops.secrets."sterwerk/secret_key_base" = {
      owner = "root";
      mode = "0400";
    };
    sops.secrets."sterwerk/release_cookie" = {
      owner = "root";
      mode = "0400";
    };
    sops.secrets."sterwerk/deploy_key" = {
      owner = "root";
      mode = "0400";
    };
    sops.templates."sterwerk-env" = {
      owner = "root";
      mode = "0400";
      content = ''
        SECRET_KEY_BASE=${config.sops.placeholder."sterwerk/secret_key_base"}
        RELEASE_COOKIE=${config.sops.placeholder."sterwerk/release_cookie"}
      '';
    };

    # `system.autoUpgrade` evaluates this flake as root and must be able to
    # fetch the private Sterwerk flake input before a new system exists. Keep
    # the read-only repository deploy key in the current system's SOPS
    # secrets, and pin GitHub's published Ed25519 host key rather than using
    # TOFU during an unattended upgrade.
    programs.ssh.knownHosts.github = {
      hostNames = ["github.com"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
    programs.ssh.extraConfig = ''
      Host github.com
        IdentityFile ${config.sops.secrets."sterwerk/deploy_key".path}
        IdentitiesOnly yes
    '';

    services.caddy.virtualHosts.${domain}.extraConfig = let
      # Authentik's embedded proxy outpost. The forward_auth subrequest only
      # answers 2xx for authenticated sessions, after which caddy copies the
      # identity headers onto the proxied request. This is the recipe
      # documented in caddy.nix's auth vhost, spelled out per the
      # deliverable.nix precedent of inlining vhost blocks in features.
      headers = ''
        header {
          Strict-Transport-Security "max-age=31536000; includeSubDomains"
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          Referrer-Policy "strict-origin-when-cross-origin"
          -Server
        }
      '';
      accessLog = ''
        log {
          output file /var/log/caddy/access-sterwerk.log {
            mode 0640
            roll_size 25MiB
            roll_keep 8
            roll_keep_for 720h
          }
          format json
        }
      '';
      authentikOutpost = ''
        route {
          reverse_proxy /outpost.goauthentik.io/* 127.0.0.1:9000
          forward_auth 127.0.0.1:9000 {
            uri /outpost.goauthentik.io/auth/caddy
            copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Entitlements X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost X-Authentik-Meta-Provider X-Authentik-Meta-App X-Authentik-Meta-Version
            trusted_proxies private_ranges
          }
          reverse_proxy 127.0.0.1:${toString port}
        }
      '';
    in ''
      encode zstd gzip
      ${accessLog}
      ${authentikOutpost}
      ${headers}
    '';
  };
}
