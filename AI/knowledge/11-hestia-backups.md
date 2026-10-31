# HestiaCP Backup & Restore Guide

## 1. Current Backup Architecture

This server does **not** use the old `v-backup-users-custom` wrapper as the default assumption.

The current architecture is:
- native Hestia `v-backup-users`
- optionally patched by `backup-core-patches`
- optional remote backup hosts via native Hestia backup-host support (`b2`, `rclone`, `ftp`, `sftp`)
- optional classic retention via `v-prune-backups`

This means you must verify the live machine before concluding how backups are stored or whether the weekly schedule was missed.

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
| **B2 Config** | `/usr/local/hestia/conf/b2.backup.conf` |

## 3. What `backup-core-patches` Changes

When installed, the patch layer keeps the native Hestia workflow but extends it:

- local archives may be moved into `/backup/YYYY/MM_MONTH/USER/`
- Hestia-compatible symlinks can remain at the root `/backup/`
- the global backup batch log may be uploaded to remote storage
- retention can be applied per backend without replacing the native backup batch
- remote paths may be organized by year and month

Implication:
- a valid remote upload log is real backup evidence
- absence of a flat `/backup/user.DATE.tar` file does not mean the backup failed

## 4. Operational Verification Checklist

When the user asks whether backups are healthy, run this set first:

```bash
sudo -n date -u +"%Y-%m-%d %H:%M UTC"
sudo -n grep -nEi "backup|v-backup" /var/spool/cron/crontabs/hestiaweb
sudo -n /usr/local/hestia/bin/v-list-backup-host b2 2>/dev/null || sudo -n /usr/local/hestia/bin/v-list-backup-host sftp 2>/dev/null || echo "No remote host configured"
sudo -n ls -l /usr/local/hestia/bin/v-backup-user-hook /usr/local/hestia/bin/v-backup-users-notify-hook /usr/local/hestia/bin/v-prune-backups 2>/dev/null
sudo -n tail -n 60 /usr/local/hestia/log/backup.log 2>/dev/null
# If backup.log is empty (after logrotate), check the rotated log for recent evidence:
sudo -n grep -E "SUMMARY|Upload to B2|Upload global|Size:|Runtime:" /usr/local/hestia/log/backup.log.1 2>/dev/null | tail -30
sudo -n tail -n 60 /var/log/hestia/backup.log 2>/dev/null
```

> **Note:** `v-list-backup-host` requires the TYPE argument (`b2`, `sftp`, `ftp`). Without it, the command returns "Usage..." which is NOT an error — it means the argument was missing.

Interpretation rules:
- use exact absolute dates in the answer
- if the last successful evidence is from the previous Sunday and the next Sunday has not arrived yet, the weekly schedule is not missed
- only call the weekly backup missed when the latest successful evidence is older than 8 days
- remote upload events count as successful backup evidence

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

### Check whether the batch is stuck

```bash
sudo -n /usr/local/hestia/bin/v-list-sys-queue
sudo -n ps aux | grep "v-backup" | grep -v grep
```

### Clear a stale lock only if you already proved it is stuck

```bash
sudo -n rm -f /usr/local/hestia/data/queue/backup.pipe
```
