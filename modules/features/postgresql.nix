{...}: {
  flake.nixosModules.postgresql = {pkgs, ...}: let
    backupDir = "/var/backup/postgresql";
  in {
    # Shared local PostgreSQL cluster for current and future apps. Individual
    # feature modules add their own `ensureDatabases` / `ensureUsers`; this
    # module owns the server and the logical-backup policy.
    services.postgresql.enable = true;
    services.postgresql.settings.password_encryption = "scram-sha-256";

    # Lock down cross-database visibility: by default PUBLIC has CONNECT on
    # every database, so any role on the cluster can reach every other DB.
    # Revoking PUBLIC on template1 means new databases (which inherit
    # template1's ACL) are locked by default; their owner still has CONNECT
    # implicitly. Existing databases were locked down in a one-shot run.
    services.postgresql.initialScript = pkgs.writeText "postgres-lockdown.sql" ''
      REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
      REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
    '';

    services.postgresqlBackup = {
      enable = true;
      backupAll = true;
      location = backupDir;
      compression = "zstd";
      compressionLevel = 9;
      pgdumpAllOptions = "--clean --if-exists";
      # Finish the dump before the restic job snapshots the dump directory.
      startAt = "*-*-* 03:30:00";
    };
  };
}
