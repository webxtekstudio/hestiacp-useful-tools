#!/bin/bash

# HestiaCP Custom Tools — Master Installer
# Installs scripts to /usr/local/hestia/bin and sets up configuration files in /etc
#
# Usage:
#   bash install.sh                           — install all scripts + interactive setup wizard
#   bash install.sh --setup-crons             — install all scripts + create/update cron entries
#   bash install.sh --setup-crons --crowdsec  — install all + crons + CrowdSec IPS
#   bash install.sh --all                     — install everything (all scripts + crons + CrowdSec)
#   bash install.sh --fail2ban                — standalone: install & apply Fail2Ban email optimizer
#   bash install.sh --harden                  — standalone: install & apply Server Hardening (Pillars 1-5)
#   bash install.sh --crowdsec                — standalone: install & apply Server Hardening + CrowdSec (Pillars 1-6)

set -o pipefail

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
export HESTIA="${HESTIA:-/usr/local/hestia}"
export PATH="$HESTIA/bin:/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:$PATH"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$HESTIA/bin"
CRON_FILE="/etc/cron.d/hestiacp-custom"
HESTIA_CONF="$HESTIA/conf/hestia.conf"

SETUP_CRONS=false
SETUP_CROWDSEC=false
FULL_INSTALL_ALL=false
WANT_FAIL2BAN_ONLY=false
WANT_HARDEN_ONLY=false
CROWDSEC_WIZARD_ONLY=false
RUN_ONLY_MODULE=""
RUN_ONLY_ARGS=()
INSTALL_ERRORS=0
ORIG_ARGC=$#

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Full installation options (combinable):"
    echo "  --setup-crons             Create/update /etc/cron.d/hestiacp-custom schedules"
    echo "  --setup-crons --crowdsec  Install all modules + crons + CrowdSec IPS (Pillar 6)"
    echo "  --all                     Install everything: all modules + crons + CrowdSec IPS"
    echo ""
    echo "Standalone single-module shortcuts:"
    echo "  --fail2ban                Install and apply only the Fail2Ban email optimizer"
    echo "  --harden                  Install and apply only Server Hardening (Pillars 1-5)"
    echo "  --crowdsec                Install and apply only Server Hardening + CrowdSec (All 6 Pillars)"
    echo ""
    echo "Without flags:              Install all modules + interactive setup wizard"
}

# ---------------------------------------------------------------------------
# 1. Parse & validate CLI arguments FIRST (no root or lock side effects yet)
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --setup-crons) SETUP_CRONS=true ;;
        --crowdsec)    SETUP_CROWDSEC=true ;;
        --all)         FULL_INSTALL_ALL=true; SETUP_CRONS=true; SETUP_CROWDSEC=true ;;
        --fail2ban)    WANT_FAIL2BAN_ONLY=true ;;
        --harden)      WANT_HARDEN_ONLY=true ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Resolve standalone vs full-install flag combinations without silent drops
if [ "$WANT_FAIL2BAN_ONLY" = true ]; then
    if [ "$WANT_HARDEN_ONLY" = true ] || [ "$SETUP_CROWDSEC" = true ] || [ "$SETUP_CRONS" = true ] || [ "$FULL_INSTALL_ALL" = true ]; then
        echo "ERROR: --fail2ban is a standalone module shortcut and cannot be combined with other flags." >&2
        exit 1
    fi
    RUN_ONLY_MODULE="fail2ban-optimize"
    RUN_ONLY_ARGS=("--force")
elif [ "$WANT_HARDEN_ONLY" = true ]; then
    if [ "$SETUP_CRONS" = true ] || [ "$FULL_INSTALL_ALL" = true ]; then
        echo "ERROR: --harden is a standalone module shortcut; omit --harden to install all modules." >&2
        exit 1
    fi
    RUN_ONLY_MODULE="server-hardening"
    [ "$SETUP_CROWDSEC" = true ] && RUN_ONLY_ARGS=("--crowdsec")
elif [ "$SETUP_CROWDSEC" = true ] && [ "$SETUP_CRONS" = false ] && [ "$FULL_INSTALL_ALL" = false ]; then
    # Standalone 'bash install.sh --crowdsec' installs only Server Hardening (All 6 Pillars)
    RUN_ONLY_MODULE="server-hardening"
    RUN_ONLY_ARGS=("--crowdsec")
fi

