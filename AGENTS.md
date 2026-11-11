# HestiaCP Useful Tools — AI Agent Instructions

> **PUBLIC REPOSITORY WARNING (CRITICAL):**
> This repository is **100% public** for the HestiaCP community.
> **NEVER** commit real server IP addresses, personal domains, real usernames, private company/agency names, or credentials anywhere in code, comments, prompts, or commit messages. Always use generic placeholders (`example.com`, `192.0.2.10`, `admin`, `user1`).

---

## 1. Repository Overview & Default Language

- **Default Language:** English for all scripts, documentation, AI prompts, and commit messages.
- **Purpose:** Production-grade administration scripts, surgical backup hooks, security auditing (`v-security-audit`), optimization tools, and AI DevOps knowledge for Debian/Ubuntu HestiaCP servers.

---

## 2. Directory Map

| Path | Description |
|---|---|
| [`install.sh`](./install.sh) | Unified installer that deploys tools into `/usr/local/hestia/bin/` and applies idempotent backup patches |
| [`AI/knowledge/`](./AI/knowledge/) | HestiaCP reference guides (paths, CLI, backups, Exim4/Dovecot, PHP-FPM, MariaDB, SSL, security, disaster recovery) |
| [`AI/DevOps-AI-Prompts/`](./AI/DevOps-AI-Prompts/) | Standalone example prompts (`System-Monitor-Prompt.md`, `DevOps-Agent-Prompt.md`) |
| [`scripts/security-audit/`](./scripts/security-audit/) | `v-security-audit` — 70-check HestiaCP & Linux security scanner (`lib/core.sh`, `lib/system/`, `lib/hestia.sh`, `lib/wordpress.sh`, `lib/malware.sh`) |
| [`scripts/server-hardening/`](./scripts/server-hardening/) | `v-harden-server` — 6-pillar upgrade-safe HestiaCP hardening (Kernel sysctl, APT config keep, lockout-safe SSH, IPv6 nftables mirror, Nginx edge + WP/Roundcube Fail2Ban sync & CrowdSec IPS) |
| [`scripts/backup-core-patches/`](./scripts/backup-core-patches/) | Surgical patches for HestiaCP `v-backup-user` / `backup.sh` enabling Backblaze B2 / SFTP hooks, `v-prune-backups` retention, `v-verify-backups`, and HTML notifications |
| [`scripts/system-report/`](./scripts/system-report/) | `v-system-report` — automated HTML system health and resource report |
| [`scripts/fix-web-permissions/`](./scripts/fix-web-permissions/) | `v-fix-web-permissions` — CMS-aware ownership and permission repair for HestiaCP web directories |
| [`scripts/clean-garbage/`](./scripts/clean-garbage/) | `v-clean-garbage` — safe cleanup of system logs, rotated logs, PHP sessions, temp dirs, and mail/trash retention |
| [`scripts/github-mirror/`](./scripts/github-mirror/) | `v-github-mirror` — zero-trust pull-only Git repository mirror into tenant `git/` (or `private/`) directories |
| [`scripts/exim-limit/`](./scripts/exim-limit/) | `v-add-exim-limit` & `monitor_large_emails.py` — attachment size limit, `+local_domains` `From:` header anti-spoofing, and alert monitor |
| [`scripts/logrotate-optimize/`](./scripts/logrotate-optimize/) | `v-optimize-logrotate` — upgrades Apache & Nginx log rotation from weekly to daily (`rotate 14`) |
| [`scripts/fail2ban-optimize/`](./scripts/fail2ban-optimize/) | `v-optimize-fail2ban` — balances Dovecot & Exim Fail2Ban thresholds via `.local` precedence |
| [`scripts/nginx-txt-nocache/`](./scripts/nginx-txt-nocache/) | `v-patch-nginx-txt-nocache` — removes `.txt` from static `expires max` blocks and `PROXY_EXT` defaults |
| [`mariadb_optimize/`](./mariadb_optimize/) | MariaDB configuration tuning for HestiaCP workloads |
| [`php_optimize/`](./php_optimize/) | PHP-FPM pool and OPcache optimization scripts |
| [`swap_setup/`](./swap_setup/) | Automated swapfile creation and `vm.swappiness` tuning |
| [`tests/run-tests.sh`](./tests/run-tests.sh) | Automated syntax, unit/regression sandbox (`/run/hestia-test.*` with mocked `systemctl`/`fail2ban-client`/`iptables`), and public-repo privacy test suite |

---

## 3. Development & Coding Standards

1. **Idempotency & HestiaCP Upgrade Safety:**
   - HestiaCP updates (`/usr/local/hestia/bin/*` and `/usr/local/hestia/func/*`) overwrite native binaries. Any core patch must include clear marker comments (e.g., `hestia-custom-hook-v1`) so `install.sh` and health monitors can detect and re-apply patches safely.
   - Prefer native HestiaCP hook directories (`/etc/hestiacp/hooks/`) whenever supported.
2. **Non-Destructive Auditing (`v-security-audit`):**
   - `v-security-audit` must remain 100% read-only unless `--fix` is explicitly passed.
   - Avoid false positives on Debian 12+ (`bookworm` / `trixie`): account for `systemd-journald` (when `/var/log/syslog` is absent), HestiaCP's native `iptables` rules (when `ufw` is not used), `sshd -T` effective runtime evaluation, and DNS-only domains (`ACCOUNT='0'` in `mail.conf`).
3. **Privacy Check Before Every Commit:**
   - Always scan `git diff` to ensure zero private IPs, domains, or usernames are present before committing.
