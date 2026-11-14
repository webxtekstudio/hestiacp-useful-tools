# HestiaCP Backup & Restore Guide

## 1. Current Backup Architecture

This server does **not** use the old `v-backup-users-custom` wrapper as the default assumption.

The current architecture supports both classic `.tar` backups and hybrid Restic + `.tar` deployments:
- native Hestia `v-backup-users` (weekly or monthly `.tar` archives)
- optionally patched by `backup-core-patches` (`YYYY/MM_MONTH/<user>/` organization, MariaDB pre-repair, HTML batch reports)
- optional daily incremental Restic snapshots via native `v-backup-user-restic` orchestrated by `v-restic-manager` (`--init-master-key`, `--enroll`, `--run-daily`, `--status`)
- optional remote backup hosts via native Hestia backup-host support (`b2`, `rclone`, `ftp`, `sftp`) and `v-add-backup-host-restic`
- optional classic retention via `v-prune-backups`
- post-backup remote/local `.tar` AND Restic snapshot verification via `v-verify-backups`

This means you must verify the live machine before concluding how backups are stored or whether the weekly/monthly `.tar` or daily Restic schedule was missed.

## 2. Verified Paths

| Component | Path |
| :--- | :--- |
| **Native Batch Command** | `/usr/local/hestia/bin/v-backup-users` |
| **Single User Backup** | `/usr/local/hestia/bin/v-backup-user` |
| **Restore Command** | `/usr/local/hestia/bin/v-restore-user` |
| **Backup Host Listing** | `/usr/local/hestia/bin/v-list-backup-host TYPE` (TYPE = `b2`, `sftp`, `ftp`) |
| **Local Root** | `/backup` (may be empty when using remote-only backends — this is normal) |
| **Panel/System Backup Log** | `/var/log/hestia/backup.log` |
| **Global Batch Log** | `/usr/local/hestia/log/backup.log` |
| **Organization Hook** | `/usr/local/hestia/bin/v-backup-user-hook` |
| **Global Notify Hook** | `/usr/local/hestia/bin/v-backup-users-notify-hook` |
| **Retention Command** | `/usr/local/hestia/bin/v-prune-backups` |
| **Retention Config** | `/etc/hestiacp-backup-retention.conf` |
| **Restic & Master Key Manager** | `/usr/local/hestia/bin/v-restic-manager` |
| **Restic Host Config** | `/usr/local/hestia/conf/restic.conf` (`0660 root:root`) |
| **Restic Master Recovery Key** | `/etc/hestiacp-restic-master.key` (`0400 root:root` — NEVER read or expose in logs/prompts) |
| **Restic Per-User Keys** | `/usr/local/hestia/data/users/<user>/restic.conf` (`0600 root:root` — NEVER expose) |
| **Restic Daily Cron Log** | `/var/log/hestia/restic-daily.log` |
| **Backup Verifier** | `/usr/local/hestia/bin/v-verify-backups` |
| **Backup Verify Status** | `/var/log/hestia/backup-verify.status` |
| **B2 Config** | `/usr/local/hestia/conf/b2.backup.conf` |
| **APT Persistence Hook** | `/etc/apt/apt.conf.d/99hestia-custom-patches` |

## 3. What `backup-core-patches` Changes

When installed, the patch layer keeps the native Hestia workflow but extends it:

