# HestiaCP Backup Core Patches (v2)

> **A seamless, native integration for HestiaCP backups.**
>
> This module upgrades HestiaCP's built-in classic backup system with organized storage, database repair, better logs, HTML notifications, and optional smart retention while keeping the panel UI and native Hestia commands working normally.

---

## Quick Start

### Step 1: Install

```bash
cd /root/hestiacp-useful-tools
bash install.sh
```

### Step 2: Configure Remote Backups (Optional)

If you want cloud backups, use Hestia's native command:

```bash
v-add-backup-host b2 YOUR_BUCKET KEY_ID APP_KEY
```

You can also use Hestia's native `ftp`, `sftp`, or `rclone` backup hosts.

---

## What This Adds

### 1. Cloud & Local Data Organization

Instead of dumping all backups into a massive flat `/backup/` folder, the native hook sorts backups into chronological folders:

```text
/backup/YYYY/MM_MONTH/username/
```

For Hestia Web Panel compatibility, the module keeps symlinks in the root `/backup/` directory pointing to the organized archive files. Downloads, restores, and deletes can still work from the panel.

For B2, the core patch stores and finds backups in organized cloud paths such as:

```text
YYYY/MM_MONTH/user/user.DATE.tar
```

B2 rotation also checks legacy paths like `user/user.DATE.tar`, so older backups are still visible to the cleanup logic.

### 2. Pre-Flight Database Auto-Repair

Before `mysqldump`, the patch runs `mysqlrepair --check --auto-repair` so corrupted indexes can be repaired before they break a backup.

### 3. Interactive Console Output

Manual SSH runs of `v-backup-users` stream live output through `tee`. Cron runs stay quiet and write to the normal Hestia backup log.

### 4. HTML Notifications & Monthly Logs

The notification hook replaces plain-text backup emails with multipart HTML reports and attaches the backup log where useful.

When B2 is configured, the global `v-backup-users` log is uploaded to the month folder:

```text
YYYY/MM_MONTH/backup-users-YYYY-MM-DD_HH-MM-SS.log
```

This is a global run log, so it sits in the month folder rather than beside one user's archive.

### 5. Optional Smart Retention (`v-prune-backups`)

HestiaCP classic `.tar` backups already support a simple per-package/per-user backup count (`BACKUPS`). HestiaCP also has Restic incremental backups with their own daily/weekly/monthly/yearly pruning.

`v-prune-backups` is for classic `.tar` backups when you want a more flexible GFS-style policy without switching to Restic:

```bash
KEEP_DAILY_FOR_DAYS=14
KEEP_WEEKLY_FOR_WEEKS=8
KEEP_MONTHLY_FOR_MONTHS=12
KEEP_YEARLY_FOR_YEARS=0
```

It is installed disabled and dry-run by default:

```bash
v-prune-backups --dry-run
v-prune-backups --apply
```

Supported backends today are `local`, `b2`, and `rclone`. The retention decision is calculated separately per user and per backend, so local copies and cloud copies do not affect each other. FTP/SFTP can still use Hestia's native count-based retention; provider-specific pruning adapters can be added later without changing the policy engine.

Configuration lives in:

```bash
/etc/hestiacp-backup-retention.conf
```

---

## Architecture Reference

The `install.sh` script applies idempotent patches to these files:

1. **`v-backup-user`** -> Runs database auto-repair, triggers folder organization, and replaces the basic notifier with the HTML notification hook.
2. **`v-backup-users`** -> Adds interactive terminal output and triggers the global backup report on loop exit.
3. **`backup.sh`** -> Updates Hestia's B2 upload, download, delete, and rotation paths.
4. **`v-delete-user-backup`** -> Makes deletion follow organized backup symlinks safely.
5. **`v-prune-backups`** -> Adds an optional dry-run-first retention command for classic `.tar` backups.

> **Note on updates:** If a HestiaCP update overwrites core files, re-run `bash install.sh` from this repository to re-apply the patches.
