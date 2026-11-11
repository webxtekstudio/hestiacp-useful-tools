# HestiaCP Useful Tools Collection

A curated collection of production-grade scripts, optimization guides, and **platform-agnostic AI prompt blueprints** for HestiaCP + Debian/Ubuntu servers.

Built and battle-tested for real production environments. A contribution to the HestiaCP community — thank you to the team for your continuous work!

---

## 📂 Repository Structure

### 1. 📖 Guides & Optimizations

Step-by-step guides to optimize your server infrastructure:

- **[PHP-FPM Optimization Guide](php_optimize/php_optimization_guide.md):** Calculate RAM limits and choose between `ondemand`, `dynamic`, and `static` PHP modes based on server size and traffic.
- **[MariaDB Optimization Guide](mariadb_optimize/mariadb_optimization_guide.md):** Configure `innodb_buffer_pool_size`, `innodb_log_file_size`, and `table_open_cache` for MariaDB 10.11 / 11.8 LTS to dramatically improve database performance and reduce CPU load.
- **[SWAP Setup Guide](swap_setup/swap_setup_guide.md):** 1-click script to configure SWAP memory and `vm.swappiness=10`, essential for low-RAM environments (1GB/2GB VPS).

---

### 2. 🤖 AI Integration Blueprints (`/AI`)

**Platform-agnostic** system prompt blueprints and knowledge bases to integrate LLMs with your HestiaCP server. No dependency on Dify, n8n, or any specific platform — inject these prompts directly into any LLM provider (OpenAI, Anthropic, Google, OpenRouter, etc.) via `systemPrompt`.

#### Cognitive Architecture (April 2026)

