# 🛠️ Fix Web Permissions (`fix-web-permissions`)

*A powerful rescue tool. If you uploaded files via FTP/SFTP and your WordPress site crashed with a "403 Forbidden" error, or if you can't upload images, this tool instantly repairs all file ownerships and permissions back to the correct HestiaCP standards.*

---

## 🚫 1. MASSIVE DANGER WARNING (READ THIS FIRST)
> [!CAUTION]
> **This is a highly destructive tool if misused.**
> It sweeps through your entire `public_html` directory and forcibly alters the permissions (`chmod`) and ownership (`chown`) of thousands of files in milliseconds. 
> 
> **NEVER** run this simultaneously with a backup operation.
> **NEVER** interrupt this script (Ctrl+C) while it is running, or you will leave your files in an unreadable half-state and your websites will permanently 403 crash. Let it finish!

## 🚀 2. How to Install (The Easy Way)
Instead of copying files manually, use our automated installer which handles permissions automatically:
```bash
cd /root/hestiacp-useful-tools/scripts/fix-web-permissions
bash install.sh
```

## 📂 3. File Paths (Where is everything?)
If you want to look at the files, here is exactly where the installer places them:
* **The Executable Script:** `/usr/local/hestia/bin/v-fix-web-permissions`
* **The Error Logs:** `/var/log/hestia/fix-permissions/` (Where it saves the list of every file it touched).

## ⚙️ 4. How to Use (The Dummy-Proof Way)
There is no configuration file for this script. It is an "on-demand" rescue tool.
To run it safely on a specific broken domain, use this command:

```bash
v-fix-web-permissions admin example.com
```
*(Replace `admin` with the Hestia username, and `example.com` with the broken site).*

If you are totally lost and want it to repair **every single website on the server** automatically:
```bash
v-fix-web-permissions --all
```

## ⛔ 5. Crucial Rules (What NOT to do)
* **DO NOT** edit the `.sh` executable file directly. 
* **DO NOT** change the permissions of the executable. It must remain `755` (rwxr-xr-x) and owned by `root:root`.
* **DO NOT** run this script as a normal user. It must be executed as `root` to forcefully overwrite file ownerships.

---

## 🔬 Advanced Architecture Notes (Geeks Only)

### Security Scan Features
Runs automatically on **every domain** regardless of CMS:
| Check | Action |
|---|---|
| `.git/` inside `public_html` | `[WARN]` — exposes entire codebase and history |
| `.env` inside `public_html` | `[WARN]` + hardened to `640` |
| `install/`, `installation/`, `setup/` directories | `[WARN]` — must be removed from production |
| `phpinfo.php`, `test.php`, `info.php`, `debug.php` | `[WARN]` — remove debug files |
| `composer.json` / `composer.lock` in `public_html` | `[WARN]` — exposes dependency versions |

### Base File Fixes (all CMS types)
| Operation | Detail |
|---|---|
| **Ownership** | Recursive `chown user:user` on `public_html/` |
| **Over-permissive dirs** | Fixes dirs with world-write bit (`/002`) → `755` |
| **Over-permissive files** | Fixes files with group/world-write bit (`/022`) → `644` |
| **Never made more permissive** | Files already at `400`, `440`, `444`, `600` etc. are left alone |

*Note: The script features advanced CMS autodetection for Laravel, Symfony, WordPress, Drupal, Joomla, Magento, PrestaShop, and OpenCart, applying bespoke `wp-config.php` and `.env` 640-level hardening rules per framework.*

### Advanced CLI Usage & Filters
```bash
# Audit entire server (read-only, no changes)
v-fix-web-permissions --all --audit

# Dry-run — show what would change without applying
v-fix-web-permissions --all --dry

# Force Drupal mode and audit a specific domain
v-fix-web-permissions admin example.com --drupal --audit

# Fix only WP sites for a specific user
v-fix-web-permissions johndoe --filter-wordpress
```

### Safety Sentinel Feature
If a domain uses custom permissions (CGI, custom PHP-FPM pools), create this file to permanently skip it:
`touch /home/USER/web/DOMAIN/public_html/.no-fix-permissions`
