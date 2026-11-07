# 🔄 Logrotate Optimizer (`v-optimize-logrotate`)

Upgrades the default HestiaCP Apache & Nginx log rotation from **weekly** to **daily**, with 14 days of compressed history.

---

## Why?

HestiaCP ships with `weekly rotate 4` for both Apache and Nginx logs. This is fine for low-traffic servers, but becomes a problem when:

- **Ad campaigns** (Facebook, Instagram, Google Ads) generate traffic with enormous referer URLs containing UTM parameters, `fbclid`, etc. A single log line can be **600+ bytes** instead of the usual ~200.
- **WordPress brute-force attacks** (wp-login.php, xmlrpc.php) inflate access logs with thousands of entries per day.
- **Multiple domains** on the same server multiply the problem.

**Real-world example:** A single domain running Instagram ads generated a **122 MB log file in 5 days** (vs 1 MB the previous week without ads). With weekly rotation, this keeps growing until Saturday's rotation.

### Before vs After

| Metric | Weekly (default) | Daily (optimized) |
|--------|-----------------|-------------------|
| Max single-file size | Can exceed 100 MB+ | Typically < 25 MB |
| Rotation frequency | Every Saturday | Every midnight |
| History kept | 4 weeks (uncompressed) | 14 days (compressed) |
| Disk usage pattern | Sawtooth (grows all week) | Flat (daily cleanup) |

---

## HestiaCP Compatibility ✅

This is **safe** and does not conflict with HestiaCP:

- HestiaCP only writes `/etc/logrotate.d/apache2` and `/etc/logrotate.d/nginx` during **initial installation**
- The daily auto-updater (`v-update-sys-hestia-all`) does **not** touch logrotate configs
- Domain rebuilds (`v-rebuild-web-domain`) do **not** touch logrotate configs
- HestiaCP upgrades last touched these files in **v1.1.0** (2021) for a minor permission fix — no overwrites since then
- HestiaCP has its own separate logrotate at `/etc/logrotate.d/hestia` for panel logs — this script does not touch it

---

## Installation

### Via the master installer
```bash
cd /root/hestiacp-useful-tools
bash install.sh
```

### Standalone
```bash
bash scripts/logrotate-optimize/install.sh
```

---

## Usage

```bash
# Preview what would change (safe, no modifications)
v-optimize-logrotate --dry-run

# Apply the optimization and force immediate rotation
v-optimize-logrotate

# Apply without forcing immediate rotation
v-optimize-logrotate --no-force
```

### Example output
```
╔══════════════════════════════════════════════════╗
║  v-optimize-logrotate — Log Rotation Optimizer   ║
╚══════════════════════════════════════════════════╝

=== Current State ===
  /etc/logrotate.d/apache2: weekly / rotate 4
  /etc/logrotate.d/nginx:   weekly / rotate 4
  /var/log total: 698 MB

  Top 5 Apache domain logs:
    114M  shop.example.com.log
    25M   travel.example.net.log.1
    15M   travel.example.net.log
    14M   services.example.org.log.1
    7.0M  services.example.org.log

=== Applying Changes ===
  -> [BACKUP] /etc/logrotate.d/apache2
  -> [BACKUP] /etc/logrotate.d/nginx
  -> [OK] Apache logrotate: daily / rotate 14
  -> [OK] Nginx logrotate:  daily / rotate 14

=== Forcing Immediate Rotation ===
  /var/log: 698 MB -> 414 MB (freed ~284 MB)

Done! Logs will now rotate daily, keeping 14 days of compressed history.
```

---

## What it changes

Only two files are modified (originals are backed up to `/var/backups/hestiacp-useful-tools/logrotate-optimize/`):

| File | Before | After |
|------|--------|-------|
| `/etc/logrotate.d/apache2` | `weekly` / `rotate 4` | `daily` / `rotate 14` |
| `/etc/logrotate.d/nginx` | `weekly` / `rotate 4` | `daily` / `rotate 14` |

Everything else (sharedscripts, postrotate hooks, create permissions) is preserved exactly as HestiaCP expects.

---

## Rollback

Backups are saved automatically outside `/etc/logrotate.d/` so `logrotate` never parses backup files. To revert:

```bash
# Find the backup
ls /var/backups/hestiacp-useful-tools/logrotate-optimize/

# Restore
cp /var/backups/hestiacp-useful-tools/logrotate-optimize/apache2.bak.YYYYMMDD-HHMMSS /etc/logrotate.d/apache2
cp /var/backups/hestiacp-useful-tools/logrotate-optimize/nginx.bak.YYYYMMDD-HHMMSS /etc/logrotate.d/nginx
```
