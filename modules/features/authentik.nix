{...}: {
  flake.nixosModules.authentik = {
    pkgs,
    lib,
    ...
  }: let
    bindHost = "127.0.0.1";
    authentikHttpPort = 9000;
    authentikHttpsPort = 9443;
    authentikMetricsPort = 9300;
    authentikRedisPort = 16379;

    dataDir = "/var/lib/authentik";
    secretDir = "${dataDir}/secrets";
    storageDir = "${dataDir}/storage";
    secretKeyPath = "${secretDir}/secret-key";
    iacTokenPath = "${secretDir}/iac-token";
    grafanaSecretDir = "/var/lib/grafana/secrets";
    grafanaClientSecretPath = "${grafanaSecretDir}/grafana-oidc-client-secret";
    grafanaSecretKeyPath = "${grafanaSecretDir}/grafana-secret-key";

    # Authentik-readable mirror of the OIDC client secret. Grafana's own copy is
    # 0400 grafana:grafana, so the blueprint's `!File` cannot read it; both are
    # written from one generation step below so they cannot drift.
    grafanaClientSecretMirror = "${secretDir}/grafana-oidc-client-secret";

    # Repo-managed Authentik objects. Applied by authentik-blueprints.service on
    # every activation where the contents changed; see docs/foundry/authentik.md.
    blueprintsDir = ./authentik-blueprints;
    blueprintFiles =
      lib.sort (a: b: a < b)
      (lib.filter (n: lib.hasSuffix ".yaml" n)
        (lib.attrNames (builtins.readDir blueprintsDir)));

    prepareSecrets = pkgs.writeShellScript "authentik-prepare-secrets" ''
      set -euo pipefail

      install -d -m 0750 -o authentik -g authentik \
        ${dataDir} \
        ${secretDir} \
        ${storageDir}
      install -d -m 0750 -o grafana -g grafana ${grafanaSecretDir}

      if [ ! -s ${secretKeyPath} ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 60 | tr -d '\n' > ${secretKeyPath}
        printf '\n' >> ${secretKeyPath}
        chown authentik:authentik ${secretKeyPath}
        chmod 0400 ${secretKeyPath}
      fi

      # API token for out-of-band administration of Authentik itself (the
      # `svc-iac` service account, see 05-iac-service-account.yaml). Generated
      # here rather than kept in sops so a full-admin credential never lands in
      # the repo; read it back with
      #   ssh deploy@foundry sudo cat ${iacTokenPath}
      if [ ! -s ${iacTokenPath} ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > ${iacTokenPath}
        chown authentik:authentik ${iacTokenPath}
        chmod 0400 ${iacTokenPath}
      fi

      if [ ! -s ${grafanaClientSecretPath} ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 36 | tr -d '\n' > ${grafanaClientSecretPath}
        printf '\n' >> ${grafanaClientSecretPath}
        chown grafana:grafana ${grafanaClientSecretPath}
        chmod 0400 ${grafanaClientSecretPath}
      fi

      # Mirror it where the blueprint's `!File` can read it. Sourced from
      # Grafana's copy rather than generated independently, so the two are the
      # same value by construction on both a fresh host and this existing one.
      if ! ${pkgs.diffutils}/bin/cmp -s ${grafanaClientSecretPath} ${grafanaClientSecretMirror}; then
        install -m 0400 -o authentik -g authentik \
          ${grafanaClientSecretPath} ${grafanaClientSecretMirror}
      fi

      # Grafana 26.05 dropped the built-in default for security.secret_key, so
      # we mint a persistent per-host key here (same pattern as the OIDC client
      # secret above). This DB stores no encrypted secrets today, so a fresh
      # random key is safe.
      if [ ! -s ${grafanaSecretKeyPath} ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 36 | tr -d '\n' > ${grafanaSecretKeyPath}
        printf '\n' >> ${grafanaSecretKeyPath}
        chown grafana:grafana ${grafanaSecretKeyPath}
        chmod 0400 ${grafanaSecretKeyPath}
      fi
    '';

    authentikBaseService = {
      after = [
        "network-online.target"
        "postgresql.service"
        "redis-authentik.service"
        "authentik-prepare-secrets.service"
      ];
      wants = [
        "network-online.target"
        "postgresql.service"
        "redis-authentik.service"
        "authentik-prepare-secrets.service"
      ];
      serviceConfig = {
        User = "authentik";
        Group = "authentik";
        WorkingDirectory = dataDir;
        StateDirectory = "authentik";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "authentik";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ReadWritePaths = [dataDir];
      };
      environment = {
        AUTHENTIK_POSTGRESQL__HOST = "/run/postgresql";
        AUTHENTIK_POSTGRESQL__NAME = "authentik";
        AUTHENTIK_POSTGRESQL__USER = "authentik";

        AUTHENTIK_REDIS__HOST = bindHost;
        AUTHENTIK_REDIS__PORT = toString authentikRedisPort;

        AUTHENTIK_SECRET_KEY = "file://${secretKeyPath}";
        AUTHENTIK_STORAGE__BACKEND = "file";
        AUTHENTIK_STORAGE__FILE__PATH = storageDir;

        AUTHENTIK_LISTEN__HTTP = "${bindHost}:${toString authentikHttpPort}";
        AUTHENTIK_LISTEN__HTTPS = "${bindHost}:${toString authentikHttpsPort}";
        AUTHENTIK_LISTEN__METRICS = "${bindHost}:${toString authentikMetricsPort}";
        AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS = "127.0.0.1/32,::1/128";

        AUTHENTIK_DISABLE_UPDATE_CHECK = "true";
        AUTHENTIK_ERROR_REPORTING__ENABLED = "false";
        AUTHENTIK_LOG_LEVEL = "info";
      };
    };
  in {
    # Authentik is one tenant of the shared local PostgreSQL cluster.
    services.postgresql = {
      ensureDatabases = ["authentik"];
      ensureUsers = [
        {
          name = "authentik";
          ensureDBOwnership = true;
        }
      ];
    };

    services.redis.servers.authentik = {
      enable = true;
      bind = bindHost;
      port = authentikRedisPort;
    };

    users.users.authentik = {
      isSystemUser = true;
      group = "authentik";
      home = dataDir;
    };
    users.groups.authentik = {};

    systemd.services.authentik-prepare-secrets = {
      description = "Prepare persistent Authentik secrets";
      wantedBy = ["multi-user.target"];
      before = [
        "authentik-migrate.service"
        "authentik-server.service"
        "authentik-worker.service"
        # Blueprints read the IaC token and the Grafana client secret mirror
        # through `!File`, both of which are written here.
        "authentik-blueprints.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = prepareSecrets;
      };
    };

    systemd.services.authentik-migrate =
      authentikBaseService
      // {
        description = "Run Authentik database migrations";
        wantedBy = ["multi-user.target"];
        serviceConfig =
          authentikBaseService.serviceConfig
          // {
            Type = "oneshot";
            ExecStart = "${pkgs.authentik}/bin/ak migrate";
          };
      };

    systemd.services.authentik-server =
      authentikBaseService
      // {
        description = "Authentik server";
        wantedBy = ["multi-user.target"];
        after = authentikBaseService.after ++ ["authentik-migrate.service"];
        wants = authentikBaseService.wants ++ ["authentik-migrate.service"];
        serviceConfig =
          authentikBaseService.serviceConfig
          // {
            ExecStart = "${pkgs.authentik}/bin/ak server";
          };
      };

    systemd.services.authentik-worker =
      authentikBaseService
      // {
        description = "Authentik worker";
        wantedBy = ["multi-user.target"];
        after =
          authentikBaseService.after
          ++ [
            "authentik-migrate.service"
            "authentik-server.service"
          ];
        wants =
          authentikBaseService.wants
          ++ [
            "authentik-migrate.service"
            "authentik-server.service"
          ];
        serviceConfig =
          authentikBaseService.serviceConfig
          // {
            ExecStart = "${pkgs.authentik}/bin/ak worker";
          };
      };

    # Authentik's own config as code. `ak apply_blueprint` is idempotent, so
    # this re-asserts every object in ./authentik-blueprints on each activation
    # where the directory changed (a changed file changes the store path, which
    # changes ExecStart, which is what makes systemd re-run it).
    #
    # AUTHENTIK_BLUEPRINTS_DIR is overridden for this unit only: the importer
    # refuses paths outside that root, and the long-running services must keep
    # the package default so upstream's own default/ and system/ blueprints
    # still get discovered.
    systemd.services.authentik-blueprints =
      authentikBaseService
      // {
        description = "Apply repo-managed Authentik blueprints";
        wantedBy = ["multi-user.target"];
        # After the worker, because upstream's default flows and scope mappings
        # are applied by worker-side discovery and every blueprint here `!Find`s
        # them. On a first boot that discovery may not have run yet, hence the
        # bounded retry rather than a hard failure.
        after = authentikBaseService.after ++ ["authentik-migrate.service" "authentik-worker.service"];
        wants = authentikBaseService.wants ++ ["authentik-migrate.service" "authentik-worker.service"];
        environment =
          authentikBaseService.environment
          // {
            AUTHENTIK_BLUEPRINTS_DIR = "${blueprintsDir}";
          };
        startLimitIntervalSec = 600;
        startLimitBurst = 6;
        serviceConfig =
          authentikBaseService.serviceConfig
          // {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = 30;
            ExecStart = "${pkgs.authentik}/bin/ak apply_blueprint ${lib.concatStringsSep " " blueprintFiles}";
          };
      };

    # Grafana is the first native OIDC target. Its provider/application pair is
    # declared in ./authentik-blueprints/10-grafana.yaml; the client secret is
    # persisted locally in Grafana's state dir so the app can read it.
    services.grafana.settings = {
      server = {
        domain = "grafana.simonito.com";
        root_url = "https://grafana.simonito.com/";
      };

      users.allow_org_create = false;
      auth.disable_login_form = false;

      security = {
        cookie_secure = true;
        hide_version = true;
        secret_key = "$__file{${grafanaSecretKeyPath}}";
      };

      "auth.generic_oauth" = {
        enabled = true;
        name = "Authentik";
        icon = "signin";
        allow_sign_up = true;
        allow_assign_grafana_admin = true;
        auto_login = false;
        client_id = "grafana";
        client_secret = "$__file{${grafanaClientSecretPath}}";
        scopes = "openid profile email";
        auth_url = "https://auth.datagiant.org/application/o/authorize/";
        token_url = "https://auth.datagiant.org/application/o/token/";
        api_url = "https://auth.datagiant.org/application/o/userinfo/";
        login_attribute_path = "preferred_username";
        email_attribute_path = "email";
        name_attribute_path = "name";
        role_attribute_path = "contains(groups[*], 'grafana-admins') && 'GrafanaAdmin' || contains(groups[*], 'foundry-admins') && 'Admin' || 'Viewer'";
        use_pkce = true;
      };
    };
  };
}