The AI prompts in this repository follow a **3-module Cognitive OS** structure inspired by the [Nuwa.skill](https://github.com/alchaincyf/zhangxuefeng-skill) methodology and the [Agent Skills](https://github.com/anthropics/skills) standard:

```
<decision_heuristics>  — Operational reasoning rules
<expression_dna>       — Tone, syntax, and output format
<internal_tensions>    — Ethical and technical constraints to force critical thinking
```

This structure shifts LLM agents from generic "helpful assistants" to **specialized cognitive profiles** with deterministic, institutional-grade behavior.

#### Available Prompts ([`/AI/DevOps-AI-Prompts`](AI/DevOps-AI-Prompts/))

- **[DevOps Agent](AI/DevOps-AI-Prompts/DevOps-Agent-Prompt.md):** A senior DevOps engineer persona with SSH root access. Enforces "look before you leap" heuristics, mandatory pre-flight checks (`nginx -t` before restart), and balances root power against operational safety. Responds in the user's language.
- **[System Monitor](AI/DevOps-AI-Prompts/System-Monitor-Prompt.md):** A cold, clinical health-check agent. Runs scheduled server audits, grades severity objectively (HEALTHY / DEGRADED / CRITICAL), and suppresses alerts when no human action is required.

#### Knowledge Base ([`/AI/knowledge`](AI/knowledge/))

Curated Markdown files covering HestiaCP CLI commands, PHP-FPM tuning, Exim troubleshooting, Nginx configuration, and more. Designed to be used as a RAG knowledge base for any LLM agent.

---

### 3. ⚙️ Custom Scripts (`/scripts`)

Automation and maintenance scripts to enhance HestiaCP's default capabilities.

| Module & Dedicated Guide | CLI Command | Default Cron Schedule | Primary Purpose |
| :--- | :--- | :--- | :--- |
| **[System Cleanup Guide](scripts/clean-garbage/README.md)** | `v-clean-garbage` | `30 4 * * 0` (Sun 04:30) | Cleans journald, rotated logs, PHP sessions, temp files, mail queue & spam |
| **[Backup Core Patches Guide](scripts/backup-core-patches/README.md)** | `v-backup-users` / `v-restic-manager` / `v-prune-backups` / `v-verify-backups` | `10 5 * * *` (Hestia native) + `30 2 * * *` (Restic) | `YYYY/MM_MONTH/user` layout, DB auto-repair, Dark-Mode HTML emails, Restic Master Key & daily runner, B2 retry, retention & verification |
| **[GitHub Mirror Guide](scripts/github-mirror/README.md)** | `v-github-mirror` | `0 */12 * * *` (every 12h + Sun 06:00) | Zero-trust pull-only mirror of private/public Git repos into `/home/<user>/git/<repo>` (or `private/`) |
| **[Exim Limit & Anti-Spoof Guide](scripts/exim-limit/README.md)** | `v-add-exim-limit` / `monitor_large_emails.py` | `0 * * * *` (hourly monitor) | Enforces 25MB attachment limit + blocks external `From:` spoofing on `+local_domains` & IP-literal HELOs |
| **[System Health Report Guide](scripts/system-report/README.md)** | `v-system-report` | `0 8 * * 0` (Sun 08:00) | HTML health digest (CPU, RAM, Disk, Services, SSL expiry, RBL blacklists) |
| **[Web Permissions Fixer Guide](scripts/fix-web-permissions/README.md)** | `v-fix-web-permissions` | On-demand rescue | Fixes `public_html` ownerships, hardens CMS configs (`640`), flags exposed `.git` |
| **[Security Audit Guide](scripts/security-audit/README.md)** | `v-security-audit` | `0 7 * * 0` (Sun 07:00) | 4-layer A–F security scanner (System, YARA Backend, TLS/Headers, OWASP Pentest) |
| **[Server Hardening & CrowdSec Guide](scripts/server-hardening/README.md)** | `v-harden-server` | `50 4 * * *` (daily 04:50 healer) | 6-pillar hardening: sysctl, APT, SSH, IPv6 nftables mirror, Nginx edge + Fail2Ban `.local`, CrowdSec IPS |
| **[Logrotate Optimizer Guide](scripts/logrotate-optimize/README.md)** | `v-optimize-logrotate` | Event-driven (`logrotate.d`) | Upgrades Nginx & Apache rotation from `weekly rotate 4` to `daily rotate 14` |
| **[Fail2Ban Email Optimizer Guide](scripts/fail2ban-optimize/README.md)** | `v-optimize-fail2ban` | Daemon (`jail.d/*.local`) | Relaxes Dovecot/Exim bans (`5` retries / `2h` ban) so typos don't cause 7-day lockouts |
| **[Nginx `.txt` Cache Hardener Guide](scripts/nginx-txt-nocache/README.md)** | `v-patch-nginx-txt-nocache` | Auto-healed daily (`04:50`) | Removes `.txt` from static `expires max` rules so `robots.txt`/`llms.txt`/`ads.txt` stay fresh |

#### [System Cleanup (`v-clean-garbage`)](scripts/clean-garbage/)
- Cleans old system logs (Journalctl), rotated logs, and temp files.
- Manages mail queue and spam retention.
- Configuration-driven toggles per task.

#### [Native Backup Core Patches](scripts/backup-core-patches/)
- **Native hooks and optional helpers:** Integrates with Hestia core scripts and provides separate helpers for Restic orchestration, verification and export.
- **Pillar 1: Data Organization:** Automatically organizes local files and B2 Cloud files into `YYYY/MM_MONTH/username/` while perfectly keeping Symlinks in root for Hestia Web Panel UI compatibility. 
- **Pillar 2: Database Auto-Repair:** Injects pre-flight `mysqlrepair --check --auto-repair` to gracefully fix corrupted indexes *before* `mysqldump`, eliminating the #1 cause of silent backup failures.
- **Pillar 3: Interactive TTY Shell:** Automatically detects manual terminal sessions and streams live console logs via `tee`, while remaining perfectly silent for nocturnal cron jobs.
- **Pillar 4: Enterprise HTML Notifications:** Replaces basic TXT messages with AWS-style Dark Mode Multipart HTML reports (inclusive of physical `.log` file attachments and Global Administration Batch summaries).
- **Native Optional Smart Retention:** Patches `v-backup-users` with a disabled-by-default retention hook powered by `v-prune-backups`, giving classic `.tar` backups dry-run-first daily/weekly/monthly thinning across local, B2, or rclone storage. Hestia's native `BACKUPS` count and Restic pruning still remain available.
- **Remote & Local Backup Verification (`v-verify-backups`):** Cross-checks every non-suspended HestiaCP user's latest `backup.conf` entry against the live remote bucket (`b2 ls --long` / `rclone lsl`) or local `.tar` archive (`tar -tf`), automatically reconciling expired cloud/local entries in `backup.conf` (`U_BACKUPS`), verifying existence, byte-size tolerance, and freshness (`<= 8` days for weekly or `<= 35` days for monthly `.tar` schedules), plus every active user's Restic snapshot metadata (`<= 36h`) into `/var/log/hestia/backup-verify.status`. This metadata check does not read all backup data or prove a working restore.
- **Restic Incremental, Secondary Recovery Password & TAR Export (`v-restic-manager`):** Enrolls a secondary recovery password in each user repository, keeps its server copy at `/etc/hestiacp-restic-master.key` (`0400 root:root`), and requires an independently protected offline copy for disaster recovery. It also hardens per-user credentials, removes staging dumps, sends failure alerts and reconstructs the Hestia archive layout for export. Per-user locks and atomic publication prevent concurrent downloads from receiving an unfinished TAR. Validate full recovery on an isolated Hestia installation before relying on it for migration.

#### [GitHub Mirror (`v-github-mirror`)](scripts/github-mirror/)
- A cron-based zero-trust auto-pull script that mirrors private/public GitHub or GitLab repositories into a user's isolated `/home/<user>/git/<repo>` directory (or `web/<domain>/private/`), safely outside public web access and automatically included in HestiaCP user backups (`User Directory: git`).
- Automatically pre-creates top-level `git/` directories (`0700 <user>:<user>`) on SFTP-chrooted HestiaCP homes and strips remote URLs/credentials from tenant `.git/config`.

#### [Exim Limit & Anti-Spoof Monitor (`v-add-exim-limit`)](scripts/exim-limit/)
- Blocks outgoing emails larger than 25MB to protect IP reputation, with user-friendly rejection messages and admin alerts.
- Dynamically blocks unauthenticated external senders forging any local HestiaCP domain (`+local_domains`) in the visual `From:` header (closing the `Return-Path: <>` null-sender spoofing loophole across all current and future domains).

#### [System Health Report (`v-system-report`)](scripts/system-report/)
- Checks CPU, RAM, Disk, and Load averages.
- Monitors all HestiaCP services (Nginx, Apache, PHP-FPM, MySQL, Exim, etc.).
- Checks SSL expiry, email blacklists, and database errors.
- Sends a detailed HTML report to the admin.

#### [Web Permissions Fixer (`v-fix-web-permissions`)](scripts/fix-web-permissions/)
- A rescue tool that goes beyond the native `v-rebuild-web-domain`. It safely descends into `public_html/` and aligns broken file ownerships (`user:user`) caused by root SFTP uploads or botched CMS auto-updates.
- **Smart Exclusions:** It applies strict `644/755` base permissions but features CMS autodetection. Framework secrets (e.g. Laravel `.env`, WordPress `wp-config.php`, Magento `env.php`) are strictly hardened to `640`.
- **Safety First:** It runs read-only security scans (warning of exposed `.git` folders in production) and respects a `.no-fix-permissions` sentinel file to gracefully skip domains with custom CGI configurations.

#### [Security Audit (`v-security-audit`)](scripts/security-audit/)
- A highly modular, zero-dependency auditing tool inspired by Lynis, built natively for HestiaCP's architecture. It grades the server's security from A to F and exports JSON/HTML reports across 4 distinct layers:
- **System Layer:** Validates kernel CVEs, SSH hardening, Fail2Ban bounds, and WordPress Fail2Ban filter coverage (ensures both `xmlrpc.php` and `wp-login.php` attacks are caught).
- **Backend Layer:** Scans `public_html/` via YARA rules for deep PHP Malware heuristics, base64 WebShells, and Auto-Symlink Escapes.
- **Frontend Layer:** Checks TLS ciphers, HSTS, and Security Headers.
- **Pentest Layer:** An aggressive offensive layer that simulates real-world OWASP Top 10 attacks (SQLi, XSS, Brute-Force floods) against your own domains to test firewall resiliency.

#### [Server Hardening & CrowdSec IPS (`v-harden-server`)](scripts/server-hardening/)
- Automates 6 upgrade-safe security layers engineered specifically for HestiaCP on Debian and Ubuntu:
- **Kernel & APT Hardening:** Applies SYN flood cookies, `rp_filter`, redirect/source-route blocks, SUID core-dump protection, and `99-keep-custom-configs` (`--force-confdef --force-confold`) so `apt upgrade` never overwrites custom `/etc` configs.
- **Lockout-Safe SSH Hardening:** Enforces `MaxAuthTries 3`, keepalives, and disables `PasswordAuthentication` *only* after verifying at least one valid SSH public key exists in `authorized_keys` (with `sshd -t` pre-flight validation).
- **Dual-Stack IPv6 Firewall Mirror (`hestia-ipv6-guard`):** Closes HestiaCP's IPv6 `INPUT ACCEPT` blind spot on dual-stack cloud servers by dynamically mirroring HestiaCP's open ports into an isolated `nftables` `table ip6 hestia_ipv6_guard` while preserving ICMPv6 Neighbor Discovery.
- **Upgrade-Proof Web/Webmail Filters & Desync Healer:** Deploys `.local` Fail2Ban overrides (`wordpress-xmlrpc.local` for `xmlrpc.php` + `wp-login.php`, plus `roundcube-auth.local` fixing Roundcube behind Nginx proxy, validated via `fail2ban-client -t`) and automatically heals post-update Fail2Ban ↔ `iptables` desyncs (`50 4 * * *` cron right after HestiaCP's `04:41` auto-update).
- **CrowdSec Collaborative IPS (`--crowdsec`):** Isolates CrowdSec LAPI on `127.0.0.1:8099` (zero port conflict with Apache `:8080`), dynamically detects the active `hestia.conf` stack (`Nginx-only` vs `Nginx+Apache2`, `VSFTPD`/`ProFTPD`, `Exim4`/`Postfix`/`Dovecot`, `MariaDB`/`PgSQL`, `Roundcube`), protects HestiaCP `:8083` + Multi-CMS logins (Drupal, Nextcloud, Laravel, PrestaShop, OpenCart, DokuWiki, MediaWiki, WordPress) + Nextcloud WebDAV sync whitelist (validated via `crowdsec -t`), runs `crowdsec-firewall-bouncer-nftables` immune to `v-update-firewall`, and **exempts the active SSH port from external blocklists** so admins on shared VPNs are never locked out of SSH.

#### [Logrotate Optimizer (`v-optimize-logrotate`)](scripts/logrotate-optimize/)
- Upgrades Apache & Nginx log rotation from the HestiaCP default (`weekly rotate 4`) to `daily rotate 14` — preventing domain logs from growing to 100MB+ during ad campaigns (Facebook/Instagram UTM params inflate each log line to ~630 bytes) or sustained brute-force attacks.
- Safe and persistent across HestiaCP updates. Backs up original configs and validates before applying.

#### [Fail2Ban Email Optimizer (`v-optimize-fail2ban`)](scripts/fail2ban-optimize/)
- Balances email jail thresholds (`dovecot-iptables` and `exim-iptables`) from HestiaCP's strict defaults (7-day ban on 3 attempts) to balanced production values: `maxretry = 5`, `findtime = 600s`, `bantime = 7200s` (2 hours).
- Solves the common issue where legitimate clients or shared webmail fetchers (Gmail POP3 Mail Fetcher, Outlook mobile) get locked out for an entire week due to accidental credential typos or background retries.
- Deploys to `/etc/fail2ban/jail.d/99-hestiacp-email-hardening.local` to ensure highest precedence over `/etc/fail2ban/jail.local`, surviving all HestiaCP package upgrades without modifying core files.
- Provides CLI diagnostic tools: `v-optimize-fail2ban --status`, `--dry-run`, and `--unban <IP>`, plus 1-command standalone installation via `bash install.sh --fail2ban`.

#### [Nginx `.txt` Cache Hardener (`v-patch-nginx-txt-nocache`)](scripts/nginx-txt-nocache/)
- Removes `txt` from Nginx static `expires max` location blocks across PHP-FPM templates, active domain configs, and reverse-proxy `PROXY_EXT` definitions (`web.conf` and HestiaCP proxy defaults) so `.txt` files (`robots.txt`, `llms.txt`, `ads.txt`, `security.txt`) are not cached indefinitely and remain clean across domain rebuilds.

---

## 🚀 Installation (Step by Step)

### Prerequisites

- A server running **HestiaCP** (any recent version)
- **Root access** via SSH
- `git` installed (`apt install git` if needed)

### Step 1: Clone the repository

```bash
git clone https://github.com/webxtekstudio/hestiacp-useful-tools.git /root/hestiacp-useful-tools
cd /root/hestiacp-useful-tools
```

### Step 2: Run the installer

```bash
# Interactive mode (recommended — lets you choose standard vs full install with CrowdSec + Crons):
bash install.sh

# — OR Non-Interactive CLI Flags —
bash install.sh --all          # Install all modules + CrowdSec IPS + Automated Cron Jobs
bash install.sh --setup-crons  # Configure recommended cron schedules only
bash install.sh --harden       # Run only the 5-pillar Server Hardening module
bash install.sh --crowdsec     # Run Server Hardening + CrowdSec Collaborative IPS (6 pillars)
bash install.sh --fail2ban     # Run only the Fail2Ban Email Optimizer
```

This installs the selected tools to `/usr/local/hestia/bin/` and creates default configs in `/etc/` (existing configs are never overwritten on re-runs).

> **That's it for backups.** This ensures your server natively supports organized storage without extra configs.

### Step 3: Set up a schedule (if not already enabled in Step 2)

The backup module uses the native HestiaCP cron system. If you chose the Standard install in Step 2 and want to add the automated maintenance schedules later:

```bash
bash install.sh --setup-crons
```

### Step 4: Test it

```bash
# Test backup for a single user via the Hestia panel, or run natively:
# (The 'yes' forces the Instant HTML Notification to trigger even on success)
v-backup-user admin yes

# Check it worked
ls -la /backup/
```

**Done!** Your server is now robustly configured.

---

### Optional: Add Remote Backups (B2, FTP, SFTP)

Want your backups also sent to the cloud? HestiaCP handles this natively — just run **one** command:

```bash
# Backblaze B2 (cheapest cloud option — ~$0.005/GB/month)
# 1. Create account at https://www.backblaze.com
# 2. Create a bucket (B2 Cloud Storage → Create a Bucket)
# 3. Create an Application Key (App Keys → Add a New Application Key)
# 4. Run:
v-add-backup-host b2 YOUR_BUCKET_NAME YOUR_KEY_ID YOUR_APP_KEY

# — OR —

# SFTP (any server with SSH access)
v-add-backup-host sftp backup.example.com username password

# — OR —

# FTP
v-add-backup-host ftp ftp.example.com username password
```

**Verify it worked:**
```bash
grep BACKUP_SYSTEM /usr/local/hestia/conf/hestia.conf
# Should show: BACKUP_SYSTEM='local,b2'  (or local,sftp etc.)
```

After this, every backup created by our tool is automatically uploaded to your cloud destination by HestiaCP. Downloads, restores, and deletes from the panel all work natively.

---

### Updating

```bash
cd /root/hestiacp-useful-tools
git pull
bash install.sh    # safe to re-run — configs are never overwritten
```

### Installing a single tool

Each tool can be installed standalone:
```bash
bash scripts/backup-core-patches/install.sh
bash scripts/system-report/install.sh
```

---

## ⚠️ Disclaimer

These scripts are provided "as is". While used in production, review and test in your environment before deployment.
