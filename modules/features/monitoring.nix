{...}: {
  flake.nixosModules.monitoring = {
    config,
    pkgs,
    lib,
    ...
  }: let
    # Every service binds on 127.0.0.1 exclusively. Remote access is via
    # `ssh -L` until Phase 4's Authentik + Caddy forward_auth lands — at that
    # point Grafana will get a `grafana.foundry.simonito.com` vhost behind
    # Authentik. Exposing Grafana or VictoriaMetrics publicly without an auth
    # proxy would be a standing-open admin surface; not worth it for one user.
    bindHost = "127.0.0.1";
    vmPort = 8428;
    lokiPort = 3100;
    nodeExporterPort = 9100;
    grafanaPort = 3000;
  in {
    # ---------------- Metrics store ----------------
    # VictoriaMetrics speaks the Prometheus remote_write + query APIs, so
    # Grafana treats it as a Prometheus datasource and off-the-shelf
    # dashboards (e.g. the node-exporter full dashboard, Grafana.com ID 1860)
    # work unchanged. No separate Prometheus process: Alloy is the single
    # scrape agent and remote-writes into VM directly.
    services.victoriametrics = {
      enable = true;
      listenAddress = "${bindHost}:${toString vmPort}";
      # 12 months of metrics. At ~15s scrape interval against a single host,
      # on-disk cost is well under 1 GB/yr; bumping this is cheap. Suffix-less
      # integers are interpreted as months (see module docs).
      retentionPeriod = "12";
    };

    # ---------------- Host exporter ----------------
    # Provides CPU, memory, disk, filesystem, network, and mdadm RAID stats.
    # mdadm is enabled explicitly because the server runs mdraid RAID1 across
    # both NVMes; systemd is on for per-unit CPU/memory accounting, which
    # pairs with the journal logs in Loki for service-level drill-downs.
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = bindHost;
      port = nodeExporterPort;
      enabledCollectors = ["systemd" "mdadm" "processes"];
    };

    # ---------------- Log store ----------------
    # Single-node Loki with the tsdb schema (the boltdb-shipper schema is
    # deprecated upstream). Storage is plain filesystem under /var/lib/loki
    # — covered by the daily restic snapshot via Phase 5c.
    services.loki = {
      enable = true;
      configuration = {
        auth_enabled = false;

        server = {
          http_listen_address = bindHost;
          http_listen_port = lokiPort;
          # Disable the gRPC listener — we have a single process, no
          # inter-component traffic. Binding to 0 lets the kernel pick a
          # free port for the internal ring gossip that Loki still wants.
          grpc_listen_address = bindHost;
          grpc_listen_port = 0;
          log_level = "warn";
        };

        common = {
          # Top-level `common.instance_addr` is the documented way to
          # pin every component's advertise address at once — memberlist,
          # ingester, compactor, frontend, scheduler all inherit it.
          # Setting `common.ring.instance_addr` on its own (which was
          # the obvious-looking option) covers only the default ring;
          # per-module rings still fall back to probing eth0/en0/lo.
          # See JayRovacsek/nix-config modules/loki/default.nix for the
          # canonical minimal-working single-binary pattern.
          instance_addr = bindHost;
          path_prefix = "/var/lib/loki";
          replication_factor = 1;
          ring = {
            instance_addr = bindHost;
            kvstore.store = "inmemory";
          };
        };

        # Loki still initializes the memberlist-kv module even when every
        # ring is configured as `inmemory`. Two separate autodiscovery
        # paths fail on foundry (primary NIC is `eno1`, not `eth0`/`en0`):
        #
        # 1. `bind_addr` — what memberlist binds on. With only localhost
        #    configured, memberlist binds on 127.0.0.1 cleanly.
        # 2. `advertise_addr` — the address memberlist advertises to
        #    peers. If unset, memberlist enumerates the bind interfaces
        #    and picks the first non-loopback unicast address; loopback
        #    alone is rejected as "no useable address found" and the
        #    whole module init fails. Pin it to localhost too — there
        #    are no peers to advertise to.
        memberlist = {
          bind_addr = [bindHost];
          advertise_addr = bindHost;
        };

        # Same "probe eth0/en0/lo, reject if only lo is populated" pattern
        # that broke memberlist also breaks the query-frontend module.
        # In single-binary mode there's no external frontend to reach,
        # but Loki still initializes the module and refuses to start if
        # it can't resolve an advertise address. Pin it explicitly.
        frontend.address = bindHost;

        schema_config.configs = [
          {
            # Any date in the past — with a single schema entry this just
            # marks "use tsdb from the start of time". If we ever migrate to
            # a newer schema, add a second entry with `from = <cutover>`.
            from = "2025-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];

        storage_config = {
          tsdb_shipper = {
            active_index_directory = "/var/lib/loki/tsdb-index";
            cache_location = "/var/lib/loki/tsdb-cache";
          };
          filesystem.directory = "/var/lib/loki/chunks";
        };

        # Retention is enforced by the compactor, which also handles
        # delete_requests. Retention is a flat 30d — crash forensics are
        # served by the 15-min journal restic job (Phase 5c), not by a
        # longer Loki window.
        compactor = {
          working_directory = "/var/lib/loki/compactor";
          retention_enabled = true;
          delete_request_store = "filesystem";
        };

        limits_config = {
          retention_period = "720h";
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
          allow_structured_metadata = true;
        };

        # Don't phone home with anonymous usage stats.
        analytics.reporting_enabled = false;
      };
    };

    # ---------------- Collection agent ----------------
    # Grafana Alloy is the OTEL Collector distribution from Grafana; in this
    # stack it does two jobs: (1) Prometheus-style scraping of node_exporter
    # and remote-writing into VictoriaMetrics; (2) reading the systemd
    # journal and pushing to Loki. A single agent beats running Promtail +
    # a separate scraper, and leaves the door open for OTEL app traces
    # without introducing a new service.
    #
    # Config lives under /etc/alloy (not a Nix-store path) so SIGHUP reload
    # works during `nixos-rebuild switch` — see the alloy NixOS module.
    services.alloy.enable = true;

    environment.etc."alloy/config.alloy".text = ''
      // ---- Metrics: scrape node_exporter, remote_write to VictoriaMetrics.
      prometheus.scrape "node" {
        targets = [{
          __address__ = "${bindHost}:${toString nodeExporterPort}",
          instance    = "foundry",
        }]
        forward_to      = [prometheus.remote_write.vm.receiver]
        scrape_interval = "15s"
      }

      prometheus.remote_write "vm" {
        endpoint {
          url = "http://${bindHost}:${toString vmPort}/api/v1/write"
        }
      }

      // ---- Logs: systemd journal -> Loki.
      loki.source.journal "journal" {
        forward_to = [loki.write.local.receiver]
        labels = {
          job  = "systemd-journal",
          host = "foundry",
        }
        // `max_age` caps how far back Alloy reads on startup so a long
        // outage doesn't replay weeks of logs into Loki at once.
        max_age = "12h"
        // `relabel_rules` is left empty — the unit name lands as
        // `__journal__systemd_unit` which Loki exposes as a label
        // automatically via the relabel defaults in loki.source.journal.
      }

      loki.write "local" {
        endpoint {
          url = "http://${bindHost}:${toString lokiPort}/loki/api/v1/push"
        }
      }
    '';

    # ---------------- Dashboard ----------------
    # Grafana sits on localhost only; reach it via
    #   ssh -L 3000:127.0.0.1:3000 foundry
    # until the Authentik forward_auth story from Phase 4 lands, at which
    # point the Caddy vhost comment in modules/features/caddy.nix will
    # grow a second block for grafana.foundry.simonito.com.
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = bindHost;
          http_port = grafanaPort;
          # Once a public vhost exists, set `domain` and `root_url` so
          # invite/reset links are correct. Leaving them at defaults is
          # fine for the SSH-tunnel access pattern.
        };
        analytics.reporting_enabled = false;
        # No public sign-up; admin user is bootstrapped by the module
        # (default login admin / admin, forced to reset on first login).
        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "VictoriaMetrics";
            type = "prometheus";
            access = "proxy";
            url = "http://${bindHost}:${toString vmPort}";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://${bindHost}:${toString lokiPort}";
          }
        ];
      };
    };
  };
}