- local archives may be moved into `/backup/YYYY/MM_MONTH/USER/`
- Hestia-compatible symlinks can remain at the root `/backup/`
- the global backup batch log may be uploaded to remote storage
- single-user retries (`v-backup-user <user>`) append `Upload to B2: ... (SINGLE-USER RETRY: <user>)` to `/var/log/hestia/backup.log` so automated monitors can see recovered uploads
- `v-verify-backups` runs automatically after `v-backup-users` and single-user B2 retries, cross-checking every active user's latest `backup.conf` entry against the live remote bucket (`b2 ls --long` / `rclone lsl`) or local `.tar` archive (`tar -tf`) and writing `/var/log/hestia/backup-verify.status` (newly created accounts `<= 8` days old without a backup yet report `PENDING_FIRST_BACKUP`)
- retention can be applied per backend without replacing the native backup batch
- remote paths may be organized by year and month
- `/etc/apt/apt.conf.d/99hestia-custom-patches` (`DPkg::Post-Invoke`) automatically re-applies core patches if an APT upgrade of the `hestia` package overwrites `/usr/local/hestia/bin/v-backup-user` or `/usr/local/hestia/func/backup.sh`
- Restic read-only listing (`v-list-user-backups-restic`, `v-list-user-backup-restic`, `v-list-user-files-restic`) passes `--no-lock`, caches JSON snapshot lists briefly under `/run/hestia-restic-cache/<user>.json` (120s TTL, invalidated on snapshot creation/deletion, bypassed with `?refresh=1` or `RESTIC_NO_CACHE=1`), `/list/backup/*` views filter instantaneously via `/usr/local/hestia/web/js/custom_scripts/backup-instant-search.js` with `25 / 50 / 100 / All` client-side pagination when >25 items, and single-row snapshot deletion routes through `/delete/backup/incremental/` -> hardened `v-delete-user-backup-restic` (avoiding upstream `/backup/tmp.*` leaks and verifying `restic forget` output).

Implication:
- a valid remote upload log plus `status=B2_VERIFIED_OK` (or `LOCAL_VERIFIED_OK`) in `/var/log/hestia/backup-verify.status` confirms archive existence, byte size, and freshness
- absence of a flat `/backup/user.DATE.tar` file does not mean the backup failed

## 4. Operational Verification Checklist

When the user asks whether backups are healthy, run this set first:

```bash
sudo -n date -u +"%Y-%m-%d %H:%M UTC"
sudo -n grep -nEi "backup|v-backup" /var/spool/cron/crontabs/hestiaweb
sudo -n /usr/local/hestia/bin/v-list-backup-host b2 2>/dev/null || sudo -n /usr/local/hestia/bin/v-list-backup-host sftp 2>/dev/null || echo "No remote host configured"
sudo -n ls -l /usr/local/hestia/bin/v-backup-user-hook /usr/local/hestia/bin/v-backup-users-notify-hook /usr/local/hestia/bin/v-prune-backups /usr/local/hestia/bin/v-verify-backups 2>/dev/null
sudo -n /usr/local/hestia/bin/v-verify-backups 2>/dev/null || sudo -n cat /var/log/hestia/backup-verify.status 2>/dev/null
sudo -n tail -n 60 /usr/local/hestia/log/backup.log 2>/dev/null
# If backup.log is empty (after logrotate), check the rotated log for recent evidence:
sudo -n grep -E "SUMMARY|Upload to B2|Upload global|Size:|Runtime:" /usr/local/hestia/log/backup.log.1 2>/dev/null | tail -30
sudo -n tail -n 60 /var/log/hestia/backup.log 2>/dev/null
```

> **Note:** `v-list-backup-host` requires the TYPE argument (`b2`, `sftp`, `ftp`). Without it, the command returns "Usage..." which is NOT an error — it means the argument was missing.

Interpretation rules:
- use exact absolute dates in the answer
- inspect `tar_schedule=` and `restic_enabled=` in `/var/log/hestia/backup-verify.status` before judging backup age:
  - when `tar_schedule=monthly` (`30 03 1 * *`), `.tar` archives are healthy up to `35` days old (`tar_max_age_days=35`) — do NOT falsely flag a 10–30 day old monthly `.tar` archive as a missed weekly backup!
  - when `tar_schedule=weekly`, `.tar` archives are healthy up to `8` days old
  - when `restic_enabled=yes`, daily Restic snapshots must be `<= 36` hours old (`restic_verified_users == active_users` and `restic_failed_users=0`)
