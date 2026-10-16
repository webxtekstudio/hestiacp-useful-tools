# HestiaCP SSL Certificate Management

## 1. Verified System Paths (Consult `01-hestia-system-paths.md`)
**CRITICAL:** HestiaCP stores certificates in user configuration and Hestia data directories, NOT in `/etc/letsencrypt/live`.

| Component | Path |
| :--- | :--- |
| **Web Certs (Active Nginx/Apache)** | `/home/[USER]/conf/web/[DOMAIN]/ssl/[DOMAIN].crt` |
| **Web Keys** | `/home/[USER]/conf/web/[DOMAIN]/ssl/[DOMAIN].key` |
| **Mail Certs (Active Exim/Dovecot)** | `/home/[USER]/conf/mail/[DOMAIN]/ssl/[DOMAIN].crt` |
| **Hestia User SSL Store (Web)** | `/usr/local/hestia/data/users/[USER]/ssl/[DOMAIN].crt` |
| **Hestia User SSL Store (Mail)** | `/usr/local/hestia/data/users/[USER]/ssl/mail.[DOMAIN].crt` |
| **Panel Cert** | `/usr/local/hestia/ssl/certificate.crt` |
| **LE Logs** | `/var/log/hestia/LE-[USER]-[DOMAIN].log` and `/var/log/hestia/LE-[USER]-mail.[DOMAIN].log` |
| **Post-Renewal Hook (Update-Safe)** | `/etc/hestiacp/hooks/le_post.sh` |

## 2. How HestiaCP Let's Encrypt Internals Work (Web vs. Mail)
`v-update-letsencrypt-ssl` (executed daily by cron) takes **no arguments** and runs **two completely independent loops** per user:
1. **Loop 1 (`web.conf`):** Checks `/usr/local/hestia/data/users/[USER]/ssl/[DOMAIN].crt`. If expiring within 30 days, calls:
   ```bash
   v-add-letsencrypt-domain "$user" "$domain" "$aliases"
   ```
2. **Loop 2 (`mail.conf`):** Checks `/usr/local/hestia/data/users/[USER]/ssl/mail.[DOMAIN].crt`. If expiring within 30 days, calls:
   ```bash
   v-add-letsencrypt-domain "$user" "$domain" "" "yes"
   ```
   - When the 4th argument `"yes"` (Mail mode) is passed, `v-add-letsencrypt-domain` **automatically prepends `mail.`** to the domain (`mail.[DOMAIN]`) and, if `WEBMAIL` is enabled on that mail domain, adds `webmail.[DOMAIN]` as the alias!
   - If validation fails 30 times (`LETSENCRYPT_FAIL_COUNT='31'`), HestiaCP stops retrying until manually re-enabled.

## 3. Checking SSL Status (The Fast Way)
Do not use `openssl s_client` against localhost (it often fails or returns the default SNI cert). Check the certificate files directly.

### A. Check All Web & Mail Certs Expiration
```bash
sudo -n find /home/*/conf/web/*/ssl/ /home/*/conf/mail/*/ssl/ -name "*.crt" -type f -exec sh -c 'echo "$1: $(openssl x509 -enddate -noout -in "$1" 2>/dev/null)"' _ {} \;
```

### B. Check Panel SSL
```bash
sudo -n openssl x509 -enddate -noout -in /usr/local/hestia/ssl/certificate.crt
```

## 4. Common Tasks

### A. Force Global Let's Encrypt Renewal Check
```bash
sudo -n /usr/local/hestia/bin/v-update-letsencrypt-ssl
```

### B. Issue / Renew Let's Encrypt for a Specific Web Domain
```bash
# Syntax: v-add-letsencrypt-domain USER DOMAIN [ALIASES]
sudo -n /usr/local/hestia/bin/v-add-letsencrypt-domain admin example.com www.example.com
```

### C. Issue / Renew Let's Encrypt for a Specific Mail Domain
```bash
# Syntax: v-add-letsencrypt-domain USER DOMAIN "" "yes"
sudo -n /usr/local/hestia/bin/v-add-letsencrypt-domain admin example.com "" "yes"
```

### D. Disable Let's Encrypt on Web Only (Keeping Mail Let's Encrypt Active)
When a domain's website is hosted externally (e.g., Cloudflare Workers/Pages) while email remains on HestiaCP:
- Keep `mail.[DOMAIN]` (and `webmail.[DOMAIN]` if webmail is enabled) as DNS-only (`A` record pointing to the HestiaCP IP, Cloudflare proxy OFF / grey cloud) so Mail Let's Encrypt renews automatically.
- Disable Let's Encrypt **only** on the Web domain (omit the 3rd `"yes"` argument so `mail.conf` is untouched):
```bash
sudo -n /usr/local/hestia/bin/v-delete-letsencrypt-domain USER example.com
```

### E. Apply SSL to HestiaCP Panel
To secure port 8083 with the hostname's Let's Encrypt certificate:
```bash
sudo -n /usr/local/hestia/bin/v-add-letsencrypt-host
```

## 5. Troubleshooting
**Symptoms:** `Let's Encrypt validation status 400`, `LETSENCRYPT_FAIL_COUNT` increasing in `web.conf` or `mail.conf`.

1. **Check DNS & Cloudflare Proxy:**
   - For **Web LE**: `example.com` and `www.example.com` must resolve to the server or pass `/.well-known/acme-challenge/` through to HestiaCP (if a Cloudflare Worker intercepts all routes without passing `.well-known`, Web LE on HestiaCP will fail).
   - For **Mail LE**: Both `mail.example.com` AND `webmail.example.com` (unless webmail is disabled via `v-delete-mail-domain-webmail USER example.com`) must exist in DNS and point to the HestiaCP IP without Cloudflare HTTP proxy redirecting ACME challenges.
   - For **Subdomain Mail Domains** (e.g., `sub.example.com` added as a Mail Domain): HestiaCP requests `mail.sub.example.com` and `webmail.sub.example.com`. Either create those DNS `A` records, disable webmail/LE on the unused mail subdomain, or use `/etc/hestiacp/hooks/le_post.sh` (which HestiaCP invokes natively after every renewal and never overwrites during updates).
2. **Check LE Logs:**
   ```bash
   sudo -n tail -n 50 /var/log/hestia/LE-admin-example.com.log
   sudo -n tail -n 50 /var/log/hestia/LE-admin-mail.example.com.log
   ```
