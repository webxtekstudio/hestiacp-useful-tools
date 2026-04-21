# HestiaCP Useful Tools Collection

A curated collection of production-grade scripts, optimization guides, and **platform-agnostic AI prompt blueprints** for HestiaCP + Debian/Ubuntu servers.

Built and battle-tested for real production environments. A contribution to the HestiaCP community — thank you to the team for your continuous work!

---

## 📂 Repository Structure

### 1. 📖 Guides & Optimizations

Step-by-step guides to optimize your server infrastructure.

- **[PHP-FPM Optimization Guide](php_optimize/):** Calculate RAM limits and choose between `ondemand`, `dynamic`, and `static` PHP modes based on server size and traffic.
- **[MariaDB Optimization Guide](mariadb_optimize/):** Configure `innodb_buffer_pool_size` to dramatically improve database performance and reduce CPU load.
- **[SWAP Setup Guide](swap_setup/):** 1-click script to configure SWAP memory, essential for low-RAM environments (1GB/2GB VPS).

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

#### [System Cleanup (`v-clean-garbage`)](scripts/clean-garbage/)
- Cleans old system logs (Journalctl), rotated logs, and temp files.
- Manages mail queue and spam retention.
- Configuration-driven toggles per task.

#### [Native Backup Core Patches](scripts/backup-core-patches/)
- **100% Native Architecture:** Injects surgical hooks directly into Hestia's core scripts. No custom wrappers or separate standalone processes.
- **Pillar 1: Data Organization:** Automatically organizes local files and B2 Cloud files into `YYYY/MM_MONTH/username/` while perfectly keeping Symlinks in root for Hestia Web Panel UI compatibility. 
- **Pillar 2: Database Auto-Repair:** Injects pre-flight `mysqlrepair --check --auto-repair` to gracefully fix corrupted indexes *before* `mysqldump`, eliminating the #1 cause of silent backup failures.
- **Pillar 3: Interactive TTY Shell:** Automatically detects manual terminal sessions and streams live console logs via `tee`, while remaining perfectly silent for nocturnal cron jobs.
- **Pillar 4: Enterprise HTML Notifications:** Replaces basic TXT messages with AWS-style Dark Mode Multipart HTML reports (inclusive of physical `.log` file attachments and Global Administration Batch summaries).
- **Native Optional Smart Retention:** Patches `v-backup-users` with a disabled-by-default retention hook powered by `v-prune-backups`, giving classic `.tar` backups dry-run-first daily/weekly/monthly thinning across local, B2, or rclone storage. Hestia's native `BACKUPS` count and Restic pruning still remain available.

#### [GitHub Mirror (`v-github-mirror`)](scripts/github-mirror/)
- A cron-based auto-pull script that securely mirrors private GitHub/GitLab repositories straight into a specified user's `private` directory (safely away from public web access).
- Automatically fixes the ownership permissions intrinsically so Hestia isn't locked out of `public_html`. Perfect for keeping static source code synced for local backups.

#### [Exim Limit Monitor (`v-add-exim-limit`)](scripts/exim-limit/)
- Blocks outgoing emails larger than 10MB to protect IP reputation.
- Sends rejection messages to users with alternatives.
- Notifies the admin on every block event.

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
bash install.sh
```

This installs all tools to `/usr/local/hestia/bin/` and creates default configs in `/etc/`.

> **That's it for backups.** This ensures your server natively supports organized storage without extra configs.

### Step 3: Set up a schedule

The backup module uses the native HestiaCP cron system. No extra crons are needed! For the other tools:

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
