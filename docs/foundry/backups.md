# Foundry Backups

Backups are designed around one constraint: if the server is compromised, it
must not be able to delete or rewrite its own backup history.

## Credentials

| Credential | Location |
|---|---|
| LUKS passphrase | Bitwarden, with a convenience copy in macOS Keychain |
| Restic repo password | Bitwarden and sops secret `restic/password` |
| Append-only Storage Box SSH key | sops secret `restic/ssh_key`, decrypted on `foundry` |
| Full-access Storage Box SSH key | laptop only: `~/.config/foundry-bootstrap/storagebox_adm` |

The admin Storage Box key must not live on `foundry`, in sops, or in CI.

## Restic model

`modules/features/restic.nix` defines:

- daily filesystem backup at roughly 04:00
- 15-minute journal backup for crash analysis
- daily PostgreSQL dump backup
- monthly restic integrity check with a 5 percent read sample

The Storage Box forced command chroots both the append-only and admin
credentials into the same underlying restic repository. The restic URL path
segment, such as `foundry` or `foundry-journal`, is therefore cosmetic. Use
`--path` when restoring so `latest` selects the right snapshot family.

Backed-up paths:

| Job | Path |
|---|---|
| daily | `/var/lib/foundryvtt-staging` |
| daily | `/var/lib/victoriametrics` |
| daily | `/var/lib/loki` |
| journal | `/var/log/journal` |
| PostgreSQL | `/var/backup/postgresql` |

Foundry data is staged with a short `SIGSTOP`/`rsync`/`SIGCONT` cycle before
restic runs. Restore `/var/lib/foundryvtt-staging/*` back into
`/var/lib/foundryvtt/`.

## Restore setup from the laptop

Storage Box External Reachability is normally off. Either toggle it on
temporarily in the Hetzner console or route through `foundry` with `ProxyJump`.

```bash
SB_SSH='ssh -p 23 -i ~/.config/foundry-bootstrap/storagebox_adm -o ProxyJump=foundry u580408-sub2@u580408-sub2.your-storagebox.de'
```

Prompt for the restic password:

```bash
printf 'Enter restic repo password: ' >&2
IFS= read -rs RESTIC_PASSWORD
echo
export RESTIC_PASSWORD
```

List snapshots:

```bash
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  snapshots
```

## Restore Foundry data

```bash
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  restore latest \
    --path /var/lib/foundryvtt-staging \
    --include /var/lib/foundryvtt-staging \
    --target /tmp/foundry-restore
```

Restored tree:

```text
/tmp/foundry-restore/var/lib/foundryvtt-staging
```

To restore to a live or freshly reinstalled server, copy the contents back to
`/var/lib/foundryvtt/` and fix ownership for the Foundry service user.

## Restore journals

The helper is the easiest path:

```bash
foundry-logs -u foundryvtt --since -1h
foundry-logs -p err -n 200
```

Manual restore:

```bash
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry-journal \
  restore latest \
    --path /var/log/journal \
    --target /tmp/foundry-journal-restore
```

## Restore VictoriaMetrics locally

Restore the whole VictoriaMetrics tree:

```bash
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  restore latest \
    --path /var/lib/victoriametrics \
    --include /var/lib/victoriametrics \
    --target /tmp/vm-restore
```

Run VictoriaMetrics against the restored data:

```bash
nix run nixpkgs#victoriametrics -- \
  -storageDataPath=/tmp/vm-restore/var/lib/victoriametrics \
  -httpListenAddr=127.0.0.1:8428 \
  -retentionPeriod=12
```

Query at a timestamp inside the restored window:

```bash
curl -sG 'http://127.0.0.1:8428/api/v1/query' \
  --data-urlencode 'query=up' \
  --data-urlencode 'time=2026-04-23T02:00:00Z' | jq .
```

## Restore PostgreSQL dumps

```bash
nix run nixpkgs#restic -- \
  -o rclone.program="$SB_SSH" \
  -r rclone:storagebox:foundry \
  restore latest \
    --path /var/backup/postgresql \
    --include /var/backup/postgresql \
    --target /tmp/foundry-pg-restore
```

Expected files:

```text
/tmp/foundry-pg-restore/var/backup/postgresql/all.sql.zstd
/tmp/foundry-pg-restore/var/backup/postgresql/all.prev.sql.zstd
```

Restore into a scratch cluster or disposable VM first:

```bash
zstd -dc /tmp/foundry-pg-restore/var/backup/postgresql/all.sql.zstd \
  | psql postgres
```

## Yearly restore drill

Run once a year:

1. Restore `/var/lib/foundryvtt-staging` and confirm worlds exist.
2. Run `foundry-logs --since -6h -n 50` and confirm fresh journal entries.
3. Restore `/var/lib/victoriametrics`, start VictoriaMetrics locally, and query
   for metric names plus an `up{job="node"}` sample inside the snapshot window.
4. Restore `/var/backup/postgresql` and confirm the dump decompresses.
5. Clean up local restore directories and unset `RESTIC_PASSWORD`.

Cleanup:

```bash
pkill -f 'storageDataPath=.*vm-restore'
rm -rf /tmp/foundry-restore /tmp/vm-restore /tmp/foundry-journal-restore /tmp/foundry-pg-restore
unset RESTIC_PASSWORD
```

If External Reachability was enabled for the drill, turn it off again.
