# 🛠️ Server Security Auditor (`security-audit`)

*A comprehensive security scanner for your server. It grades your server's security from A to F by scanning for malware, looking for leaked passwords, and testing your firewalls.*

---

## 🚫 1. MASSIVE DANGER WARNING (READ THIS FIRST)
> [!CAUTION]
> **This tool includes a `--pentest` function.**
> The pentest layer performs aggressively offensive hacking attacks against your own websites (SQL Injection, XSS, Brute-Force) to test if your firewalls work.
> 
> **NEVER** run the `--pentest` flag on a production website during business hours! It will flood your server with malicious traffic and may trigger alarms on external firewalls like Cloudflare.
> The other layers (`--system` and `--backend`) are 100% read-only and safe to use at any time!

## 🚀 2. How to Install (The Easy Way)
Instead of copying files manually, use the module installer to place the script and its library modules:
```bash
cd /root/hestiacp-useful-tools/scripts/security-audit
bash install.sh
```

To add the recommended weekly schedule, run the repository root installer with `--setup-crons`.

## 📂 3. File Paths (Where is everything?)
If you want to look at the files, here is exactly where the installer places them:
* **The Executable Script:** `/usr/local/hestia/bin/v-security-audit`
* **The Vulnerability Database:** `/usr/local/hestia/bin/v-security-audit.d/` (installed beside the executable).

## ⚙️ 4. How to Run Scans (The Dummy-Proof Way)
There is no configuration file. You just run it via the command line when you want to audit your server.

**Safe, Read-Only Scans:**
```bash
v-security-audit --system      # Audits Linux, Firewalls, and Ports
v-security-audit --backend     # Scans inside users' folders for Malware & Viruses
v-security-audit --frontend https://domain.com   # Scans domain SSL & HTTP headers safely
```

**Aggressive Pentest Scan:**
```bash
v-security-audit --pentest https://domain.com    # ATTACKS the domain (SQLi, Brute-Force, LFI)
```

**Global "Run Everything" Scan:**
```bash
v-security-audit --all                           # Runs all 4 layers (Including Pentest)
```

## ⛔ 5. Crucial Rules (What NOT to do)
* **DO NOT** edit the `.sh` executable file directly. 
* **DO NOT** rip the `v-security-audit` file away from its `lib/` folder. It relies on 32 adjacent dependency scripts to run.
* **DO NOT** run this script as a normal user. It must be executed as `root` to bypass folder permissions and scan for malware effectively.

---

## 🔬 Advanced Architecture Notes (Geeks Only)

### Modular Architecture
Inspired by Lynis and testssl.sh. Core tests are separated into `lib/system/`, `lib/backend/`, `lib/frontend/`, and `lib/pentest/`, where each folder contains multiple targeted files.

### Layer 1: `--system` (OS & Service Hardening)
Audits the server infrastructure as root.
| Category | Checks |
|---|---|
| OS & Keys | Outdated Kernel, Failed SSH logins, Firewalls, Root Cron Job Hijack validation |
| Fail2Ban | SSH jail, Recidive jail, WordPress jail presence, WordPress filter wp-login.php coverage |
| Kernel | ASLR, SYN cookies, source routing, core dumps, CVE Profiling (Dirty COW / Dirty Pipe) |

### Layer 2: `--backend` (Per-Domain File-Level Scan)
Scans the filesystem inside each domain's `public_html/`.
| Category | Checks |
|---|---|
| File Exposure | `.env`, `.git/`, SQL dumps, config backups, debug files, private keys |
| PHP Malware | `eval(base64_decode())`, webshell signatures, YARA rules, Auto-Symlink Escapes |
| CMS Hardening | WordPress (wp-config perms, upload execution), Laravel (APP_DEBUG, APP_KEY) |

### Layer 3: `--frontend` (External HTTP/HTTPS Scan)
Simulates an external attacker probing the website limits.
| Category | Checks |
|---|---|
| TLS/Headers | HTTP/2, OCSP stapling, X-Frame-Options, CSP, Strict-Transport-Security |
| Info Leak | xmlrpc.php, REST API user enum, ?author enumeration, open redirects |

### Layer 4: `--pentest` (Offensive Self-Attack)
Actively attempts exploitation using curl, openssl, dig, and nc.
| Category | Checks |
|---|---|
| Active Hacks | SQL Injection (Time-based/Error), XSS, LFI/RFI, Command Injection `;id` |
| Load Attacks | Login rate-limit tests, XMLRPC Pingback DoS, 20-request auth floods |

### Scoring & Reporting
Outputs beautiful terminal, markdown `--md` or `--json` structured formats.

| Score | Grade | Status |
|---|---|---|
| 90–100 | A | Production-hardened |
| 75–89 | B | Minor improvements needed |
| 60–74 | C | Several gaps to address |
| 40–59 | D | Significant risk |
| 0–39 | F | Actively vulnerable |
