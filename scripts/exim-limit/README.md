# 🛠️ Exim Limit Monitor (`exim-limit`)

*Automatically blocks users from sending giant email attachments (like huge PDFs) which protects your server from being blacklisted by Google or Microsoft.*

---

## 🚀 1. How to Install (The Easy Way)
Instead of copying files manually, use the module installer to place the script, monitor helper, and default config:
```bash
cd /root/hestiacp-useful-tools/scripts/exim-limit
bash install.sh
```

Then apply the Exim patch and install the monitor cron:

```bash
v-add-exim-limit
```

## 📂 2. File Paths (Where is everything?)
If you want to look at the files, here is exactly where the installer places them:
* **The Executable Script:** `/usr/local/hestia/bin/v-add-exim-limit`
* **The Monitor Helper:** `/usr/local/hestia/bin/monitor_large_emails.py` (copied to `/usr/local/bin/monitor_large_emails.py` when `v-add-exim-limit` is applied)
* **The Configuration File:** `/etc/hestiacp-exim-limit.conf`

## ⚙️ 3. How to Configure
By default, the script will:
- Block outgoing emails larger than 25MB (while allowing users to receive large incoming emails).
- Block unauthenticated external senders that forge any local HestiaCP domain (`+local_domains`) in the visual `From:` header (`BLOCK_HEADER_FROM_SPOOF="TRUE"`), closing the loophole where attackers use an empty `Return-Path: <>` bounce envelope or multi-address `From:` headers to bypass HestiaCP's default `acl_check_rcpt` `sender_domains` check.

> **Using External ESPs (SendGrid, Amazon SES, Mailgun, Brevo):**
> Because the `acl_check_data` rule includes `hosts = !+relay_from_hosts : !+whitelist`, any unauthenticated third-party service that legitimately sends emails with `From: @yourdomain.com` **into** a local mailbox on this server should have its outbound IP/CIDR added to HestiaCP's native whitelist at `/etc/exim4/white-blocks.conf` (one IP or CIDR per line, no Exim restart needed).

1. Open `/etc/hestiacp-exim-limit.conf` in your editor (`nano /etc/hestiacp-exim-limit.conf`).
2. Change the variables you want. For example, if you want to block BOTH incoming and outgoing large emails to save disk space, change `LIMIT_OUTGOING_ONLY="TRUE"` to `LIMIT_OUTGOING_ONLY="FALSE"`, or set `BLOCK_HEADER_FROM_SPOOF="FALSE"` to disable header `From:` anti-spoofing.
3. Save the file.
4. **IMPORTANT:** Unlike other tools, Exim requires you to reload the rules manually. After editing the config file, you must run: `v-add-exim-limit` to apply the changes!

## ⛔ 4. Crucial Rules (What NOT to do)
* **DO NOT** edit the `.sh` executable file directly. Your changes will be wiped on the next update! Always edit the `.conf` file in `/etc/`.
* **DO NOT** change the permissions of the executable. It must remain `755` (rwxr-xr-x) and owned by `root:root` to function correctly inside Hestia.
* **DO NOT** run this script manually as a normal user. It must be executed as `root`.

---

## 🔬 Advanced Architecture Notes (Geeks Only)

### How it works
This tool injects custom ACL rules into `/etc/exim4/exim4.conf.template` inside the `acl_check_data` block:
1. **Large Attachment Guard:** Sends a custom 550 User-Friendly Message directly to the email client (Outlook/Apple Mail) when an authenticated user exceeds 25MB.
2. **Dynamic `From:` Header Anti-Spoofing (`+local_domains`):** HestiaCP's default `acl_check_rcpt` only checks `sender_domains = +local_domains` on the SMTP envelope (`MAIL FROM`). Attackers bypass this using `MAIL FROM:<>` (null bounce sender) or external envelope senders while forging `From: user@yourdomain.com` in the `DATA` headers. This rule uses `forany{${addresses:$h_from:}}{match_domain{${lc:${domain:$item}}}{+local_domains}}{yes}{no}}` against `+local_domains` (`dsearch;/etc/exim4/domains/`), inspecting every address in the `From:` header and automatically protecting all existing and future HestiaCP domains while respecting `/etc/exim4/white-blocks.conf` (`+whitelist`).

### Python Monitoring Daemon (Included)
When `v-add-exim-limit` is applied, it also sets up a python listener (`monitor_large_emails.py`) hooked into root's cron. It aggressively tails `/var/log/exim4/mainlog` looking for the exact custom 552 rejection string. When it detects an active block, it triggers an instant administrative email alert telling you which user tried to send the giant file.

**Testing the Monitor:**
You can test the exact email delivery by running:
`/usr/local/bin/monitor_large_emails.py --test`
This will send a test alert directly to your `ADMIN_EMAIL` bypassing the log validation.
