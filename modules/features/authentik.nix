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
    grafanaClientSecretPath = "${secretDir}/grafana-oidc-client-secret";

    prepareSecrets = pkgs.writeShellScript "authentik-prepare-secrets" ''
      set -euo pipefail

      install -d -m 0750 -o authentik -g authentik \
        ${dataDir} \
        ${secretDir} \
        ${storageDir}

      if [ ! -s ${secretKeyPath} ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 60 | tr -d '\n' > ${secretKeyPath}
        printf '\n' >> ${secretKeyPath}
        chown authentik:authentik ${secretKeyPath}
        chmod 0400 ${secretKeyPath}
      fi

      if [ ! -s ${grafanaClientSecretPath} ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 36 | tr -d '\n' > ${grafanaClientSecretPath}
        printf '\n' >> ${grafanaClientSecretPath}
        chown authentik:authentik ${grafanaClientSecretPath}
        chmod 0400 ${grafanaClientSecretPath}
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

    # Grafana is the first native OIDC target. The provider/application pair
    # still needs to be created once inside Authentik, but the client secret is
    # already persisted locally so Grafana and Authentik can share it.
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
        auth_url = "https://auth.simonito.com/application/o/authorize/";
        token_url = "https://auth.simonito.com/application/o/token/";
        api_url = "https://auth.simonito.com/application/o/userinfo/";
        login_attribute_path = "preferred_username";
        email_attribute_path = "email";
        name_attribute_path = "name";
        role_attribute_path = "contains(groups[*], 'grafana-admins') && 'GrafanaAdmin' || contains(groups[*], 'foundry-admins') && 'Admin' || 'Viewer'";
        use_pkce = true;
      };
    };
  };
}