- Evaluate TAR and Restic freshness separately: a recent TAR upload must not conceal an old daily Restic snapshot.
- `B2_VERIFIED_OK` / `BACKUP_VERIFIED_OK` establishes metadata checks only. Read `checked_at`, `verification_scope`, `data_integrity` and `restore_test`; an old success is not current evidence and does not prove a working restore.

### Restic & Secondary Recovery Password Operations (`v-restic-manager`)

- Check Restic configuration, Master Key presence, and per-user repository status (safe — never prints keys):
  ```bash
  sudo -n /usr/local/hestia/bin/v-restic-manager --status
  ```
- Run daily Restic incremental snapshots, auto-enroll the Master Recovery Key on any new user, clean `/home/<user>/backup` staging dumps, and refresh `backup-verify.status`:
  ```bash
  sudo -n /usr/local/hestia/bin/v-restic-manager --run-daily
  ```
- Granular or full Restic restore (confirm with the user first — restores overwrite live data):
  ```bash
  sudo -n /usr/local/hestia/bin/v-list-user-backups-restic <user>
  sudo -n /usr/local/hestia/bin/v-restore-user-restic <user> <snapshot_id>
  sudo -n /usr/local/hestia/bin/v-restore-file-restic <user> <snapshot_id> home/<user>/web/<domain>/public_html/index.html
  ```
- Export a Restic snapshot to a native `v-restore-user`-compatible HestiaCP `.tar` archive (or stream raw tar):
  ```bash
  sudo -n /usr/local/hestia/bin/v-restic-manager --export-tar <user> [snapshot_id|latest]
  sudo -n /usr/local/hestia/bin/v-restic-manager --dump-tar <user> latest /tmp/<user>-raw.tar
  ```

### Recovery password and provider security

The toolkit keeps a secondary recovery password on the server at `/etc/hestiacp-restic-master.key` (0400) so future repositories can be enrolled automatically. Keep an independently protected offline copy and separately recoverable provider credentials. Do not read or print their contents into AI conversations or logs.

`hard_delete=false` is rclone behavior, not an immutable retention policy. A credential with `deleteFiles` may permanently remove unprotected versions. Check actual provider capabilities and Object Lock mode/retention; a 14-day hidden-version lifecycle is not a guaranteed defense against a stolen deletion-capable key.

### Export behavior

Exports use per-user locks and temporary files beside the destination. They publish the final TAR only after successful construction and validation. A concurrent web request queues while the user export is running. Existing invalid cached archives are rebuilt. Restored directories used as packing roots must remain inside the isolated staging tree; symlinks cannot redirect root to live files outside that snapshot. Local exports are retained until explicitly removed; there is no automatic 24-hour deletion job in this helper.

## 5. Manual Operations

### Run full backup batch

```bash
sudo -n /usr/local/hestia/bin/v-backup-users
```

### Run single-user backup

```bash
sudo -n /usr/local/hestia/bin/v-backup-user admin
```

### List remote backup host

```bash
sudo -n /usr/local/hestia/bin/v-list-backup-host b2
# or: v-list-backup-host sftp / v-list-backup-host ftp
```

> **Note:** The TYPE argument is required. Without it, the command shows a usage message, not an error.

## 6. Restore

Restores are destructive. Confirm with the user first.

### Full restore

```bash
sudo -n /usr/local/hestia/bin/v-restore-user admin admin.2024-03-15.tar
```

### Partial restore

```bash
sudo -n /usr/local/hestia/bin/v-restore-user admin admin.tar no no no yes no no no
```

## 7. Troubleshooting

### Check recent backup evidence

```bash
sudo -n tail -n 80 /usr/local/hestia/log/backup.log 2>/dev/null
# If empty after logrotate, check the rotated log:
sudo -n grep -E "SUMMARY|Upload to B2|Upload global|Size:|Runtime:|Error|FAIL" /usr/local/hestia/log/backup.log.1 2>/dev/null | tail -40
sudo -n tail -n 80 /var/log/hestia/backup.log 2>/dev/null
```

