{...}: {
  flake.nixosModules.crowdsec = {
    lib,
    pkgs,
    ...
  }: let
    # The bouncer's first ExecStart connects to the LAPI immediately. CrowdSec
    # is Type=notify but its "ready" signal fires a touch before the HTTP
    # listener is accepting connections, so even ordered after crowdsec.service
    # the bouncer can win the race and exit 1. Block startup until the LAPI
    # port answers so the real ExecStart succeeds on the first try and the
    # nixos-rebuild switch sees a clean activation instead of a flapping unit.
    # No external tools beyond sleep: the bouncer unit runs with an empty PATH
    # in nftables mode, and the TCP probe is a bash /dev/tcp builtin (AF_INET
    # is permitted by the unit's RestrictAddressFamilies).
    waitForLapi = pkgs.writeShellScript "crowdsec-firewall-bouncer-wait-lapi" ''
      for ((i = 0; i < 60; i++)); do
        if (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; then
          exec 3<&- 3>&-
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 1
      done
      echo "crowdsec LAPI on 127.0.0.1:8080 not reachable after 60s" >&2
      exit 1
    '';
  in {
    # The firewall bouncer uses nftables mode. Flip the host firewall backend
    # once here so the allow-list remains declarative.
    networking.nftables.enable = true;

    services.crowdsec = {
      enable = true;
      autoUpdateService = true;

      hub.collections = [
        "crowdsecurity/sshd"
        "crowdsecurity/caddy"
      ];

      settings = {
        general.api.server = {
          enable = true;
          listen_uri = "127.0.0.1:8080";
        };

        lapi.credentialsFile = "/var/lib/crowdsec/local_api_credentials.yaml";
      };

      localConfig.acquisitions = [
        {
          source = "journalctl";
          journalctl_filter = ["_SYSTEMD_UNIT=sshd.service"];
          labels.type = "syslog";
        }
        {
          filenames = ["/var/log/caddy/access-*.log"];
          labels.type = "caddy";
        }
      ];
    };

    services.crowdsec-firewall-bouncer = {
      enable = true;
      registerBouncer.enable = true;
      settings.mode = "nftables";
    };

    # Keep the CrowdSec engine user stable so group-based access to Caddy's
    # on-disk logs is predictable, and work around the current state-dir
    # permission issue seen by other NixOS users. Leave the bouncer units on
    # their upstream defaults so systemd credentials keep working.
    users.users.crowdsec.extraGroups = [
      "systemd-journal"
      "caddy"
    ];

    systemd.services.crowdsec.serviceConfig = {
      DynamicUser = lib.mkForce false;
      StateDirectory = lib.mkForce "crowdsec";
    };

    # Gate the bouncer on the LAPI being reachable (see waitForLapi above).
    # mkAfter appends to upstream's ExecStartPre list (config generation +
    # config test) rather than replacing it, so credential loading and the
    # config check stay intact. Restart=on-failure is kept as a safety net for
    # later LAPI restarts (e.g. crowdsec's own auto-update reloads).
    systemd.services.crowdsec-firewall-bouncer.serviceConfig = {
      ExecStartPre = lib.mkAfter ["${waitForLapi}"];
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
