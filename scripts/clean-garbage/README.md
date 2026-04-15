# 🛠️ System Garbage Cleaner (`clean-garbage`)

*A simple housekeeper script. It safely deletes old unneeded system logs, temporary server files, and frozen spam emails to free up large amounts of disk space on your server.*

---

## 🚀 1. How to Install (The Easy Way)
Instead of copying files manually, use our automated installer which handles permissions and `cron` jobs automatically:
```bash
cd /root/hestiacp-useful-tools/scripts/clean-garbage
bash install.sh
```

## 📂 2. File Paths (Where is everything?)
If you want to look at the files, here is exactly where the installer places them:
* **The Executable Script:** `/usr/local/hestia/bin/v-clean-garbage`
* **The Configuration File:** `/etc/hestiacp-clean-garbage.conf`

## ⚙️ 3. How to Configure
By default, the script will safely clean logs older than 7 days. If you want to change this behavior:

1. Open `/etc/hestiacp-clean-garbage.conf` in your editor (e.g. `nano /etc/hestiacp-clean-garbage.conf`).
2. Change the variables you want. For example, to keep logs for 30 days instead of 7, change `JOURNALCTL_RETENTION_DAYS=7` to `JOURNALCTL_RETENTION_DAYS=30`.
3. Save the file. The cleanup script will automatically read this file the next time it runs!

## ⛔ 4. Crucial Rules (What NOT to do)
* **DO NOT** edit the `.sh` executable file directly. Your changes will be wiped on the next update! Always edit the `.conf` file in `/etc/`.
* **DO NOT** change the permissions of the executable. It must remain `755` (rwxr-xr-x) and owned by `root:root` to function correctly inside Hestia.
* **DO NOT** run this script manually as a normal user. It must be executed as `root` or it won't have permission to clean system logs.

---

## 🔬 Advanced Architecture Notes (Geeks Only)

### Features under the hood
*   **System Logs:** Cleans old `journalctl` logs, rotated logs, and orphaned temp files.
*   **Service Logs:** Truncates and safely rotates logs for Nginx, Apache, Exim, Dovecot, MySQL, PHP-FPM without restarting the services.
*   **Mail Queue:** Eradicates old frozen Exim emails and spam.
*   **Trash:** Empties user trash bins older than configured days via Hestia CLI.
*   **Database:** Purges MySQL slow query logs natively.
*   **Smart Safety:** Employs `lsof` to ensure files aren't locked before deleting them.

### Concurrency & Crash Safety
- Written with `set -o pipefail` for safer pipe error handling.
- Uses atomic `flock` filesystem locks instead of fragile `pidof` to prevent double-execution.
- Injects a `trap ERR` listener that guarantees an administrative email alert if the cleanup process violently crashes mid-execution.
