{...}: {
  flake.nixosModules.crowdsec = {lib, ...}: {
    # Phase 5f calls for the firewall bouncer in nftables mode. Flip the
    # host firewall backend once here so the allow-list remains declarative.
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
  };
}
