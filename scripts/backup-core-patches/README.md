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

### 5. Native Optional Smart Retention (`v-prune-backups`)

HestiaCP classic `.tar` backups already support a simple per-package/per-user backup count (`BACKUPS`). HestiaCP also has Restic incremental backups with their own daily/weekly/monthly/yearly pruning.

`v-prune-backups` is for classic `.tar` backups when you want a more flexible GFS-style policy without switching to Restic:

```bash
KEEP_DAILY_FOR_DAYS=14
KEEP_WEEKLY_FOR_WEEKS=8
KEEP_MONTHLY_FOR_MONTHS=12
KEEP_YEARLY_FOR_YEARS=0
```

The installer patches `v-backup-users` with a native retention hook, the same way this module hooks notifications and global logs. It is still installed disabled and dry-run by default:

```bash
v-prune-backups --dry-run
v-prune-backups --apply
```

To let the native nightly backup batch run retention automatically, review the dry-run output first and then enable:

```bash
RETENTION_ENABLED="TRUE"
RETENTION_AUTO_RUN="TRUE"
RETENTION_DRY_RUN="TRUE"
```

Switch `RETENTION_DRY_RUN` to `FALSE` only when the log output matches your policy.

Supported backends today are `local`, `b2`, and `rclone`. The retention decision is calculated separately per user and per backend, so local copies and cloud copies do not affect each other. FTP/SFTP can still use Hestia's native count-based retention; provider-specific pruning adapters can be added later without changing the policy engine.

Configuration lives in:

```bash
/etc/hestiacp-backup-retention.conf
```

### 6. Remote Backup Size & Integrity Verification (`v-verify-backups`)

Log lines alone cannot catch a truncated upload or an accidentally deleted cloud archive. `v-verify-backups` cross-checks every non-suspended HestiaCP user's latest `backup.conf` entry against the live remote bucket (`b2 ls --long` / `rclone lsl`) or local `.tar` archive (`tar -tf`), verifying:

- The expected `.tar` archive actually exists on the remote backend
- The archive is non-empty (`>= 10 KB`) and matches HestiaCP's recorded `SIZE` within tolerance
- The archive age does not exceed `--max-age-days` (auto-detected as `8` days for weekly/daily `v-backup-users` schedules, or `35` days when `v-backup-users` is scheduled monthly)
- When HestiaCP's Restic incremental backups are enabled (`BACKUP_INCREMENTAL='yes'` in `hestia.conf` + `restic.conf`), every active user's Restic repository is also verified (`restic snapshots --latest 1 --json --no-lock` within `--max-restic-age-hours=36`)
- Newly created HestiaCP accounts without their first scheduled archive/snapshot yet are marked `PENDING_FIRST_BACKUP` / `PENDING_FIRST_RESTIC_SNAPSHOT` rather than failing verification

It runs automatically after `v-backup-users` and single-user B2 retries, writing a machine-readable report to `/var/log/hestia/backup-verify.status` (`status=B2_VERIFIED_OK` or `status=BACKUP_VERIFY_FAILED`), and can also be executed manually at any time:

```bash
v-verify-backups
```

### 7. Restic Incremental Backups, Offline Master Recovery Key & Hybrid Architecture (`v-restic-manager`)

HestiaCP's built-in Restic support (`v-add-backup-host-restic` / `v-backup-user-restic`) provides fast, block-deduplicated snapshots and granular single-file/database/mail restores inside the HestiaCP Web Panel (**Backups → Incremental Backups**), but out of the box it has four operational gaps:

1. **Single-Point-of-Failure Per-User Keys:** HestiaCP generates a random password per user in `/usr/local/hestia/data/users/<user>/restic.conf`. If the server disk dies and those files are lost, your cloud Restic repositories are permanently locked.
2. **Permissive Key & Staging Files:** `users/<user>/restic.conf` is written without `0600` clamping, and `/home/<user>/backup` (containing staged `pam/shadow` and SQL dumps) remains on local disk after each snapshot.
3. **New Accounts Skip Incremental Backups by Default:** Unless `BACKUPS_INCREMENTAL='yes'` is enabled on packages and `user.conf`, newly created users silently skip Restic snapshots.
4. **Hidden Cloud Version Bloat:** On Backblaze B2 (`Keep all versions` + `hard_delete = false`), daily `restic forget --prune` runs leave hidden pack files behind forever unless a custom B2 Lifecycle Rule expires hidden versions.

`v-restic-manager` closes all four gaps and pairs seamlessly with monthly Object-Locked `.tar` archives:

#### Recommended Two-Layer Hybrid Cloud Architecture (Backblaze B2 Example)

| Layer | Schedule | Bucket & Immutability | Retention & Purpose |
| :--- | :--- | :--- | :--- |
| **Layer 1 — Daily Restic (`v-restic-manager --run-daily`)** | `30 2 * * *` (Daily) | Dedicated B2 bucket (`Object Lock: Disabled`, `rclone` `hard_delete = false`, B2 Custom Lifecycle: `daysFromHidingToDeleting = 14`, `unfinishedLargeFiles = 3`) | `7 daily + 4 weekly + 3 monthly` (~90 days block-deduplicated history for ~1.2× single-backup storage + 1-click Web Panel granular restore) |
| **Layer 2 — Monthly `.tar` (`v-backup-users`)** | `30 3 1 * *` (1st of month) | Dedicated B2 bucket (**`Object Lock: Default 175 Days`**, B2 Custom Lifecycle: `daysFromUploadingToHiding = 180`, `daysFromHidingToDeleting = 1`) | Standalone immutable WORM `.tar` archives immune even to root/API sabotage, auto-expiring after 6 months |

