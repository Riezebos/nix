{...}: {
  flake.nixosModules.alerting = {
    config,
    pkgs,
    lib,
    ...
  }: let
    # Healthchecks.io "ping by slug" URL form:
    #   https://hc-ping.com/<project ping key>/<slug>[/start|/fail|/<exit>]?create=1
    # One project-wide ping key (sops) + per-check slugs in this file.
    # `?create=1` asks Healthchecks.io to auto-create the check on the
    # first ping (returning 201), or ping-and-return-200 if it already
    # exists. This is a per-request flag — there is no project-level
    # toggle for auto-provisioning — so every URL this helper emits
    # carries it unconditionally.
    # Docs: https://healthchecks.io/docs/auto_provisioning/
    #
    # The shared helper reads HEALTHCHECKS_PING_KEY from the unit's
    # environment (populated via EnvironmentFile from the sops template
    # below).
    #
    # This script **always exits 0**. A ping is a best-effort side
    # channel: a missing env var, a network blip, or a 404 from
    # Healthchecks.io (e.g. auto-provision off) must never propagate into
    # the caller. If the helper here failed, an `ExecStartPost=` would
    # flip its parent restic unit to "failed", and — worse — the
    # `healthchecks-fail@` template unit itself would end up "failed"
    # and cause deploy-rs to abort the whole activation and roll back
    # (seen in CI run 24833575949 against `loki` already being down).
    # The curl output still lands in the journal, so a broken ping is
    # visible without taking services or deploys down with it.
    healthchecksPing = pkgs.writeShellScript "healthchecks-ping" ''
      slug="''${1:-}"
      suffix="''${2:-}"
      if [ -z "$slug" ]; then
        echo "healthchecks-ping: slug argument missing; skipping" >&2
        exit 0
      fi
      if [ -z "''${HEALTHCHECKS_PING_KEY:-}" ]; then
        echo "healthchecks-ping: HEALTHCHECKS_PING_KEY not set; skipping ping for $slug$suffix" >&2
        exit 0
      fi
      if ! ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 --retry-delay 2 \
         "https://hc-ping.com/$HEALTHCHECKS_PING_KEY/$slug$suffix?create=1" >/dev/null; then
        echo "healthchecks-ping: ping for $slug$suffix failed (see curl output above); continuing" >&2
      fi
      exit 0
    '';

    healthchecksFailAfter = pkgs.writeShellScript "healthchecks-fail-after" ''
      slug="''${1:-}"
      threshold="''${2:-}"
      if [ -z "$slug" ]; then
        echo "healthchecks-fail-after: slug argument missing; skipping" >&2
        exit 0
      fi
      case "$threshold" in
        ""|*[!0-9]*|0)
          echo "healthchecks-fail-after: invalid threshold '$threshold' for $slug; skipping" >&2
          exit 0
          ;;
      esac

      state_dir=/run/healthchecks-fail-after
      state_file="$state_dir/$slug.count"
      mkdir -p "$state_dir"

      count=0
      if [ -r "$state_file" ]; then
        IFS= read -r count < "$state_file" || count=0
      fi
      case "$count" in
        ""|*[!0-9]*) count=0 ;;
      esac

      count=$((count + 1))
      printf '%s\n' "$count" > "$state_file"

      if [ "$count" -lt "$threshold" ]; then
        echo "healthchecks-fail-after: $slug failure $count/$threshold; not pinging /fail yet" >&2
        exit 0
      fi

      echo "healthchecks-fail-after: $slug failure $count/$threshold; pinging /fail" >&2
      exec ${healthchecksPing} "$slug" /fail
    '';

    healthchecksResetAndPing = pkgs.writeShellScript "healthchecks-reset-and-ping" ''
      slug="''${1:-}"
      if [ -n "$slug" ]; then
        rm -f "/run/healthchecks-fail-after/$slug.count"
      fi
      exec ${healthchecksPing} "$@"
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
      "authentik-server" = "authentik-server";
      "authentik-worker" = "authentik-worker";
      loki = "loki";
      grafana = "grafana";
      victoriametrics = "victoriametrics";
      alloy = "alloy";
      pgbouncer = "pgbouncer";
    };

    onFailureHook = slug: {
      onFailure = ["healthchecks-fail@${slug}.service"];
    };

    onSecondFailureHook = slug: {
      onFailure = ["healthchecks-fail-after-2@${slug}.service"];
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

        "healthchecks-fail-after-2@" = {
          description = "Healthchecks.io fail ping for %i after two consecutive failures";
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = healthchecksEnvFile;
            ExecStart = "${healthchecksFailAfter} %i 2";
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
          onSecondFailureHook "journal-backup"
          // {
            serviceConfig = {
              EnvironmentFile = healthchecksEnvFile;
              ExecStartPost = "${healthchecksResetAndPing} journal-backup";
            };
          };

        restic-backups-foundry-postgresql =
          onFailureHook "postgresql-backup"
          // {
            serviceConfig = {
              EnvironmentFile = healthchecksEnvFile;
              ExecStartPost = "${healthchecksPing} postgresql-backup";
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