# ---------------------------------------------------------------------------
# 2. Enforce root execution BEFORE acquiring system locks
# ---------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Recursion & concurrency guard
#    - Env guard catches direct child re-entry (e.g. sub-module -> apt -> DPkg::Post-Invoke)
#    - Kernel flock in root-owned /run prevents concurrent runs without /tmp symlink/DoS risk
#    - Sub-processes run with 9>&- so no child or daemon inherits the lock FD
# ---------------------------------------------------------------------------
[ "${HESTIA_TOOLS_INSTALLING:-}" = "1" ] && exit 0
export HESTIA_TOOLS_INSTALLING=1

LOCK_DIR="/run"
[ -d "$LOCK_DIR" ] || LOCK_DIR="/var/lock"
LOCK_FILE="$LOCK_DIR/hestiacp-useful-tools.lock"

if command -v flock >/dev/null 2>&1; then
    (umask 077 && : >> "$LOCK_FILE") 2>/dev/null || true
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "[INFO] Another HestiaCP tools installation is already in progress — skipping."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# 4. Single-module shortcuts
# ---------------------------------------------------------------------------
if [ -n "$RUN_ONLY_MODULE" ]; then
    module_install="$SRC_DIR/scripts/$RUN_ONLY_MODULE/install.sh"
    if [ ! -f "$module_install" ]; then
        echo "ERROR: Module installer not found: $module_install" >&2
        exit 1
    fi

    echo "Running single module: $RUN_ONLY_MODULE"
    bash "$module_install" ${RUN_ONLY_ARGS[@]+"${RUN_ONLY_ARGS[@]}"} 9>&-
    exit $?
fi

# ---------------------------------------------------------------------------
# 5. Full installation
# ---------------------------------------------------------------------------
echo "========================================"
echo " HestiaCP Custom Tools Installer"
echo " Source: $SRC_DIR"
echo "========================================"

if [ ! -d "$DEST_DIR" ]; then
    echo "ERROR: HestiaCP bin directory not found at $DEST_DIR" >&2
    exit 1
fi

add_cron_entry() {
    local tag="$1"
    local schedule="$2"
    local command="$3"

    if grep -q "# hestiacp-custom:$tag" "$CRON_FILE" 2>/dev/null; then
        echo "  -> [INFO] Cron already exists: $tag (skipped)"
    else
        {
            echo "# hestiacp-custom:$tag"
            echo "$schedule $command"
            echo ""
        } >> "$CRON_FILE"
        echo "  -> [OK] Cron added: $tag ($schedule)"
    fi
}

# ---------------------------------------------------------------------------
# STEP 1: INSTALL ALL MODULES
# ---------------------------------------------------------------------------

echo ""
echo "--- Installing Modules ---"

