{...}: {
  flake.nixosModules.restic = {
    config,
    pkgs,
    lib,
    ...
  }: let
    # Hetzner Storage Box subaccount used by foundry (append-only credential).
    # Pairs with the `foundry-admin` subaccount used from the laptop for
    # prune/restore — see server_plan.md Phase 5. The username is not a
    # secret; the SSH key (sops) and restic password (sops) are what gate
    # access.
    storageboxHost = "u580408-sub1.your-storagebox.de";
    storageboxUser = "u580408-sub1";
    # Path passed to `-r rclone:<remote>:<path>` — irrelevant, because the
    # Storage Box's forced command fixes the real path to the subaccount's
    # chrooted home. Kept stable across runs so restic's metadata is
    # coherent.
    repoName = "foundry";

    # restic spawns this as `rclone.program`. It dials the Storage Box over
    # SSH; the forced command pinned in the subaccount's authorized_keys runs
    # `rclone serve restic --stdio --append-only <repoName>`. Append-only is
    # enforced server-side — from foundry's credential, `forget`/`prune`/
    # overwrite are rejected by rclone regardless of what the client asks.
    sshWrapper = pkgs.writeShellScript "restic-storagebox-ssh" ''
      exec ${pkgs.openssh}/bin/ssh \
        -p 23 \
        -i ${config.sops.secrets."restic/ssh_key".path} \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        "${storageboxUser}@${storageboxHost}" \
        "$@"
    '';

    # Shared between the daily backup and the monthly check unit so both use
    # the same transport.
    resticRcloneOption = "rclone.program=${sshWrapper}";
  in {
    # Pin the Storage Box host key. Capture once after provisioning via
    #   ssh-keyscan -t ed25519 -p 23 <storageboxHost>
    # and paste the key below. Without this, the first connection would
    # TOFU-accept any key; with it, a MITM on the backup path is visible
    # immediately as an ssh failure.
    programs.ssh.knownHosts."[${storageboxHost}]:23".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs";

    sops.secrets."restic/password" = {
      owner = "root";
      mode = "0400";
    };
    sops.secrets."restic/ssh_key" = {
      owner = "root";
      mode = "0400";
    };

    services.restic.backups.foundry = {
      # The `rclone:<remote>:<path>` URL is parsed by restic but the remote
      # + path are irrelevant here — rclone is never invoked locally; the
      # Storage Box's forced command fixes the real repo path. Keep the URL
      # stable so restic's metadata stays coherent across runs.
      repository = "rclone:storagebox:${repoName}";
      passwordFile = config.sops.secrets."restic/password".path;

      # FoundryVTT world state + the entire VictoriaMetrics data tree +
      # live Loki tsdb data.
      #
      # VictoriaMetrics note (corrected 2026-04-23 after a restore drill):
      # VM's `/snapshot/create` does NOT build a self-contained hardlinked
      # tree under `snapshots/<name>/`. It builds a structure of RELATIVE
      # SYMLINKS: `snapshots/<name>/data/{small,big,indexdb}` each point
      # at `../../../data/<table>/snapshots/<name>/`, where the hardlinked
      # partition files actually live. Backing up only `snapshots/` means
      # capturing dangling symlinks. So back up the whole
      # `/var/lib/victoriametrics` dir; restic dedup + the fact that VM
      # parts are immutable once written keep run-over-run cost near zero
      # on the bytes, and the backupPrepareCommand's snapshot still acts
      # as the point-in-time anchor for a clean restore.
      #
      # Loki's tsdb chunks and index files are flushed atomically on
      # close — live-backing them up is safe; the last few minutes of
      # unflushed log data are covered by the separate 15-minute journal
      # job below.
      paths = [
        "/var/lib/foundryvtt"
        "/var/lib/victoriametrics"
        "/var/lib/loki"
      ];

      # Safe to leave on. Init writes a handful of new objects (`config`,
      # `keys/*`), all creates — append-only permits that. Subsequent runs
      # short-circuit on an existing repo.
      initialize = true;

      # Foundry persists world state as live JSON/ndjson. Stopping the
      # service for the duration of the backup is the simplest way to get
      # a point-in-time snapshot; expect ~3–5s of daily downtime at 04:00.
      # VictoriaMetrics stays up: its `/snapshot/create` endpoint hard-links
      # the storage dir into a new subdirectory under snapshots/, which is
      # what restic then reads. The snapshot name is recorded in /run so
      # backupCleanupCommand can delete it after restic finishes, even if
      # the main backup step fails.
      backupPrepareCommand = ''
        set -euo pipefail
        snapshot=$(${pkgs.curl}/bin/curl -sf \
          http://127.0.0.1:8428/snapshot/create \
          | ${pkgs.jq}/bin/jq -r '.snapshot')
        printf '%s\n' "$snapshot" > /run/vm-snapshot-name
        ${pkgs.systemd}/bin/systemctl stop foundryvtt.service
      '';
      backupCleanupCommand = ''
        ${pkgs.systemd}/bin/systemctl start foundryvtt.service
        snapshot=$(cat /run/vm-snapshot-name 2>/dev/null || true)
        if [ -n "$snapshot" ]; then
          ${pkgs.curl}/bin/curl -sf \
            "http://127.0.0.1:8428/snapshot/delete?snapshot=$snapshot" \
            >/dev/null || true
          rm -f /run/vm-snapshot-name
        fi
      '';

      extraOptions = [resticRcloneOption];

      # No pruneOpts: foundry holds the append-only credential, so `forget
      # --prune` would be rejected. Retention is enforced from the laptop
      # (separate, full-access credential) — see server_plan.md Phase 5
      # "Pruning from the laptop".
      #
      # No checkOpts: a monthly bit-rot scan runs in its own unit below so
      # heavy read-sampling doesn't bloat daily runtime, and a check failure
      # surfaces as a distinct unit failure rather than being folded into
      # the backup job.

      timerConfig = {
        OnCalendar = "04:00";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };

    # Crash-forensics backup. `/var/log/journal` is append-only on disk, so
    # restic's content-addressed dedup keeps each run cheap — only new
    # journal segments get uploaded. Cadence is every 15 min, which caps
    # the "what happened right before the crash?" gap at 15 minutes. Uses
    # the same append-only credential + password as the main job. A
    # separate repo (`foundry-journal`) keeps the restore path trivial
    # (`restic restore latest` doesn't need a path filter) and isolates
    # journal retention from the main repo's retention policy.
    services.restic.backups.foundry-journal = {
      repository = "rclone:storagebox:foundry-journal";
      passwordFile = config.sops.secrets."restic/password".path;
      paths = ["/var/log/journal"];
      initialize = true;
      extraOptions = [resticRcloneOption];
      timerConfig = {
        OnCalendar = "*:00/15";
        RandomizedDelaySec = "60";
        Persistent = true;
      };
    };

    # Monthly bit-rot sentry. `--read-data-subset=5%` re-downloads 5% of
    # pack files and verifies every pack header + snapshot tree. Over ~20
    # months the whole repo is read at least once. Separate unit so its
    # journal lives on its own and an OnFailure= hook can be attached
    # distinctly from the backup unit (Phase 5 step 6).
    systemd.services.restic-check-foundry = {
      description = "Restic repository integrity check (5% read-sample)";
      wants = ["network-online.target"];
      after = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      environment = {
        RESTIC_REPOSITORY = "rclone:storagebox:${repoName}";
        RESTIC_PASSWORD_FILE = config.sops.secrets."restic/password".path;
      };
      script = ''
        ${pkgs.restic}/bin/restic \
          -o ${lib.escapeShellArg resticRcloneOption} \
          check --read-data-subset=5%
      '';
    };

    systemd.timers.restic-check-foundry = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "monthly";
        RandomizedDelaySec = "6h";
        Persistent = true;
      };
    };
  };
}
