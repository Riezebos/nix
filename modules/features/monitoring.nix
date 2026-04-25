{...}: {
  flake.nixosModules.monitoring = {
    config,
    pkgs,
    lib,
    ...
  }: let
    # Loki and VictoriaMetrics stay loopback-only; Grafana is the public,
    # authenticated front door and proxies both datasources
    # server-side. This keeps the raw stores off the internet entirely.
    bindHost = "127.0.0.1";
    vmPort = 8428;
    lokiPort = 3100;
    nodeExporterPort = 9100;
    processExporterPort = 9256;
    grafanaPort = 3000;
    grafanaDbPath = "/var/lib/grafana/data/grafana.db";

    prometheusDatasource = {
      type = "prometheus";
      uid = "victoriametrics";
    };
    lokiDatasource = {
      type = "loki";
      uid = "loki";
    };

    dashboardFile = name: dashboard:
      pkgs.writeText "${name}.json" (builtins.toJSON dashboard);
    dashboardDir = pkgs.linkFarm "grafana-dashboards" [
      {
        name = "foundry-system-overview.json";
        path = dashboardFile "foundry-system-overview" systemOverviewDashboard;
      }
      {
        name = "foundry-services-and-logs.json";
        path = dashboardFile "foundry-services-and-logs" servicesAndLogsDashboard;
      }
      {
        name = "foundry-edge-and-backups.json";
        path = dashboardFile "foundry-edge-and-backups" edgeAndBackupsDashboard;
      }
    ];

    commonDashboard = title: uid: panels: {
      inherit panels title uid;
      annotations.list = [
        {
          builtIn = 1;
          datasource = {
            type = "grafana";
            uid = "-- Grafana --";
          };
          enable = true;
          hide = true;
          iconColor = "rgba(0, 211, 255, 1)";
          name = "Annotations & Alerts";
          type = "dashboard";
        }
      ];
      editable = true;
      fiscalYearStartMonth = 0;
      graphTooltip = 1;
      liveNow = false;
      refresh = "30s";
      schemaVersion = 39;
      tags = ["foundry" "nixos"];
      templating.list = [];
      time = {
        from = "now-6h";
        to = "now";
      };
      timezone = "browser";
      version = 1;
      weekStart = "";
    };

    statPanel = id: title: gridPos: expr: unit: {
      inherit gridPos id title;
      datasource = prometheusDatasource;
      fieldConfig.defaults = {
        inherit unit;
        color.mode = "thresholds";
        thresholds = {
          mode = "absolute";
          steps = [
            {
              color = "green";
              value = null;
            }
          ];
        };
      };
      fieldConfig.overrides = [];
      options = {
        colorMode = "value";
        graphMode = "area";
        justifyMode = "auto";
        orientation = "auto";
        reduceOptions = {
          calcs = ["lastNotNull"];
          fields = "";
          values = false;
        };
        textMode = "auto";
        wideLayout = true;
      };
      targets = [
        {
          inherit expr;
          instant = true;
          refId = "A";
        }
      ];
      type = "stat";
    };

    timeseriesPanelWithDatasource = datasource: id: title: gridPos: targets: unit: {
      inherit datasource gridPos id targets title;
      fieldConfig.defaults = {
        inherit unit;
        color.mode = "palette-classic";
        custom = {
          axisCenteredZero = false;
          axisColorMode = "text";
          axisLabel = "";
          axisPlacement = "auto";
          barAlignment = 0;
          drawStyle = "line";
          fillOpacity = 12;
          gradientMode = "none";
          hideFrom = {
            legend = false;
            tooltip = false;
            viz = false;
          };
          insertNulls = false;
          lineInterpolation = "linear";
          lineWidth = 1;
          pointSize = 4;
          scaleDistribution.type = "linear";
          showPoints = "never";
          spanNulls = false;
          stacking.mode = "none";
          thresholdsStyle.mode = "off";
        };
        thresholds = {
          mode = "absolute";
          steps = [
            {
              color = "green";
              value = null;
            }
          ];
        };
      };
      fieldConfig.overrides = [];
      options = {
        legend = {
          calcs = ["lastNotNull"];
          displayMode = "list";
          placement = "bottom";
          showLegend = true;
        };
        tooltip = {
          mode = "multi";
          sort = "none";
        };
      };
      type = "timeseries";
    };
    timeseriesPanel = timeseriesPanelWithDatasource prometheusDatasource;
    lokiTimeseriesPanel = timeseriesPanelWithDatasource lokiDatasource;

    logsPanel = id: title: gridPos: expr: {
      inherit gridPos id title;
      datasource = lokiDatasource;
      options = {
        dedupStrategy = "none";
        enableLogDetails = true;
        prettifyLogMessage = false;
        showCommonLabels = false;
        showLabels = false;
        showTime = true;
        sortOrder = "Descending";
        wrapLogMessage = true;
      };
      targets = [
        {
          inherit expr;
          queryType = "range";
          refId = "A";
        }
      ];
      type = "logs";
    };

    serviceProcesses = [
      {
        name = "foundryvtt";
        cmdline = [".*(FoundryVTT|foundryvtt|resources/app/main\\.js).*"];
      }
      {
        name = "caddy";
        cmdline = [".*/caddy( |$).*"];
      }
      {
        name = "grafana";
        cmdline = [".*(grafana|grafana-server).*"];
      }
      {
        name = "authentik-server";
        cmdline = [".*(/ak|authentik).*server.*"];
      }
      {
        name = "authentik-worker";
        cmdline = [".*(/ak|authentik).*worker.*"];
      }
      {
        name = "loki";
        cmdline = [".*/loki( |$).*"];
      }
      {
        name = "victoriametrics";
        cmdline = [".*(victoria-metrics|victoriametrics).*"];
      }
      {
        name = "alloy";
        cmdline = [".*/alloy( |$).*"];
      }
      {
        name = "postgresql";
        cmdline = [".*(postgres|postgresql).*"];
      }
      {
        name = "redis-authentik";
        cmdline = [".*redis-server.*16379.*"];
      }
      {
        name = "node-exporter";
        cmdline = [".*node_exporter.*"];
      }
      {
        name = "process-exporter";
        cmdline = [".*process-exporter.*"];
      }
    ];
    serviceUnits = "foundryvtt.service|caddy.service|grafana.service|authentik-server.service|authentik-worker.service|loki.service|victoriametrics.service|alloy.service|postgresql.service|redis-authentik.service";
    serviceProcessRegex = lib.concatStringsSep "|" (map (service: service.name) serviceProcesses);
    backupTimers = "restic-backups-foundry.timer|restic-backups-foundry-journal.timer|restic-backups-foundry-postgresql.timer|restic-check-foundry.timer";

    systemOverviewDashboard = commonDashboard "Foundry / System Overview" "foundry-system-overview" [
      (statPanel 1 "Node exporter" {
          h = 4;
          w = 6;
          x = 0;
          y = 0;
        }
        "up{instance=\"foundry\"}"
        "none")
      (statPanel 2 "CPU busy" {
          h = 4;
          w = 6;
          x = 6;
          y = 0;
        }
        "100 * (1 - avg(rate(node_cpu_seconds_total{instance=\"foundry\",mode=\"idle\"}[$__rate_interval])))"
        "percent")
      (statPanel 3 "Memory used" {
          h = 4;
          w = 6;
          x = 12;
          y = 0;
        }
        "100 * (1 - node_memory_MemAvailable_bytes{instance=\"foundry\"} / node_memory_MemTotal_bytes{instance=\"foundry\"})"
        "percent")
      (statPanel 4 "Root filesystem used" {
          h = 4;
          w = 6;
          x = 18;
          y = 0;
        }
        "100 * (1 - node_filesystem_avail_bytes{instance=\"foundry\",mountpoint=\"/\",fstype!~\"tmpfs|ramfs|overlay\"} / node_filesystem_size_bytes{instance=\"foundry\",mountpoint=\"/\",fstype!~\"tmpfs|ramfs|overlay\"})"
        "percent")
      (timeseriesPanel 5 "CPU busy" {
          h = 8;
          w = 12;
          x = 0;
          y = 4;
        } [
          {
            expr = "100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{instance=\"foundry\",mode=\"idle\"}[$__rate_interval])))";
            legendFormat = "busy";
            refId = "A";
          }
        ]
        "percent")
      (timeseriesPanel 6 "Memory" {
          h = 8;
          w = 12;
          x = 12;
          y = 4;
        } [
          {
            expr = "node_memory_MemTotal_bytes{instance=\"foundry\"} - node_memory_MemAvailable_bytes{instance=\"foundry\"}";
            legendFormat = "used";
            refId = "A";
          }
          {
            expr = "node_memory_MemAvailable_bytes{instance=\"foundry\"}";
            legendFormat = "available";
            refId = "B";
          }
        ]
        "bytes")
      (timeseriesPanel 7 "Filesystem free" {
          h = 8;
          w = 12;
          x = 0;
          y = 12;
        } [
          {
            expr = "node_filesystem_avail_bytes{instance=\"foundry\",fstype!~\"tmpfs|ramfs|overlay\",mountpoint=~\"/|/boot.*\"}";
            legendFormat = "{{mountpoint}}";
            refId = "A";
          }
        ]
        "bytes")
      (timeseriesPanel 8 "Network throughput" {
          h = 8;
          w = 12;
          x = 12;
          y = 12;
        } [
          {
            expr = "sum by (device) (rate(node_network_receive_bytes_total{instance=\"foundry\",device!~\"lo|veth.*|docker.*\"}[$__rate_interval]))";
            legendFormat = "{{device}} rx";
            refId = "A";
          }
          {
            expr = "-sum by (device) (rate(node_network_transmit_bytes_total{instance=\"foundry\",device!~\"lo|veth.*|docker.*\"}[$__rate_interval]))";
            legendFormat = "{{device}} tx";
            refId = "B";
          }
        ]
        "Bps")
    ];

    servicesAndLogsDashboard = commonDashboard "Foundry / Services & Logs" "foundry-services-and-logs" [
      (statPanel 1 "Active core services" {
          h = 4;
          w = 8;
          x = 0;
          y = 0;
        }
        "sum(node_systemd_unit_state{instance=\"foundry\",name=~\"${serviceUnits}\",state=\"active\"})"
        "none")
      (statPanel 2 "Failed units" {
          h = 4;
          w = 8;
          x = 8;
          y = 0;
        }
        "sum(node_systemd_unit_state{instance=\"foundry\",state=\"failed\"})"
        "none")
      (statPanel 3 "Running processes" {
          h = 4;
          w = 8;
          x = 16;
          y = 0;
        }
        "node_procs_running{instance=\"foundry\"}"
        "none")
      (timeseriesPanel 4 "Service active state" {
          h = 9;
          w = 24;
          x = 0;
          y = 4;
        } [
          {
            expr = "node_systemd_unit_state{instance=\"foundry\",name=~\"${serviceUnits}\",state=\"active\"}";
            legendFormat = "{{name}}";
            refId = "A";
          }
        ]
        "none")
      (lokiTimeseriesPanel 5 "Journal volume" {
          h = 7;
          w = 12;
          x = 0;
          y = 37;
        } [
          {
            datasource = lokiDatasource;
            expr = "sum(count_over_time({host=\"foundry\", job=\"systemd-journal\"}[$__interval]))";
            legendFormat = "journal lines";
            refId = "A";
          }
        ]
        "logs")
      (lokiTimeseriesPanel 6 "Error-ish journal lines" {
          h = 7;
          w = 12;
          x = 12;
          y = 37;
        } [
          {
            datasource = lokiDatasource;
            expr = "sum(count_over_time({host=\"foundry\", job=\"systemd-journal\"} |~ \"(?i)(error|failed|panic|traceback|exception)\" [$__interval]))";
            legendFormat = "matches";
            refId = "A";
          }
        ]
        "logs")
      (logsPanel 7 "Recent service errors" {
          h = 10;
          w = 12;
          x = 0;
          y = 44;
        }
        "{host=\"foundry\", job=\"systemd-journal\"} |~ \"(?i)(error|failed|panic|traceback|exception)\"")
      (logsPanel 8 "Authentik and Grafana" {
          h = 10;
          w = 12;
          x = 12;
          y = 44;
        }
        "{host=\"foundry\", job=\"systemd-journal\"} |~ \"authentik|grafana\"")
      (timeseriesPanel 9 "Service CPU" {
          h = 8;
          w = 12;
          x = 0;
          y = 13;
        } [
          {
            expr = "rate(namedprocess_namegroup_cpu_seconds_total{instance=\"foundry\",groupname=~\"${serviceProcessRegex}\"}[$__rate_interval])";
            legendFormat = "{{groupname}}";
            refId = "A";
          }
        ]
        "cores")
      (timeseriesPanel 10 "Service memory RSS" {
          h = 8;
          w = 12;
          x = 12;
          y = 13;
        } [
          {
            expr = "namedprocess_namegroup_memory_bytes{instance=\"foundry\",groupname=~\"${serviceProcessRegex}\",memtype=\"resident\"}";
            legendFormat = "{{groupname}}";
            refId = "A";
          }
        ]
        "bytes")
      (timeseriesPanel 11 "Service processes" {
          h = 8;
          w = 12;
          x = 0;
          y = 21;
        } [
          {
            expr = "namedprocess_namegroup_num_procs{instance=\"foundry\",groupname=~\"${serviceProcessRegex}\"}";
            legendFormat = "{{groupname}}";
            refId = "A";
          }
        ]
        "none")
      (timeseriesPanel 12 "Service threads" {
          h = 8;
          w = 12;
          x = 12;
          y = 21;
        } [
          {
            expr = "sum by (groupname) (namedprocess_namegroup_thread_count{instance=\"foundry\",groupname=~\"${serviceProcessRegex}\"})";
            legendFormat = "{{groupname}}";
            refId = "A";
          }
        ]
        "none")
      (timeseriesPanel 13 "Service disk I/O" {
          h = 8;
          w = 24;
          x = 0;
          y = 29;
        } [
          {
            expr = "rate(namedprocess_namegroup_read_bytes_total{instance=\"foundry\",groupname=~\"${serviceProcessRegex}\"}[$__rate_interval])";
            legendFormat = "{{groupname}} read";
            refId = "A";
          }
          {
            expr = "-rate(namedprocess_namegroup_write_bytes_total{instance=\"foundry\",groupname=~\"${serviceProcessRegex}\"}[$__rate_interval])";
            legendFormat = "{{groupname}} write";
            refId = "B";
          }
        ]
        "Bps")
    ];

    edgeAndBackupsDashboard = commonDashboard "Foundry / Edge & Backups" "foundry-edge-and-backups" [
      (lokiTimeseriesPanel 1 "Caddy requests by host" {
          h = 8;
          w = 12;
          x = 0;
          y = 0;
        } [
          {
            datasource = lokiDatasource;
            expr = "sum by (request_host) (count_over_time({host=\"foundry\", job=\"caddy-access\"} | json [$__interval]))";
            legendFormat = "{{request_host}}";
            refId = "A";
          }
        ]
        "reqps")
      (lokiTimeseriesPanel 2 "Caddy 5xx responses" {
          h = 8;
          w = 12;
          x = 12;
          y = 0;
        } [
          {
            datasource = lokiDatasource;
            expr = "sum(count_over_time({host=\"foundry\", job=\"caddy-access\"} |~ \"\\\"status\\\":5[0-9][0-9]\" [$__interval]))";
            legendFormat = "5xx";
            refId = "A";
          }
        ]
        "reqps")
      (statPanel 3 "Backup timers seen" {
          h = 4;
          w = 8;
          x = 0;
          y = 8;
        }
        "count(node_systemd_unit_state{instance=\"foundry\",name=~\"${backupTimers}\"})"
        "none")
      (statPanel 4 "Oldest backup timer age" {
          h = 4;
          w = 8;
          x = 8;
          y = 8;
        }
        "max(time() - node_systemd_timer_last_trigger_seconds{instance=\"foundry\",name=~\"${backupTimers}\"})"
        "s")
      (statPanel 5 "MD RAID inactive disks" {
          h = 4;
          w = 8;
          x = 16;
          y = 8;
        }
        "sum(node_md_disks{instance=\"foundry\",state!=\"active\"})"
        "none")
      (timeseriesPanel 6 "Backup timer age" {
          h = 8;
          w = 12;
          x = 0;
          y = 12;
        } [
          {
            expr = "time() - node_systemd_timer_last_trigger_seconds{instance=\"foundry\",name=~\"${backupTimers}\"}";
            legendFormat = "{{name}}";
            refId = "A";
          }
        ]
        "s")
      (timeseriesPanel 7 "RAID disks" {
          h = 8;
          w = 12;
          x = 12;
          y = 12;
        } [
          {
            expr = "node_md_disks{instance=\"foundry\"}";
            legendFormat = "{{device}} {{state}}";
            refId = "A";
          }
        ]
        "none")
      (logsPanel 8 "Recent Caddy access logs" {
          h = 10;
          w = 12;
          x = 0;
          y = 20;
        }
        "{host=\"foundry\", job=\"caddy-access\"} | json")
      (logsPanel 9 "Backup and healthcheck logs" {
          h = 10;
          w = 12;
          x = 12;
          y = 20;
        }
        "{host=\"foundry\", job=\"systemd-journal\"} |~ \"restic|postgresqlBackup|healthchecks-ping\"")
    ];
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

    # Per-service resource accounting. Node exporter gives host-wide CPU,
    # memory, disk, network, and systemd state; process-exporter adds grouped
    # CPU/RSS/process/thread metrics for the services we actually care about.
    services.prometheus.exporters.process = {
      enable = true;
      listenAddress = bindHost;
      port = processExporterPort;
      # Root is needed for accurate cross-user /proc/<pid>/io reads; the
      # exporter stays loopback-only and inherits the module's hardening.
      user = "root";
      group = "root";
      settings.process_names =
        map (service: {
          inherit (service) cmdline name;
        })
        serviceProcesses;
    };

    # ---------------- Log store ----------------
    # Single-node Loki with the tsdb schema (the boltdb-shipper schema is
    # deprecated upstream). Storage is plain filesystem under /var/lib/loki
    # — covered by the daily restic snapshot.
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
        # served by the 15-min journal restic job, not by a
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

      // ---- Metrics: scrape process_exporter for per-service resources.
      prometheus.scrape "process" {
        targets = [{
          __address__ = "${bindHost}:${toString processExporterPort}",
          instance    = "foundry",
          job         = "process-exporter",
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

      // ---- Logs: Caddy access JSON -> Loki.
      local.file_match "caddy_access" {
        path_targets = [
          {
            __path__ = "/var/log/caddy/access-auth.log",
            job      = "caddy-access",
            host     = "foundry",
          },
          {
            __path__ = "/var/log/caddy/access-foundry.log",
            job      = "caddy-access",
            host     = "foundry",
          },
          {
            __path__ = "/var/log/caddy/access-grafana.log",
            job      = "caddy-access",
            host     = "foundry",
          },
        ]
        sync_period = "10s"
      }

      loki.source.file "caddy_access" {
        targets    = local.file_match.caddy_access.targets
        forward_to = [loki.write.local.receiver]
      }

      loki.write "local" {
        endpoint {
          url = "http://${bindHost}:${toString lokiPort}/loki/api/v1/push"
        }
      }
    '';

    # Caddy writes access logs as 0640; the Alloy service needs the Caddy
    # group to tail those files into Loki.
    systemd.services.alloy.serviceConfig.SupplementaryGroups = ["caddy"];

    # Grafana generated random datasource UIDs before we started pinning
    # dashboards to stable datasource UIDs. Align the existing SQLite rows
    # before Grafana starts so provisioning can update them instead of
    # aborting with "data source not found".
    systemd.services.grafana-datasource-uids = {
      description = "Align Grafana datasource UIDs with provisioned dashboards";
      before = ["grafana.service"];
      requiredBy = ["grafana.service"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
      };
      script = ''
        set -euo pipefail
        if [ ! -f ${grafanaDbPath} ]; then
          exit 0
        fi
        has_data_source_table="$(${pkgs.sqlite}/bin/sqlite3 ${grafanaDbPath} \
          "select count(*) from sqlite_master where type = 'table' and name = 'data_source';")"
        if [ "$has_data_source_table" != "1" ]; then
          exit 0
        fi
        ${pkgs.sqlite}/bin/sqlite3 ${grafanaDbPath} '
          update data_source set uid = "victoriametrics" where name = "VictoriaMetrics";
          update data_source set uid = "loki" where name = "Loki";
        '
      '';
    };

    # ---------------- Dashboard ----------------
    # Grafana still listens on localhost only; Caddy publishes it at
    # `grafana.simonito.com` and Authentik handles login via native OIDC.
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = bindHost;
          http_port = grafanaPort;
        };
        analytics.reporting_enabled = false;
        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "VictoriaMetrics";
            uid = "victoriametrics";
            type = "prometheus";
            access = "proxy";
            url = "http://${bindHost}:${toString vmPort}";
            isDefault = true;
          }
          {
            name = "Loki";
            uid = "loki";
            type = "loki";
            access = "proxy";
            url = "http://${bindHost}:${toString lokiPort}";
          }
        ];

        dashboards.settings.providers = [
          {
            name = "foundry";
            orgId = 1;
            folder = "Foundry";
            type = "file";
            disableDeletion = true;
            allowUiUpdates = true;
            options.path = dashboardDir;
          }
        ];
      };
    };
  };
}
