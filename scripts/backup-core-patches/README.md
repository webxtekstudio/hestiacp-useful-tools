# HestiaCP Backup Core Patches (v2)

> **A seamless, 100% native integration for HestiaCP backups.** 
> 
> This module upgrades HestiaCP's built-in backup system into an enterprise-grade orchestrator. It introduces **4 Major Pillars of functionality** by surgically patching Hestia's native core scripts, ensuring zero friction with the panel UI or cloud cron jobs.

---

## 🚀 Quick Start (1 minute)

### Step 1: Install

```bash
cd /root/hestiacp-useful-tools
bash install.sh
```

### Step 2: Configure Backblaze B2 (Optional but Recommended)

If you haven't enabled cloud backups yet, simply add your B2 credentials using Hestia's native command:

```bash
v-add-backup-host b2 YOUR_BUCKET KEY_ID APP_KEY
```

> **That's it!** There are no complex configuration files, custom cron jobs, or old wrapper scripts. You run backups natively via the panel or via `v-backup-users`.

---

## 🌟 The 4 Pillars of the Overhaul

### 1. Cloud & Local Data Organization
Instead of dumping all backups into a massive, flat `/backup/` folder, our native hook intelligently sorts your backups into **chronological folders** both locally and on the Cloud (B2):
`/backup/YYYY/MM_MONTH/username/`

**UI Transparency:** Our system handles HestiaCP's UI logic by creating hidden **symlinks** in the root `/backup/` directory pointing to the real organized files. You can still comfortably Download, Restore, and Delete backups directly from the Web Interface without modifying Hestia's PHP.

### 2. Pre-Flight Database Auto-Repair
Corrupted database tables (like a crashed `wp_options`) are the #1 cause of silent backup failures. 
Our patch injects a surgical pre-flight check right before the `mysqldump` begins using the official `mysqlrepair --check --auto-repair` utility. 
If a table is healthy, it skips in milliseconds. If it's corrupted, it repairs the table indexes on-the-fly and guarantees the database is extracted perfectly instead of failing halfway.

### 3. Interactive Console Output
When managing backups via command line, waiting blindly is frustrating. 
Our patch introduces `tty` detection. If you manually run `v-backup-users` via SSH, it intelligently activates `--interactive` mode, printing real-time `grep`-like process logs directly to your screen natively. If it detects it's being executed by the system's silent nightly `cron`, it instantly reverts to blind mode to keep system logs clean.

### 4. Enterprise HTML Notifications & Logging
We replace the archaic plain-text Hestia notifications with modern, beautiful AWS-grade Multipart MIME HTML emails:
* **Individual Accounts (`v-backup-user admin yes`):** Sends a dark-mode status panel to the account owner along with the system `.log` file securely embedded as a physical MIME attachment. The `yes` switch forcibly triggers this HTML notification block even on success.
* **Global Master Report:** A hook intercepts the end of the `v-backup-users` master cron loop and fires a compiled, summarized Multi-User Server Report directly to the System Admin, displaying total sizes and statuses for all accounts packaged that night.

---

## 🛠 Architecture Reference

The `install.sh` script applies idempotent patches to these core files:

1. **`v-backup-user`** -> Patched to run Database Auto-Repair, trigger the Folder Organization hook, and replace the basic email notifier with our Multipart MIME Hook.
2. **`v-backup-users`** -> Patched to detect TTY outputs for interactive logs and trigger the Global Master Email Hook on loop exit.
3. **`backup.sh`** -> Modifies Hestia's native `b2_backup()`, `b2_download()`, and `b2_delete()` to read from and write to organized cloud paths.
4. **`v-delete-user-backup`** -> Modifies the deletion logic to intelligently follow our symlinks.

> **Note on Updates:** If a HestiaCP system update over-writes core files, simply re-run `bash install.sh` from this repository to re-apply the patches effortlessly.
