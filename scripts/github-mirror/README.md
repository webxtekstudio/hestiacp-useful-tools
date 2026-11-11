# 🛠️ GitHub Mirror (`github-mirror`)

*Automatically clones and syncs private or public GitHub/GitLab repositories into a HestiaCP user's dedicated `git/` directory (or `web/<domain>/private/`) using a **Zero-Trust Pull-Only Architecture** — so HestiaCP backups (`v-backup-users` / Restic) include up-to-date source code snapshots without ever exposing Git credentials to tenant accounts or `public_html`.*

---

## 🚀 1. How to Install (The Easy Way)
Instead of copying files manually, use the module installer to place the script, default configs (`0600 root:root`), and pin GitHub's official Ed25519 SSH host key in `/root/.ssh/known_hosts`. To add the recommended 12-hour sync schedule, run the repository root installer with `--setup-crons`.
```bash
cd /root/hestiacp-useful-tools/scripts/github-mirror
bash install.sh
```

## 📂 2. File Paths (Where is everything?)
* **The Executable Script:** `/usr/local/hestia/bin/v-github-mirror`
* **The Target URLs List:** `/etc/hestiacp-github-mirror.conf` (`0600 root:root` — where you list your repositories)
* **The Optional Read-Only PAT File:** `/etc/hestiacp-github-mirror.token` (`0400`/`0600 root:root` — Fine-Grained Read-Only GitHub Personal Access Token for HTTPS private repos)
* **The Settings File:** `/etc/hestiacp-github-mirror.settings` (`0600 root:root` — notification & backup retention settings)
* **Isolated Root Staging Directory:** `/var/lib/hestiacp-github-mirror` (`0711 root:root`)
* **Execution Log:** `/var/log/hestia/github-mirror.log` (`0640`)

## ⚙️ 3. How to Configure
You need to tell the script WHICH repositories to clone and into WHICH user's folder (recommended: `git/<repo-name>`, which creates `/home/<user>/git/<repo-name>` with `0700` permissions and is backed up automatically by HestiaCP as `User Directory: git` without coupling repositories to any single web domain).

1. Open `/etc/hestiacp-github-mirror.conf` in your editor (`nano /etc/hestiacp-github-mirror.conf`).
2. Add your repositories using the pipe-delimited (`|`) format:
   ```text
   # Format: USER|REPO_URL|BRANCH|DESTINATION_PATH_RELATIVE_TO_HOME|RETENTION_MODE|RETENTION_COUNT
   admin|https://github.com/your-org/repo.git|main|git/repo|overwrite
   client1|git@github.com:your-org/website-source.git|production|git/website-source|versioned|5
   ```
3. **Authentication for Private Repositories (Choose Option A or Option B):**
   * **Option A — Fine-Grained Read-Only Token over HTTPS (Recommended):**
     Create a GitHub Fine-Grained Personal Access Token with **`Contents: Read-only`** permission, save it into `/etc/hestiacp-github-mirror.token`, and lock permissions:
     ```bash
     chmod 400 /etc/hestiacp-github-mirror.token
     chown root:root /etc/hestiacp-github-mirror.token
     ```
     The script injects the token transiently as root via HTTP header (`GIT_CONFIG_VALUE_0`) during staging — it is **never** written to `.git/config` or command-line arguments.
   * **Option B — Root SSH Deploy Key:**
     Add `/root/.ssh/id_ed25519.pub` (or `/root/.ssh/id_rsa.pub`) as a Read-Only Deploy Key on your GitHub repository and use `git@github.com:org/repo.git`.

## ⛔ 4. Crucial Rules (What NOT to do)
* **DO NOT** mirror repositories directly into `public_html` unless intentional — always use `git/<repo>` (recommended) or `web/<domain>/private/<folder>` so `.git` metadata and source files stay out of public web reach while still being included in HestiaCP user backups.
* **DO NOT** edit the executable `/usr/local/hestia/bin/v-github-mirror` directly. Always edit `/etc/hestiacp-github-mirror.conf` and `/etc/hestiacp-github-mirror.settings`.
* **DO NOT** run this script as a normal user. It must be executed as `root`.

---

## 🔬 Advanced Architecture Notes (Geeks Only)

### Zero-Trust Pull-Only Security Model
1. **Pull-Only Root Staging:** Network `git ls-remote` / `git fetch` / `git clone --bare` runs exclusively as `root` inside `/var/lib/hestiacp-github-mirror` (and scrubs staged metadata once synced).
2. **Offline Tenant Repositories:** Local fetches/resets inside `/home/<user>/...` run as the unprivileged HestiaCP user with `protocol.allow=never`, `GIT_SSH_COMMAND=/bin/false`, and `core.hooksPath=/dev/null`.
3. **Sanitized `.git/config` (`0700`):** Before and after each sync, `_sanitize_user_git_repo` atomically overwrites the tenant's `.git/config` (removing all `remote "origin"` URLs, hooks, filters, and `fsmonitor` directives) and locks the mirror directory to `0700 <user>:<user>`. Even if a tenant account is compromised, the attacker cannot read GitHub credentials or push back upstream.

### Flexible Retention Modes
* **`overwrite`:** Keeps a single live mirror synced to the latest commit on the configured branch.
* **`versioned|<N>`:** Keeps the last `N` timestamped snapshots (`v_YYYYMMDD_HHMMSS`).
* **`backup`:** Keeps GFS-style Daily/Weekly/Monthly snapshots when enabled in `/etc/hestiacp-github-mirror.settings`.

### CLI Testing Commands
* `/usr/local/hestia/bin/v-github-mirror` (Runs the sync engine)
* `/usr/local/hestia/bin/v-github-mirror --test-email` (Sends a test alert to verify your SMTP config)
* `/usr/local/hestia/bin/v-github-mirror --force-notification` (Used by the weekly Sunday `06:00` cron to send a heartbeat summary email even when all syncs succeed)
