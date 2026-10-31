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
| [`scripts/server-hardening/`](./scripts/server-hardening/) | `v-harden-server` — 6-pillar upgrade-safe HestiaCP hardening (Kernel sysctl, APT config keep, lockout-safe SSH, IPv6 nftables mirror, WP Fail2Ban sync & CrowdSec IPS) |
| [`scripts/backup-core-patches/`](./scripts/backup-core-patches/) | Surgical patches for HestiaCP `v-backup-user` / `backup.sh` enabling Backblaze B2 / SFTP hooks, per-user retention, and notifications |
| [`scripts/system-report/`](./scripts/system-report/) | `v-system-report` — automated HTML system health and resource report |
| [`scripts/fix-permissions/`](./scripts/fix-permissions/) | `v-fix-web-permissions` — safe ownership and permission repair for HestiaCP web directories |
| [`mariadb_optimize/`](./mariadb_optimize/) | MariaDB configuration tuning for HestiaCP workloads |
| [`php_optimize/`](./php_optimize/) | PHP-FPM pool and OPcache optimization scripts |
| [`swap_setup/`](./swap_setup/) | Automated swapfile creation and `vm.swappiness` tuning |

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
