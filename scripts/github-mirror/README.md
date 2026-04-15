# 🛠️ GitHub Mirror (`github-mirror`)

*Automatically pushes and clones private GitHub/GitLab repositories straight into your HestiaCP server. Perfect for keeping static sites (like Astro or React) automatically synced to your server for local backups.*

---

## 🚀 1. How to Install (The Easy Way)
Instead of copying files manually, use our automated installer which handles permissions and `cron` jobs automatically:
```bash
cd /root/hestiacp-useful-tools/scripts/github-mirror
bash install.sh
```

## 📂 2. File Paths (Where is everything?)
If you want to look at the files, here is exactly where the installer places them:
* **The Executable Script:** `/usr/local/hestia/bin/v-github-mirror`
* **The Target URLs List:** `/etc/hestiacp-github-mirror.conf` (Where you put your GitHub links)
* **The Settings File:** `/etc/hestiacp-github-mirror.settings` (Where you set Emails)

## ⚙️ 3. How to Configure
You need to tell the script WHICH repositories to clone and to WHICH user's folder.

1. Open `/etc/hestiacp-github-mirror.conf` in your editor (`nano /etc/hestiacp-github-mirror.conf`).
2. Add your repositories using this dummy-proof format divided by `|` pipes:
   `username|git@github.com:your-name/your-repo.git|main|web/domain.com/public_html|overwrite`
   *(This tells it: For Hestia user "username", clone that repo, using branch "main", into that folder, and "overwrite" it).*
3. Save the file.
4. **Important!** Since it's a private repo, you must go to GitHub -> Repository Settings -> Deploy Keys, and add your Server's Root SSH public key. (To get the key, type: `cat /root/.ssh/id_rsa.pub`).

## ⛔ 4. Crucial Rules (What NOT to do)
* **DO NOT** edit the `.sh` executable file directly. Your changes will be wiped on the next update! Always edit the `.conf` file in `/etc/`.
* **DO NOT** change the permissions of the executable. It must remain `755` (rwxr-xr-x) and owned by `root:root` to function correctly inside Hestia.
* **DO NOT** use HTTPS urls if your repo is private. Always use SSH URLs (`git@github.com:...`).
* **DO NOT** run this script as a normal user. It must be executed as `root`.

---

## 🔬 Advanced Architecture Notes (Geeks Only)

### Features under the hood
*   **Secure Permissions:** Automatically fixes file ownership (`chown user:user`) after pulling so HestiaCP doesn't break.
*   **Flexible Retention:** Choose between **Overwrite** (incremental git mirror) or **Versioned** (keeps the last 5 pull versions separately).
*   **Email Alerts:** Sends an HTML Server log to the Admin via Exim if a git clone/pull fails.

### CLI Testing Commands
You can test the module without activating the cron loop:
* `/usr/local/hestia/bin/v-github-mirror` (Runs the sync engine)
* `/usr/local/hestia/bin/v-github-mirror --test-email` (Sends a fake crash alert to verify your SMTP config)
* `/usr/local/hestia/bin/v-github-mirror --force-notification` (Useful to hook up to a weekly cron to receive heartbeat status emails)

### Security & Sanitization
- Replaced `eval echo "~$user"` with `getent passwd "$user"` to definitively eliminate bash command injection risks if the configuration file is contaminated.
- Replaced pipeline `ls -d | sort` with `find -print0 | sort -z` to safely handle repositories with exotic file names and spaces.
- Bound by `set -o pipefail` and `trap ERR` to email crashes.