#### Step-by-Step Restic + Master Key Setup

1. **Configure `rclone` (`0600 /root/.config/rclone/rclone.conf`) with soft-delete protection:**
   ```ini
   [b2restic]
   type = b2
   account = YOUR_SCOPED_B2_KEY_ID
   key = YOUR_SCOPED_B2_APPLICATION_KEY
   hard_delete = false
   ```
2. **Register the Restic host in HestiaCP (`7 daily, 4 weekly, 3 monthly`):**
   ```bash
   v-add-backup-host-restic 'rclone:b2restic:YOUR_RESTIC_BUCKET' -1 7 4 3 -1
   ```
3. **Generate & save your offline Master Recovery Key (`0400 /etc/hestiacp-restic-master.key`):**
   ```bash
   v-restic-manager --init-master-key --print
   # Save the printed 48-character key in Bitwarden / 1Password!
   ```
4. **Run the initial snapshot & enroll the Master Key across all active users:**
   ```bash
   v-restic-manager --run-daily
   v-restic-manager --status
   ```
   > Every future user created in HestiaCP automatically receives `BACKUPS_INCREMENTAL='yes'`, `0600` on `restic.conf`, `/home/<user>/backup` post-snapshot cleanup, and automatic Master Recovery Key enrollment on their very first `02:30` daily run!
5. **Enable the `02:30` daily cron (automatic with `bash install.sh --setup-crons` once Restic is enabled):**
   ```cron
   30 2 * * * root /usr/local/hestia/bin/v-restic-manager --run-daily >> /var/log/hestia/restic-daily.log 2>&1
   ```

#### Exporting a Restic Snapshot to a Native HestiaCP `.tar` Archive (`--export-tar` / `--dump-tar`)

Because `v-backup-user-config` already stages `hestia/`, `pam/`, `db/`, `dns/`, `cron/`, `web/*/conf|hestia|template`, `mail/*/conf|hestia`, and `backup.conf` inside `/home/<user>/backup` before every Restic snapshot, `v-restic-manager --export-tar` can reconstruct a **100% native `v-restore-user`-compatible `/backup/<user>.<date>.tar` archive** from any Restic snapshot on Backblaze B2 — and automatically register it in `data/users/<user>/backup.conf` (`TYPE='local'`) so it appears in the HestiaCP **BACKUP** tab for instant browser **Download** or **Restore**:

```bash
# Reconstruct a full HestiaCP .tar archive in /backup/ and register it in the Web Panel:
v-restic-manager --export-tar <username> [snapshot_id|latest]

# Reconstruct a full HestiaCP .tar archive at a custom path without registering:
v-restic-manager --export-tar <username> latest /tmp/<username>.tar --no-register

# Or stream a raw tar directly from Restic (zero local staging disk usage):
v-restic-manager --dump-tar <username> latest /tmp/<username>-raw.tar [/home/<username>/subpath]
```

#### Bare-Metal Emergency Restore (Total Server Loss — Using Only the Master Recovery Key)

Even if the original HestiaCP server and all `/usr/local/hestia/data/users/*/restic.conf` files are completely destroyed, any user's Restic repository can be unlocked on a fresh HestiaCP server using only your offline Master Recovery Key (`/etc/hestiacp-restic-master.key`) and converted directly into a native HestiaCP `.tar` archive for `v-restore-user`:

```bash
# Option A — Reconstruct a native HestiaCP .tar archive using the Master Recovery Key and restore:
v-restic-manager --export-tar <username> latest /backup/<username>.latest.tar --no-register
v-restore-user <username> <username>.latest.tar

# Option B — Direct Restic CLI access:
export RESTIC_REPOSITORY="rclone:b2restic:YOUR_RESTIC_BUCKET/<username>"
restic --password-file /path/to/master.key snapshots
restic --password-file /path/to/master.key restore latest --target /restore/<username>
```

---

## Architecture Reference

The `install.sh` script applies idempotent patches to these files:

1. **`v-backup-user`** -> Runs database auto-repair, triggers folder organization, and replaces the basic notifier with the HTML notification hook.
2. **`v-backup-users`** -> Adds interactive terminal output, triggers the global backup report, and runs the optional retention hook on loop exit.
3. **`backup.sh`** -> Updates Hestia's B2 upload (with 3-attempt exponential-backoff retry and temp cleanup on failure), download, delete, and rotation paths.
4. **`v-delete-user-backup`** -> Makes deletion follow organized backup symlinks safely.
5. **`v-prune-backups`** -> Adds the dry-run-first retention engine used by the native `v-backup-users` hook.
6. **`v-verify-backups`** -> Verifies remote (`b2` / `rclone`) and local `.tar` archives against `backup.conf` plus Restic incremental snapshots (`<= 36h`) after batch runs and single-user B2 retries.
7. **`v-restic-manager`** -> Manages offline Master Recovery Key generation (`--init-master-key`), dual-key enrollment (`--enroll`), `0600` `restic.conf` hardening, `/home/<user>/backup` cleanup, and failure-only alert daily runs (`--run-daily`).
8. **APT Auto-Healer (`/etc/apt/apt.conf.d/99hestia-custom-patches`)** -> Automatically re-runs `install.sh` via `DPkg::Post-Invoke` whenever `apt`/`dpkg` updates HestiaCP packages, ensuring custom core patches and fresh `.original` backups are preserved across every HestiaCP release without manual intervention.
