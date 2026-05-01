{...}: {
  flake.nixosModules.deliverable = {
    config,
    lib,
    pkgs,
    ...
  }: let
    domain = "database.datamastery.nl";
    database = "deliverable";
    databaseUser = "deliverable";
    pgbouncerAuthUser = "pgbouncer_auth";
    pgbouncerPort = 6432;
    acmeWebroot = "/var/lib/acme/acme-challenge";
    acmeCertDir = config.security.acme.certs.${domain}.directory;
    deliverableSchemas = ["public" "order_forecaster" "engineers" "analysts" "internal"];
    deliverableSchemaSqlArray = lib.concatMapStringsSep ", " (s: "'${s}'") deliverableSchemas;
    deliverableSchemaSql =
      lib.concatMapStringsSep "\n" (schema: ''
        CREATE SCHEMA IF NOT EXISTS "${schema}" AUTHORIZATION "${databaseUser}";
        ALTER SCHEMA "${schema}" OWNER TO "${databaseUser}";
      '')
      deliverableSchemas;
    deliverablePrivilegeSql = pkgs.writeText "deliverable-privileges.sql" ''
      ALTER ROLE "${databaseUser}" SET createrole_self_grant = 'set, inherit';

      CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION postgres;
      ALTER SCHEMA pgbouncer OWNER TO postgres;
      REVOKE ALL ON SCHEMA pgbouncer FROM PUBLIC;
      GRANT USAGE ON SCHEMA pgbouncer TO "${pgbouncerAuthUser}";

      CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(
        IN username text,
        OUT uname text,
        OUT phash text
      )
      RETURNS record
      LANGUAGE sql
      SECURITY DEFINER
      SET search_path = pg_catalog
      AS $$
        SELECT rolname, rolpassword
        FROM pg_authid
        WHERE rolname = username
          AND rolcanlogin
          AND rolpassword IS NOT NULL
      $$;
      ALTER FUNCTION pgbouncer.user_lookup(text) OWNER TO postgres;
      REVOKE ALL ON FUNCTION pgbouncer.user_lookup(text) FROM PUBLIC;
      GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO "${pgbouncerAuthUser}";

      ${deliverableSchemaSql}

      DO $$
      DECLARE
        obj record;
      BEGIN
        FOR obj IN
          SELECT n.nspname, c.relname, c.relkind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = ANY (ARRAY[${deliverableSchemaSqlArray}])
            AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
            AND pg_get_userbyid(c.relowner) <> '${databaseUser}'
            AND NOT EXISTS (
              SELECT 1
              FROM pg_depend d
              WHERE d.objid = c.oid
                AND d.deptype = 'e'
            )
        LOOP
          EXECUTE format(
            'ALTER %s %I.%I OWNER TO %I',
            CASE obj.relkind
              WHEN 'S' THEN 'SEQUENCE'
              WHEN 'v' THEN 'VIEW'
              WHEN 'm' THEN 'MATERIALIZED VIEW'
              WHEN 'f' THEN 'FOREIGN TABLE'
              ELSE 'TABLE'
            END,
            obj.nspname,
            obj.relname,
            '${databaseUser}'
          );
        END LOOP;

        FOR obj IN
          SELECT
            n.nspname,
            p.proname,
            p.prokind,
            pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = ANY (ARRAY[${deliverableSchemaSqlArray}])
            AND pg_get_userbyid(p.proowner) <> '${databaseUser}'
            AND NOT EXISTS (
              SELECT 1
              FROM pg_depend d
              WHERE d.objid = p.oid
                AND d.deptype = 'e'
            )
        LOOP
          EXECUTE format(
            'ALTER %s %I.%I(%s) OWNER TO %I',
            CASE obj.prokind
              WHEN 'p' THEN 'PROCEDURE'
              WHEN 'a' THEN 'AGGREGATE'
              ELSE 'FUNCTION'
            END,
            obj.nspname,
            obj.proname,
            obj.args,
            '${databaseUser}'
          );
        END LOOP;
      END
      $$;

      GRANT USAGE, CREATE ON SCHEMA order_forecaster TO trainee_group;
      GRANT USAGE ON SCHEMA public TO trainee_group;
      GRANT USAGE ON SCHEMA internal TO trainee_group;
      GRANT SELECT ON ALL TABLES IN SCHEMA public TO trainee_group;
      GRANT SELECT ON ALL TABLES IN SCHEMA internal TO trainee_group;
      ALTER DEFAULT PRIVILEGES FOR ROLE "${databaseUser}" IN SCHEMA public GRANT SELECT ON TABLES TO trainee_group;
      ALTER DEFAULT PRIVILEGES FOR ROLE "${databaseUser}" IN SCHEMA internal GRANT SELECT ON TABLES TO trainee_group;
      ALTER DEFAULT PRIVILEGES FOR ROLE "${databaseUser}" IN SCHEMA order_forecaster GRANT ALL ON TABLES TO trainee_group;

      GRANT USAGE ON SCHEMA engineers TO engineers_group;
      GRANT SELECT ON ALL TABLES IN SCHEMA engineers TO engineers_group;
      ALTER DEFAULT PRIVILEGES FOR ROLE "${databaseUser}" IN SCHEMA engineers GRANT SELECT ON TABLES TO engineers_group;

      GRANT USAGE ON SCHEMA analysts TO analysts_group;
      GRANT SELECT ON ALL TABLES IN SCHEMA analysts TO analysts_group;
      ALTER DEFAULT PRIVILEGES FOR ROLE "${databaseUser}" IN SCHEMA analysts GRANT SELECT ON TABLES TO analysts_group;
    '';
    databaseHelpPage = pkgs.writeTextDir "index.html" ''
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Database connection details</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              font-family: Poppins, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              line-height: 1.5;
              background: #002f52;
              color: #ffffff;
            }

            main {
              width: min(32rem, calc(100vw - 2rem));
              padding: 1rem 0;
            }

            h1 {
              margin: 0 0 1rem;
              font-size: 2rem;
              line-height: 1.1;
              color: #ffd64c;
            }

            p {
              margin: 0 0 1rem;
            }

            dl {
              display: grid;
              grid-template-columns: 6rem 1fr;
              gap: 0.5rem 1rem;
              margin: 1.25rem 0;
              padding: 1rem;
              border: 1px solid #4080aa;
              border-left: 4px solid #ffd64c;
              border-radius: 8px;
              background: #1f3f53;
            }

            dt {
              font-weight: 700;
            }

            dd {
              margin: 0;
              font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
              overflow-wrap: anywhere;
            }

            @media (max-width: 30rem) {
              h1 {
                font-size: 1.7rem;
              }
            }
          </style>
        </head>
        <body>
          <main>
            <h1>Database connection details</h1>
            <p>Use the deliverable database with your provided database credentials.</p>
            <dl>
              <dt>Host</dt>
              <dd>${domain}</dd>
              <dt>Port</dt>
              <dd>${toString pgbouncerPort}</dd>
              <dt>Database</dt>
              <dd>${database}</dd>
              <dt>SSL</dt>
              <dd>required</dd>
            </dl>
            <p>The username and password are the ones you were provided.</p>
          </main>
        </body>
      </html>
    '';
  in {
    services.postgresql = {
      ensureDatabases = [database];
      ensureUsers = [
        {
          name = databaseUser;
          ensureDBOwnership = true;
          ensureClauses.createrole = true;
        }
        {name = pgbouncerAuthUser;}
        {
          name = "trainee_group";
          ensureClauses.login = false;
        }
        {
          name = "engineers_group";
          ensureClauses.login = false;
        }
        {
          name = "analysts_group";
          ensureClauses.login = false;
        }
      ];

      # PgBouncer is the only public PostgreSQL-protocol endpoint. The owner
      # role keeps peer auth for administration; trainee roles created by the
      # course prep scripts use their PostgreSQL passwords through PgBouncer's
      # auth_query path.
      authentication = lib.mkBefore ''
        local ${database} postgres peer map=postgres
        local ${database} ${pgbouncerAuthUser} peer map=pgbouncer-auth
        local ${database} ${databaseUser} peer map=pgbouncer-deliverable
        local ${database} all scram-sha-256
      '';
      identMap = lib.mkAfter ''
        pgbouncer-auth pgbouncer ${pgbouncerAuthUser}
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

    # Caddy serves the ACME http-01 challenge for pgbouncer's cert. It needs
    # to traverse the webroot, which acme.nix chgrp's to the cert group
    # (pgbouncer); adding caddy to that group is the smallest fix. The auth
    # file is 0400 so caddy still can't read it.
    users.users.caddy.extraGroups = ["pgbouncer"];

    services.caddy.virtualHosts."http://${domain}".extraConfig = ''
      @acme path /.well-known/acme-challenge/*
      handle @acme {
        root * ${acmeWebroot}
        file_server
      }
      handle {
        respond 404
      }
    '';

    services.caddy.virtualHosts."https://${domain}".extraConfig = ''
      encode zstd gzip
      header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
      }
      root * ${databaseHelpPage}
      file_server
    '';

    services.pgbouncer = {
      enable = true;
      openFirewall = true;
      settings = {
        databases.${database} = "host=/run/postgresql port=5432 dbname=${database} pool_size=10 max_db_connections=20";

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
          auth_user = pgbouncerAuthUser;
          auth_query = "SELECT uname, phash FROM pgbouncer.user_lookup($1)";

          client_tls_sslmode = "require";
          client_tls_cert_file = "${acmeCertDir}/fullchain.pem";
          client_tls_key_file = "${acmeCertDir}/key.pem";
          client_tls_ca_file = "/etc/ssl/certs/ca-certificates.crt";

          log_connections = 1;
          log_disconnections = 1;
          log_pooler_errors = 1;
        };
      };
    };

    systemd.services.pgbouncer = {
      wants = ["acme-${domain}.service" "postgresql-deliverable-privileges.service"];
      after = ["acme-${domain}.service" "postgresql-deliverable-privileges.service"];
    };

    systemd.services.postgresql-deliverable-privileges = {
      description = "Prepare deliverable database privileges";
      requires = ["postgresql.service" "postgresql-setup.service"];
      after = ["postgresql.service" "postgresql-setup.service"];
      wantedBy = ["multi-user.target"];
      path = [config.services.postgresql.finalPackage];
      serviceConfig = {
        User = "postgres";
        Group = "postgres";
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        psql -v ON_ERROR_STOP=1 -d ${database} -f ${deliverablePrivilegeSql}
      '';
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
