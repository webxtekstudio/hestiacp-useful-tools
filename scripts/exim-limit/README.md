# 🛠️ Exim Limit Monitor (`exim-limit`)

*Automatically blocks users from sending giant email attachments (like huge PDFs) which protects your server from being blacklisted by Google or Microsoft.*

---

## 🚀 1. How to Install (The Easy Way)
Instead of copying files manually, use our automated installer which handles permissions and `cron` jobs automatically:
```bash
cd /root/hestiacp-useful-tools/scripts/exim-limit
bash install.sh
```

## 📂 2. File Paths (Where is everything?)
If you want to look at the files, here is exactly where the installer places them:
* **The Executable Script:** `/usr/local/hestia/bin/v-add-exim-limit`
* **The Configuration File:** `/etc/hestiacp-exim-limit.conf`

## ⚙️ 3. How to Configure
By default, the script will block outgoing emails larger than 10MB, but will allow your users to receive large incoming emails perfectly.

1. Open `/etc/hestiacp-exim-limit.conf` in your editor (`nano /etc/hestiacp-exim-limit.conf`).
2. Change the variables you want. For example, if you want to block BOTH incoming and outgoing emails to save disk space, change `LIMIT_OUTGOING_ONLY="TRUE"` to `LIMIT_OUTGOING_ONLY="FALSE"`.
3. Save the file.
4. **IMPORTANT:** Unlike other tools, Exim requires you to reload the rules manually. After editing the config file, you must run: `v-add-exim-limit` to apply the changes!

## ⛔ 4. Crucial Rules (What NOT to do)
* **DO NOT** edit the `.sh` executable file directly. Your changes will be wiped on the next update! Always edit the `.conf` file in `/etc/`.
* **DO NOT** change the permissions of the executable. It must remain `755` (rwxr-xr-x) and owned by `root:root` to function correctly inside Hestia.
* **DO NOT** run this script manually as a normal user. It must be executed as `root`.

---

## 🔬 Advanced Architecture Notes (Geeks Only)

### How it works
This tool injects a custom ACL rule into `/etc/exim4/exim4.conf.template` at the `acl_check_message` block.
It sends a custom 552 User-Friendly Message directly to the email client (Outlook/Apple Mail) saying exactly: *"Message size exceeds 10MB limit. Please use WeTransfer or Google Drive."*

### Python Monitoring Daemon (Included)
The installer also sets up a python listener (`monitor_large_emails.py`) hooked into root's cron. It aggressively tails `/var/log/exim4/mainlog` looking for the exact custom 552 rejection string. When it detects an active block, it triggers an instant administrative email alert telling you which user tried to send the giant file.

**Testing the Monitor:**
You can test the exact email delivery by running:
`/usr/local/hestia/bin/monitor_large_emails.py --test`
This will send a test alert directly to your `ADMIN_EMAIL` bypassing the log validation.

