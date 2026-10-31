# Server Hardening & CrowdSec IPS (`v-harden-server`)

Automates 6 production-grade Linux, Dual-Stack IPv6, Fail2Ban, and **CrowdSec Collaborative IPS** security layers specifically engineered for HestiaCP servers on Debian and Ubuntu — **100% immune to daily HestiaCP updates and SSH lockouts**.

---

## 🎯 Why Default HestiaCP Servers Need This

Out of the box on cloud VPS providers, HestiaCP has four subtle architectural blind spots:

1. **Unfirewalled Dual-Stack IPv6 (`INPUT ACCEPT`):** HestiaCP's built-in `v-update-firewall` and `v-add-firewall-ban` only manage IPv4 `iptables`. On dual-stack VPS instances with a global IPv6 `/64`, `ip6tables` defaults to `ACCEPT` with zero rules — exposing `:8083`, `:22`, and mail ports over IPv6 without firewall or Fail2Ban protection.
2. **HestiaCP Updates Wipe Custom `iptables` Rules:** Daily `v-update-sys-hestia-all` runs can flush `iptables` chains, breaking traditional `iptables`-based CrowdSec bouncers or desyncing Fail2Ban bans.
3. **Vanilla CrowdSec Collides with Apache `:8080` & Misses Domain Logs:** On HestiaCP, Apache2 binds port `:8080` (colliding with CrowdSec's default `127.0.0.1:8080` LAPI), and CrowdSec's auto-generated acquisition misses `/var/log/apache2/domains/*.log`, `/var/log/nginx/domains/*.log`, `/var/log/exim4/mainlog`, and `/var/log/dovecot.log`.
4. **Shared VPN SSH Lockout Risk:** Admins connecting via commercial VPNs share exit IPs with thousands of strangers. If that shared VPN IP lands on a global blocklist, standard firewall bouncers lock the admin out of SSH even with a valid Ed25519 key.

---

## 🛡️ What `v-harden-server` Automates (The 6 Pillars)

| Pillar | Protection | Upgrade-Safe Mechanism |
| :--- | :--- | :--- |
| **1. Kernel Network Hardening** | SYN flood cookies, `rp_filter` anti-spoofing, ICMP redirect & source-route blocks, `fs.suid_dumpable=0`, `kernel.panic=10` (keeps `cubic`) | `/etc/sysctl.d/99-hestiacp-hardening.conf` |
| **2. APT Config Preservation** | Prevents `apt upgrade` from overwriting custom `/etc` configs + locks `/etc/crontab` (`0600`) | `/etc/apt/apt.conf.d/99-keep-custom-configs` |
| **3. Lockout-Safe SSH Hardening** | `MaxAuthTries 3`, keepalives, and `PasswordAuthentication no` **only** if a valid SSH public key is verified in `authorized_keys` (tested with `sshd -t` before reload) | `/etc/ssh/sshd_config.d/00-hardening.conf` |
| **4. IPv6 Firewall Mirror** | Dynamically mirrors HestiaCP's open ports from `rules.conf` (+ essential `icmpv6` Neighbor Discovery) into an isolated `nftables` IPv6 firewall | `hestia-ipv6-guard.service` (`table ip6 hestia_ipv6_guard`) |
| **5. WP Filter & F2B Sync** | Covers both `xmlrpc.php` and `wp-login.php` brute-force attacks and auto-heals Fail2Ban ↔ `iptables` desyncs | `/etc/fail2ban/filter.d/wordpress-xmlrpc.local` |
| **6. CrowdSec Collaborative IPS** | Isolates LAPI on `127.0.0.1:8099`, tails all HestiaCP domain/mail logs, runs `nftables` bouncer immune to `iptables -F`, and **exempts the active SSH port** from external blocklists | `table ip crowdsec` + `crowdsec-ssh-exempt` |

---

## 🛠 Usage

```bash
# Inspect live status of all 6 security pillars (100% read-only)
v-harden-server --status

# Preview planned changes without modifying any files
v-harden-server --dry-run

# Apply Pillars 1–5 (Kernel, APT, safe SSH, IPv6 Firewall Mirror, WP Fail2Ban)
v-harden-server

# Install & configure Pillar 6 (CrowdSec + nftables bouncer + SSH anti-lockout)
v-harden-server --crowdsec

# Apply ALL 6 Pillars in one command
v-harden-server --all

# Permanently whitelist a trusted office/admin IP across CrowdSec & Fail2Ban
v-harden-server --whitelist 198.51.100.10/32

# Instantly unban an IP across CrowdSec, HestiaCP firewall, and all Fail2Ban jails
v-harden-server --unban 198.51.100.25
```

---

## 📦 Standalone Installation

From the `hestiacp-useful-tools` repository root:

```bash
# Install and apply Pillars 1–5
bash install.sh --harden

# Install and apply ALL 6 Pillars (including CrowdSec IPS)
bash install.sh --crowdsec
```

When `bash install.sh --setup-crons` is enabled, a daily silent self-healing check (`v-harden-server --cron-heal`) runs at `04:50` (right after HestiaCP's `04:41` auto-update) to resync IPv6 rules, heal any Fail2Ban chain desync, and verify CrowdSec + SSH anti-lockout rules.