for module_dir in "$SRC_DIR/scripts"/*; do
    [ -d "$module_dir" ] || continue
    module_name=$(basename "$module_dir")

    if [ -f "$module_dir/install.sh" ]; then
        echo "Installing module: $module_name"

        if [ "$module_name" = "server-hardening" ] && [ "$SETUP_CROWDSEC" = true ]; then
            bash "$module_dir/install.sh" --crowdsec 9>&-
        else
            bash "$module_dir/install.sh" 9>&-
        fi

        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "  -> [WARN] Module '$module_name' exited with code $rc"
            INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
        fi
    fi
done

# ---------------------------------------------------------------------------
# STEP 2: SETUP WIZARD (only on first install, only if interactive terminal)
# ---------------------------------------------------------------------------

backup_system=$(grep "^BACKUP_SYSTEM=" "$HESTIA_CONF" 2>/dev/null | cut -d"'" -f2)

if ! echo "$backup_system" | grep -qE "b2|sftp|ftp|rclone" && [ -t 0 ]; then
    echo ""
    echo "========================================"
    echo " Setup Wizard"
    echo "========================================"
    echo ""
    echo "Backups are currently saved to disk only (local)."
    echo "All features (folder organization, retention, reports)"
    echo "work in local mode — no cloud account needed."
    echo ""
    echo "Optionally, you can also send copies to a remote destination:"
    echo ""
    echo "  1) Local only      — backups stay on this server (default)"
    echo "  2) Backblaze B2    — cheap cloud storage (~\$0.005/GB/month)"
    echo "  3) SFTP            — backup to another server via SSH"
    echo "  4) FTP             — classic FTP server"
    echo ""
    read -rp "Choose [1-4] (default: 1): " backup_choice
    backup_choice=${backup_choice:-1}

    case "$backup_choice" in
        2)
            echo ""
            echo "--- Backblaze B2 Setup ---"
            echo ""
            echo "You need 3 things from https://www.backblaze.com:"
            echo "  1. Create a B2 Bucket (B2 Cloud Storage → Buckets)"
            echo "  2. Create an App Key (App Keys → Add a New Application Key)"
            echo "  3. Copy the Key ID and Application Key"
            echo ""
            read -rp "  Bucket name: " b2_bucket
            read -rp "  Key ID:      " b2_keyid
            read -rp "  App Key:     " b2_appkey
            if [ -n "$b2_bucket" ] && [ -n "$b2_keyid" ] && [ -n "$b2_appkey" ]; then
                echo ""
                if v-add-backup-host b2 "$b2_bucket" "$b2_keyid" "$b2_appkey" 9>&- 2>&1; then
                    echo "  ✅ Backblaze B2 configured! Backups will be saved locally + uploaded to B2."
                else
                    echo "  ❌ Failed. You can try manually later:"
                    echo "     v-add-backup-host b2 $b2_bucket $b2_keyid YOUR_APP_KEY"
                fi
            else
                echo "  Skipped — missing credentials."
            fi
            ;;
        3)
            echo ""
            echo "--- SFTP Setup ---"
            echo ""
            read -rp "  Host (e.g. backup.example.com): " sftp_host
            read -rp "  Username:                       " sftp_user
            read -rsp "  Password:                       " sftp_pass
            echo ""
            read -rp "  Remote path (default: /backup):  " sftp_path
            sftp_path=${sftp_path:-/backup}
            read -rp "  Port (default: 22):              " sftp_port
            sftp_port=${sftp_port:-22}
            if [ -n "$sftp_host" ] && [ -n "$sftp_user" ]; then
                echo ""
                if v-add-backup-host sftp "$sftp_host" "$sftp_user" "$sftp_pass" "$sftp_path" "$sftp_port" 9>&- 2>&1; then
                    echo "  ✅ SFTP configured! Backups will be saved locally + uploaded via SFTP."
                else
                    echo "  ❌ Failed. Try manually: v-add-backup-host sftp HOST USER PASSWORD"
                fi
            fi
            ;;
        4)
            echo ""
            echo "--- FTP Setup ---"
            echo ""
            read -rp "  Host (e.g. ftp.example.com): " ftp_host
            read -rp "  Username:                    " ftp_user
            read -rsp "  Password:                    " ftp_pass
            echo ""
            read -rp "  Remote path (default: /backup): " ftp_path
            ftp_path=${ftp_path:-/backup}
            read -rp "  Port (default: 21):             " ftp_port
            ftp_port=${ftp_port:-21}
            if [ -n "$ftp_host" ] && [ -n "$ftp_user" ]; then
                echo ""
                if v-add-backup-host ftp "$ftp_host" "$ftp_user" "$ftp_pass" "$ftp_path" "$ftp_port" 9>&- 2>&1; then
                    echo "  ✅ FTP configured! Backups will be saved locally + uploaded via FTP."
                else
                    echo "  ❌ Failed. Try manually: v-add-backup-host ftp HOST USER PASSWORD"
                fi
            fi
            ;;
        *)
            echo ""
            echo "  ✅ Local-only mode selected. Backups will stay on this server."
            echo "  You can add remote backup anytime with: v-add-backup-host"
            ;;
    esac

    # --- Cron setup ---
    echo ""
    echo "---"
    echo ""
    echo "Do you want to set up automatic cron schedules?"
    echo "(cleanup, reports, security audit, GitHub mirror, etc.)"
    echo ""
    read -rp "Set up crons? [Y/n]: " setup_crons_answer
    setup_crons_answer=${setup_crons_answer:-Y}
    if [[ "$setup_crons_answer" =~ ^[Yy] ]]; then
        SETUP_CRONS=true
    fi

    # --- CrowdSec question ---
    if [ "$SETUP_CROWDSEC" != true ]; then
        echo ""
        echo "---"
        echo ""
        echo "Do you want to enable CrowdSec Collaborative IPS? (Pillar 6)"
        echo "This adds real-time community threat intelligence and nftables bouncing."
        echo ""
        read -rp "Enable CrowdSec? [y/N]: " crowdsec_answer
        crowdsec_answer=${crowdsec_answer:-N}
        if [[ "$crowdsec_answer" =~ ^[Yy] ]]; then
            SETUP_CROWDSEC=true
            CROWDSEC_WIZARD_ONLY=true
            echo "  -> CrowdSec will be configured after cron setup."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# STEP 3: CRON SETUP (from wizard or --setup-crons / --all flag)
# ---------------------------------------------------------------------------

if [ "$SETUP_CRONS" = true ]; then
    echo ""
    echo "--- Setting Up Cron Jobs ---"

    # Ensure log directories exist
    mkdir -p /var/log/hestia/security-audit

    if [ ! -f "$CRON_FILE" ]; then
        cat > "$CRON_FILE" << 'CRONHEADER'
# HestiaCP Custom Tools — Cron Schedule
# Managed by install.sh — re-run with --setup-crons to update
SHELL=/bin/bash
PATH=/usr/local/hestia/bin:/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

CRONHEADER
        echo "  -> Created $CRON_FILE"
    fi

    ts="$(date +%Y%m%d-%H%M%S)"
    for legacy_cron in /etc/cron.d/hestia-github-mirror /etc/cron.d/hestia-github-mirror-weekly; do
        if [ -f "$legacy_cron" ]; then
            mv "$legacy_cron" "${legacy_cron}.disabled.${ts}"
            echo "  -> Disabled legacy cron: $legacy_cron"
        fi
    done

    add_cron_entry "clean-garbage" \
        "30 4 * * 0" \
        "root /usr/local/hestia/bin/v-clean-garbage >> /var/log/hestia/clean-garbage.log 2>&1"

    add_cron_entry "github-mirror-sync" \
        "0 */12 * * *" \
        "root /usr/local/hestia/bin/v-github-mirror >> /var/log/hestia/github-mirror.cron.log 2>&1"

    add_cron_entry "github-mirror-weekly-report" \
        "0 6 * * 0" \
        "root /usr/local/hestia/bin/v-github-mirror --force-notification >> /var/log/hestia/github-mirror.cron.log 2>&1"

    add_cron_entry "system-report" \
        "0 8 * * 0" \
        "root /usr/local/hestia/bin/v-system-report >> /var/log/hestia/system-report.log 2>&1"

    add_cron_entry "security-audit" \
        "0 7 * * 0" \
        "root /usr/local/hestia/bin/v-security-audit --system --backend --quiet --email >> /var/log/hestia/security-audit/weekly.log 2>&1"

    add_cron_entry "server-hardening-heal" \
        "50 4 * * *" \
        "root /usr/local/hestia/bin/v-harden-server --cron-heal >> /var/log/hestia/server-hardening.log 2>&1"

    chmod 644 "$CRON_FILE"