### Tar errors and upload evidence

Do not classify an archive as restorable merely because an upload log exists. Record the archive command exit status and full relevant diagnostics, then verify expected contents and restoreability in an isolated recovery check. GNU tar distinguishes successful completion, changed files and fatal errors; a changed-file archive may be inconsistent. Unresolved errors must stay unresolved in the health report. [GNU tar exit status reference](https://www.gnu.org/software/tar/manual/html_section/Synopsis.html).

### Empty `/backup/` directory

When `BACKUP_SYSTEM` is set to a remote-only backend (e.g., `b2` without `local`), the post-backup hook uploads the tarball and then cleans up the local copy. The `/backup/` directory being empty is **normal and expected** — it does NOT mean backups have failed.

### Single-user retry & Backblaze B2 CLI v4 syntax

- If a single user's B2 upload fails transiently during the weekly batch, retry only that user with:
  ```bash
  sudo -n /usr/local/hestia/bin/v-backup-user <user>
  ```
- When `backup-core-patches` (`hestia-custom-b2-v5.4-verify`) is active, standalone `v-backup-user <user>` runs append `Upload to B2: ... (SINGLE-USER RETRY: <user>)` to `/var/log/hestia/backup.log` and refresh `/var/log/hestia/backup-verify.status` via `v-verify-backups`. If an earlier upload error for `<user>` is marked `REMEDIATED:` or followed by a newer `Upload to B2: .../<user>/...` (`SINGLE-USER RETRY: <user>`) and `v-verify-backups` reports `OK <user>`, treat that user's backup as recovered/OK.
- Backblaze B2 CLI v4 uses `B2_APPLICATION_KEY_ID` / `B2_APPLICATION_KEY` environment variables with `b2 file upload <bucket> <local_file> <remote_path>` and `b2 ls b2://<bucket>/<prefix>`. Never recommend deprecated B2 CLI v3 subcommands (`b2 authorize-account` or `b2 upload-file`).

### Check whether the batch is stuck

```bash
sudo -n /usr/local/hestia/bin/v-list-sys-queue
sudo -n ps aux | grep "v-backup" | grep -v grep
```

### Clear a stale lock only if you already proved it is stuck

```bash
sudo -n rm -f /usr/local/hestia/data/queue/backup.pipe
```

<a id="recovery-drill"></a>
## Recovery drill

1. Use a disposable Hestia installation or isolated recovery VM with no live customer accounts. Disable outbound mail and scheduled application jobs in the recovery environment. Do not run restore commands against the production account as a test.
2. Recover provider access and the secondary recovery password from their independent storage. Test an explicit older snapshot ID, not only `latest`. Do not print either credential.
3. Check repository structure with `restic check`; use `check --read-data` or a rotating `--read-data-subset` policy when a data read is intended. These reads consume provider bandwidth and time.
4. Run `v-restic-manager --export-tar <user> <snapshot> <output.tar> --no-register` on the recovery host, using the recovered password file and repository configuration. Inspect the TAR and its internal archives.
5. Restore it with the recovery installation's `v-restore-user`. Verify file hashes, database import and queries, HTTP responses using local host mapping, mailbox contents, DNS/configuration and cron definitions. Validate those components before enabling jobs or outbound mail.
6. Record the source revision, snapshot ID, recovery-host version, checked components, elapsed time and uncovered components. Archive listing, gzip CRC tests and an HTTP 200 alone are not a complete recovery result.

References: [Restic integrity checks](https://restic.readthedocs.io/en/stable/045_working_with_repos.html#checking-integrity-and-consistency), [rclone B2 deletion behavior](https://rclone.org/b2/#b2-hard-delete), [Backblaze key capabilities](https://www.backblaze.com/docs/cloud-storage-application-key-capabilities).
