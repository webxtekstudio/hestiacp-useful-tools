# Fail2Ban Email Optimizer (`v-optimize-fail2ban`)

Balances email jail thresholds in Fail2Ban and ensures persistent, highest-priority configuration across HestiaCP updates.

---

## 🎯 The Problem

HestiaCP defaults to very strict rules on email jails (`dovecot-iptables` and `exim-iptables`):
* **`bantime = 604800` (7 days)**
* **`maxretry = 3` (3 attempts)**

When legitimate users:
1. Make an accidental typo in their username or password;
2. Use **Gmail POP3 Mail Fetcher** or **Outlook mobile**, which retry in the background;
3. Omit the full domain in the username (typing `webmaster` instead of `webmaster@domain.com`);

Fail2Ban bans the IP for **7 full days**, resulting in:
> *"Connection timed out: There may be a problem with the settings you added..."*

Worse, HestiaCP package updates regularly overwrite `/etc/fail2ban/jail.local`, and drop-in `.conf` files in `jail.d/` are evaluated *before* `jail.local`, meaning custom `bantime` settings get ignored.

---

## 🚀 The Solution

`v-optimize-fail2ban`:
1. Deploys `/etc/fail2ban/jail.d/99-hestiacp-email-hardening.local`. Because it uses the `.local` extension, Fail2Ban gives it **highest precedence**, overriding `/etc/fail2ban/jail.local` even after HestiaCP updates.
2. Configures balanced thresholds:
   * **`maxretry = 5`**: Tolerates accidental typos and background client retries.
   * **`findtime = 600`** (10m): Failures only count within a 10-minute window.
   * **`bantime = 7200`** (2 hours): Blocks bots effectively, while ensuring legitimate users are unblocked in 2 hours instead of 7 days.
3. Automatically cleans up legacy/ineffective `.conf` overrides in `jail.d/`.
4. Safely restarts Fail2Ban and verifies the live jail values.

---

## 🛠 Usage

```bash
# Apply optimization immediately
v-optimize-fail2ban

# Check live jail thresholds and banned IP count
v-optimize-fail2ban --status

# Preview changes without modifying anything
v-optimize-fail2ban --dry-run

# Unban a specific IP from all mail jails
v-optimize-fail2ban --unban 1.2.3.4
```

---

## 📦 Standalone Installation

From the `hestiacp-useful-tools` repository root:
```bash
# Install only the Fail2Ban optimizer module
bash install.sh --fail2ban
```