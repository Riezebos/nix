{...}: {
  flake.nixosModules.postgresql = {...}: let
    backupDir = "/var/backup/postgresql";
  in {
    # Shared local PostgreSQL cluster for current and future apps. Individual
    # feature modules add their own `ensureDatabases` / `ensureUsers`; this
    # module owns the server and the logical-backup policy.
    services.postgresql.enable = true;

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