fi

# ---------------------------------------------------------------------------
# STEP 4: Apply CrowdSec if requested interactively in the Setup Wizard
# (When --all or --setup-crons --crowdsec is passed via CLI, STEP 1 already
# ran server-hardening/install.sh --crowdsec.)
# ---------------------------------------------------------------------------
if [ "$CROWDSEC_WIZARD_ONLY" = true ] && [ -x "$DEST_DIR/v-harden-server" ]; then
    echo ""
    echo "--- Applying CrowdSec IPS (Pillar 6) ---"
    "$DEST_DIR/v-harden-server" --crowdsec 9>&- 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  -> [WARN] CrowdSec setup had issues (exit code $rc)"
        INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# DONE
# ---------------------------------------------------------------------------

backup_system=$(grep "^BACKUP_SYSTEM=" "$HESTIA_CONF" 2>/dev/null | cut -d"'" -f2)

echo ""
echo "========================================"
if [ "$INSTALL_ERRORS" -gt 0 ]; then
    echo " ⚠️  Installation complete with $INSTALL_ERRORS warning(s)"
else
    echo " ✅ Installation complete!"
fi
echo "========================================"
echo ""
echo " Scripts:  $DEST_DIR"
echo " Configs:  /etc/hestiacp-*.conf"
if [ "$SETUP_CRONS" = true ]; then
    echo " Crons:    $CRON_FILE"
fi
echo " Backups:  ${backup_system:-local}"
echo ""
echo " Next steps:"
echo "   1. Test backup via Server interface or:  v-backup-user admin"
if [ "$SETUP_CRONS" != true ]; then
    echo "   2. Setup optional tool crons:  bash install.sh --setup-crons"
fi
echo ""
echo "========================================"

if [ "$INSTALL_ERRORS" -gt 0 ] && { [ "$ORIG_ARGC" -gt 0 ] || [ -t 0 ]; }; then
    exit 1
fi
exit 0
