{...}: {
  flake.nixosModules.deliverable = {
    config,
    lib,
    ...
  }: let
    domain = "database.datamastery.nl";
    database = "deliverable";
    databaseUser = "deliverable";
    pgbouncerPort = 6432;
    acmeWebroot = "/var/lib/acme/acme-challenge";
    acmeCertDir = config.security.acme.certs.${domain}.directory;
  in {
    services.postgresql = {
      ensureDatabases = [database];
      ensureUsers = [
        {
          name = databaseUser;
          ensureDBOwnership = true;
        }
      ];

      # PgBouncer is the only public PostgreSQL-protocol endpoint. It reaches
      # the backend over the local Unix socket as the database owner.
      authentication = lib.mkBefore ''
        local ${database} ${databaseUser} peer map=pgbouncer-deliverable
      '';
      identMap = lib.mkAfter ''
        pgbouncer-deliverable pgbouncer ${databaseUser}
      '';
    };

    sops.secrets."deliverable/pgbouncer_auth" = {
      owner = config.systemd.services.pgbouncer.serviceConfig.User;
      group = config.systemd.services.pgbouncer.serviceConfig.Group;
      mode = "0400";
    };

    security.acme = {
      acceptTerms = true;
      defaults.email = "simon@datagiant.org";
      certs.${domain} = {
        webroot = acmeWebroot;
        group = config.systemd.services.pgbouncer.serviceConfig.Group;
        reloadServices = ["pgbouncer.service"];
      };
    };

    services.caddy.virtualHosts."http://${domain}".extraConfig = ''
      root * ${acmeWebroot}
      file_server /.well-known/acme-challenge/*
      respond 404
    '';

    services.pgbouncer = {
      enable = true;
      openFirewall = true;
      settings = {
        databases.${database} = "host=/run/postgresql port=5432 dbname=${database} user=${databaseUser} pool_size=10 max_db_connections=20";

        pgbouncer = {
          listen_addr = "*";
          listen_port = pgbouncerPort;
          pool_mode = "session";
          max_client_conn = 80;
          default_pool_size = 10;
          max_db_connections = 20;
          max_user_connections = 20;
          reserve_pool_size = 2;
          reserve_pool_timeout = 5;
          client_login_timeout = 15;
          idle_transaction_timeout = 300;
          query_timeout = 120;
          ignore_startup_parameters = "extra_float_digits";

          auth_type = "scram-sha-256";
          auth_file = config.sops.secrets."deliverable/pgbouncer_auth".path;

          client_tls_sslmode = "require";
          client_tls_cert_file = "${acmeCertDir}/fullchain.pem";
          client_tls_key_file = "${acmeCertDir}/key.pem";

          log_connections = 1;
          log_disconnections = 1;
          log_pooler_errors = 1;
        };
      };
    };

    systemd.services.pgbouncer = {
      wants = ["acme-${domain}.service"];
      after = ["acme-${domain}.service"];
    };

    services.crowdsec.localConfig = {
      acquisitions = [
        {
          source = "journalctl";
          journalctl_filter = ["_SYSTEMD_UNIT=pgbouncer.service"];
          labels.type = "pgbouncer";
        }
      ];

      parsers.s01Parse = [
        {
          name = "local/pgbouncer-auth-failures";
          description = "Parse PgBouncer authentication failures";
          filter = "evt.Line.Labels.type == 'pgbouncer'";
          onsuccess = "next_stage";
          pattern_syntax.PGBOUNCER_AUTH_FAILURE = ".*@%{IPORHOST:source_ip}:%{INT:source_port}.*(password authentication failed|no such user|TLS required|client_login_timeout).*";
          grok = {
            name = "PGBOUNCER_AUTH_FAILURE";
            expression = "evt.Line.Raw";
          };
          statics = [
            {
              meta = "log_type";
              value = "pgbouncer_failed_auth";
            }
            {
              meta = "service";
              value = "pgbouncer";
            }
            {
              meta = "source_ip";
              expression = "evt.Parsed.source_ip";
            }
          ];
        }
      ];

      scenarios = [
        {
          type = "leaky";
          name = "local/pgbouncer-bf";
          description = "Detect repeated PgBouncer authentication failures";
          filter = "evt.Meta.log_type == 'pgbouncer_failed_auth'";
          groupby = "evt.Meta.source_ip";
          capacity = 6;
          leakspeed = "1m";
          blackhole = "5m";
          labels = {
            service = "pgbouncer";
            confidence = 2;
            spoofable = 0;
            classification = ["attack.T1110"];
            behavior = "generic:bruteforce";
            label = "PgBouncer Bruteforce";
            remediation = true;
          };
        }
      ];
    };
  };
}
