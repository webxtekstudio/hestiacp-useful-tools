# 🛠️ System Health Reporter (`system-report`)

*Sends you a beautiful, detailed HTML email report every morning showing your Server RAM, CPU usage, Disk Space, running services, and database health so you don't have to log into the terminal to check.*

---

## 🚀 1. How to Install (The Easy Way)
Instead of copying files manually, use the module installer to place the script and default config. To add the recommended schedule, run the repository root installer with `--setup-crons`.
```bash
cd /root/hestiacp-useful-tools/scripts/system-report
bash install.sh
```

## 📂 2. File Paths (Where is everything?)
If you want to look at the files, here is exactly where the installer places them:
* **The Executable Script:** `/usr/local/hestia/bin/v-system-report`
* **The Configuration File:** `/etc/hestiacp-system-report.conf`

## ⚙️ 3. How to Configure
By default, the script will check EVERYTHING (CPU, RAM, MySQL, Exim, PHP). If you want to disable checking a specific component:

1. Open `/etc/hestiacp-system-report.conf` in your editor (`nano /etc/hestiacp-system-report.conf`).
2. Turn off the variable you want. For example, to stop checking MySQL errors, change `CHECK_MYSQL="TRUE"` to `CHECK_MYSQL="FALSE"`.
3. Save the file.
4. The system reporter automatically reads this file the next time it runs.

## ⛔ 4. Crucial Rules (What NOT to do)
* **DO NOT** edit the `.sh` executable file directly. Your changes will be wiped on the next update! Always edit the `.conf` file in `/etc/`.
* **DO NOT** change the permissions of the executable. It must remain `755` (rwxr-xr-x) and owned by `root:root` to function correctly inside Hestia.
* **DO NOT** run this script manually as a normal user. It must be executed as `root` to read system-level metrics.

---

## 🔬 Advanced Architecture Notes (Geeks Only)

### Core Checks Performed
*   **Performance Metrics:** CPU Load Averages, RAM Consumption (Actual Use vs Cache), Disk Partitions.
*   **Hestia Services:** Validates operational state of `nginx`, `apache2`, `bind9`, `exim4`, `dovecot`, `mariadb`, etc.
*   **PHP-FPM:** Scans all pools for crashes or 503 errors.
*   **Databases:** Tracks MySQL slow query logs and crash errors in `syslog`.
*   **Network:** Queries email IP blacklisting databases to ensure your IP reputation is solid.
*   **Certificates:** Audits SSL Expiry dates for all domains.

### Security & Hardening Improvements
- Replaced fragile `pidof -x` script concurrency checking with robust atomic `flock` filesystem locks.
- PHP version detection in error log analysis is now fully dynamic (auto-adapts to PHP 8.2, 8.3, 8.5+, etc.) without needing hardcoded paths.
- Bound by `set -o pipefail` and `trap ERR` to email crashes.
- Removed duplicate `run_with_timeout()` functions to optimize memory footprint.
