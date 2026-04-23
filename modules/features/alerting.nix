{...}: {
  flake.nixosModules.alerting = {
    config,
    pkgs,
    lib,
    ...
  }: let
    # Healthchecks.io "ping by slug" URL form:
    #   https://hc-ping.com/<project ping key>/<slug>[/start|/fail|/<exit>]
    # One project-wide ping key (sops) + per-check slugs in this file.
    # Enable "Auto-provision checks from /ping/<key>/<slug> requests" under
    # the Healthchecks.io project's settings so new units create their
    # check on first ping — no Healthchecks.io-side fiddling when we add
    # monitored services.
    #
    # The shared helper reads HEALTHCHECKS_PING_KEY from the unit's
    # environment (populated via EnvironmentFile from the sops template
    # below). A failed ping is *never* allowed to fail the host unit — the
    # `|| true` lives in each caller, not here, so the helper itself can
    # use `set -eu` for argument sanity.
    healthchecksPing = pkgs.writeShellScript "healthchecks-ping" ''
      set -eu
      : "''${HEALTHCHECKS_PING_KEY:?HEALTHCHECKS_PING_KEY not set in environment}"
      slug="$1"
      suffix="''${2:-}"
      exec ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 --retry-delay 2 \
        "https://hc-ping.com/$HEALTHCHECKS_PING_KEY/$slug$suffix" >/dev/null
    '';

    healthchecksEnvFile = config.sops.templates."healthchecks-ping.env".path;

    # Long-running services: we only want a fail alert, not a dead-man
    # heartbeat. Systemd auto-restarts the unit; Healthchecks.io fires on
    # the initial failure (before the restart), and resolves naturally
    # the next day if it comes back up. Keys are systemd unit names;
    # values are Healthchecks.io slugs.
    failOnly = {
      foundryvtt = "foundryvtt";
      caddy = "caddy";
      loki = "loki";
      grafana = "grafana";
      victoriametrics = "victoriametrics";
      alloy = "alloy";
    };

    onFailureHook = slug: {
      onFailure = ["healthchecks-fail@${slug}.service"];
    };
  in {
    # Raw ping key in sops. The sops template below wraps it as an
    # EnvironmentFile — systemd can't read a bare secret as KEY=VALUE.
    sops.secrets."healthchecks/pingkey" = {
      owner = "root";
      mode = "0400";
    };

    sops.templates."healthchecks-ping.env" = {
      owner = "root";
      mode = "0400";
      content = ''
        HEALTHCHECKS_PING_KEY=${config.sops.placeholder."healthchecks/pingkey"}
      '';
    };

    # Template unit (`healthchecks-fail@<slug>.service`) plus
    # OnFailure/ExecStartPost wiring for every monitored unit. systemd
    # fills %i in the template with the slug from the instance name.
    #
    # ExecStartPost runs only if ExecStart succeeded (systemd.exec(5)), so
    # a successful restic run is exactly what reaches Healthchecks.io as a
    # heartbeat. Start pings (/start) are deliberately omitted: the
    # Healthchecks.io grace window on a daily cadence already distinguishes
    # "ran but failed" from "never ran", and a start-ping via
    # `backupPrepareCommand` would string-conflict with the prepare logic
    # in restic.nix. Fail + success is sufficient.
    systemd.services =
      {
        "healthchecks-fail@" = {
          description = "Healthchecks.io fail ping for %i";
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = healthchecksEnvFile;
            ExecStart = "${healthchecksPing} %i /fail";
          };
        };

        restic-backups-foundry =
          onFailureHook "daily-backup"
          // {
            serviceConfig = {
              EnvironmentFile = healthchecksEnvFile;
              ExecStartPost = "${healthchecksPing} daily-backup";
            };
          };

        # 15-min journal job. Dead-man window at Healthchecks.io side
        # should be ~1 h with 15 min grace — four pings per hour, one miss
        # is fine, two misses means something is wrong.
        restic-backups-foundry-journal =
          onFailureHook "journal-backup"
          // {
            serviceConfig = {
              EnvironmentFile = healthchecksEnvFile;
              ExecStartPost = "${healthchecksPing} journal-backup";
            };
          };

        # Monthly integrity check. Defined in restic.nix as a plain oneshot;
        # merging serviceConfig here adds the env + post-hook without
        # touching its script.
        restic-check-foundry =
          onFailureHook "restic-check"
          // {
            serviceConfig = {
              EnvironmentFile = healthchecksEnvFile;
              ExecStartPost = "${healthchecksPing} restic-check";
            };
          };
      }
      // lib.mapAttrs (_: onFailureHook) failOnly;
  };
}
