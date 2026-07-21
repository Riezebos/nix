{...}: {
  flake.nixosModules.crowdsec = {
    config,
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

    # Same rendering the nixpkgs module uses internally for the config file it
    # passes to `crowdsec -c`. Rebuilt here (identical name + inputs, so the
    # same store path) because the module keeps its copy in a `let` and the
    # crowdsec-firewall-bouncer-register oneshot calls the *unwrapped* cscli,
    # which only looks at /etc/crowdsec/config.yaml. Without this link the
    # register unit fails on every activation.
    settingsFormat = pkgs.formats.yaml {};
    crowdsecConfigFile =
      settingsFormat.generate "crowdsec.yaml"
      config.services.crowdsec.settings.general;
  in {
    # The firewall bouncer uses nftables mode. Flip the host firewall backend
    # once here so the allow-list remains declarative.
    networking.nftables.enable = true;

    services.crowdsec = {
      enable = true;

      # No autoUpdateService: `cscli hub update` already runs on every service
      # start, and letting a nightly timer chase the hub's master branch is
      # what broke us on 2026-05-31 — hub content drifted ahead of the pinned
      # binary (a scenario started using the LookupFile expr helper that
      # crowdsec < 1.7.5 doesn't have) and the agent crash-looped for seven
      # weeks. The unit also never worked here: it runs with DynamicUser=true
      # while our state dir is owned by the static crowdsec user.

      hub = {
        collections = [
          "crowdsecurity/sshd"
          "crowdsecurity/caddy"
        ];

        # Fetch hub content from the release branch that matches the pinned
        # binary instead of the default `master`, so scenarios can never
        # require expr helpers the binary doesn't ship. Tracks version bumps
        # automatically. Upstream cuts the vX.Y.Z branch once that release is
        # no longer the newest, which is always true for a stable-nixpkgs pin;
        # if this ever 404s (pinned version is the latest release), crowdsec
        # fails to start loudly at deploy time — fall back to "master" then.
        branch = "v${config.services.crowdsec.package.version}";
      };

      settings = {
        general.api.server = {
          enable = true;
          listen_uri = "127.0.0.1:8080";
        };

        lapi.credentialsFile = "/var/lib/crowdsec/local_api_credentials.yaml";
      };

      localConfig = {
        acquisitions = [
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

        # The module renders exactly this list as the LAPI's profiles file, and
        # an empty list means alerts never become ban decisions — detection
        # without remediation. This is upstream's stock default_ip_remediation
        # profile.
        profiles = [
          {
            name = "default_ip_remediation";
            filters = [''Alert.Remediation == true && Alert.GetScope() == "Ip"''];
            decisions = [
              {
                type = "ban";
                duration = "4h";
              }
            ];
            on_success = "break";
          }
        ];
      };
    };

    services.crowdsec-firewall-bouncer = {
      enable = true;
      registerBouncer.enable = true;
      settings.mode = "nftables";
    };

    # See crowdsecConfigFile above.
    environment.etc."crowdsec/config.yaml".source = crowdsecConfigFile;

    # Keep the CrowdSec engine user stable so group-based access to Caddy's
    # on-disk logs is predictable, and work around the current state-dir
    # permission issue seen by other NixOS users. Leave the bouncer units on
    # their upstream defaults so systemd credentials keep working.
    users.users.crowdsec.extraGroups = [
      "systemd-journal"
      "caddy"
    ];

    systemd.services.crowdsec = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        StateDirectory = lib.mkForce "crowdsec";
      };

      # Restart=always with no start limit means a persistently failing start
      # (fatal config error, unreachable hub CDN) keeps the unit in
      # "activating (auto-restart)" forever: it never reaches `failed`, so
      # `systemctl --failed` and the healthchecks OnFailure hook both stay
      # silent — that is how the 2026-05-31 crash loop went unnoticed for
      # seven weeks. With RestartSec=60 this gives ~10 minutes of retries
      # (enough to ride out DNS/network coming up at boot), then lands in
      # `failed` where the alert fires.
      startLimitIntervalSec = 3600;
      startLimitBurst = 10;
    };

    # Gate the bouncer on the LAPI being reachable (see waitForLapi above).
    # mkAfter appends to upstream's ExecStartPre list (config generation +
    # config test) rather than replacing it, so credential loading and the
    # config check stay intact. Restart=on-failure is kept as a safety net for
    # later LAPI restarts (e.g. crowdsec's own auto-update reloads).
    systemd.services.crowdsec-firewall-bouncer = {
      serviceConfig = {
        ExecStartPre = lib.mkAfter ["${waitForLapi}"];
        Restart = "on-failure";
        RestartSec = "5s";
      };

      # Bound the retry. `Restart=on-failure` around a 60s blocking
      # ExecStartPre means a genuinely-down LAPI (e.g. crowdsec itself
      # crash-looping) makes `systemctl start` never return, which wedges
      # `switch-to-configuration` and therefore the whole deploy. With a
      # start limit the unit gives up and lands in `failed`, so activation
      # reports a broken unit and moves on instead of hanging.
      startLimitIntervalSec = 600;
      startLimitBurst = 5;
    };
  };
}
