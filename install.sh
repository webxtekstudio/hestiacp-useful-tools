#!/bin/bash

# HestiaCP Scripts Installer
# Installs scripts to /usr/local/hestia/bin and sets up configuration files in /etc
# Also cleans up old installations in /usr/local/bin
#
# Usage:
#   bash install.sh              — install scripts + interactive setup wizard
#   bash install.sh --setup-crons  — also create/update system crontab entries

set -o pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="/usr/local/hestia/bin"
CRON_FILE="/etc/cron.d/hestiacp-custom"
SETUP_CRONS=false

# --- Parse arguments ---
for arg in "$@"; do
    case "$arg" in
        --setup-crons) SETUP_CRONS=true ;;
        --help|-h)
            echo "Usage: $0 [--setup-crons]"
            echo "  --setup-crons   Create/update /etc/cron.d/hestiacp-custom with recommended schedules"
            exit 0
            ;;
    esac
done

echo "========================================"
echo " HestiaCP Custom Tools Installer"
echo " Source: $SRC_DIR"
echo "========================================"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root"
    exit 1
fi

# Check if HestiaCP bin directory exists
if [ ! -d "$DEST_DIR" ]; then
    echo "ERROR: HestiaCP bin directory not found at $DEST_DIR"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

install_script() {
    local src="$1"
    local script_name="$2"
    local dest="$DEST_DIR/$script_name"
    local old_dest="/usr/local/bin/$script_name"

    if [ -f "$src" ]; then
        if [ -f "$dest" ]; then
            local bak="${dest}.bak.$(date +%Y%m%d-%H%M%S)"
            cp "$dest" "$bak" && echo "  -> Backed up existing: $bak"
        fi
        cp "$src" "$dest"
        chmod +x "$dest"
        echo "  -> [OK] $script_name installed to $dest"

        if [ -f "$old_dest" ]; then
            rm -f "$old_dest"
            echo "  -> Removed legacy: $old_dest"
        fi
    else
        echo "  -> [ERROR] Source not found: $src"
    fi
}

install_symlink() {
    local src="$1"
    local script_name="$2"
    local dest="$DEST_DIR/$script_name"
    local old_dest="/usr/local/bin/$script_name"

    if [ -f "$src" ]; then
        rm -f "$dest"
        ln -sf "$src" "$dest"
        chmod +x "$src"
        echo "  -> [OK] $script_name symlinked to $dest"

        if [ -f "$old_dest" ]; then
            rm -f "$old_dest"
            echo "  -> Removed legacy: $old_dest"
        fi
    else
        echo "  -> [ERROR] Source not found: $src"
    fi
}

install_config() {
    local src="$1"
    local dest="$2"

    if [ ! -f "$dest" ]; then
        if [ -f "$src" ]; then
            cp "$src" "$dest"
            echo "  -> [OK] Config installed: $dest"
        else
            echo "  -> [ERROR] Sample config not found: $src"
        fi
    else
        echo "  -> [INFO] Config already exists (skipped): $dest"
    fi
}

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
        bash "$module_dir/install.sh"
    fi
done

# ---------------------------------------------------------------------------
# STEP 2: SETUP WIZARD (only on first install, only if interactive terminal)
# ---------------------------------------------------------------------------

HESTIA_CONF="/usr/local/hestia/conf/hestia.conf"
backup_system=$(grep "^BACKUP_SYSTEM=" "$HESTIA_CONF" 2>/dev/null | cut -d"'" -f2)

# Show wizard if: remote backup not configured AND we're in a terminal
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
                if v-add-backup-host b2 "$b2_bucket" "$b2_keyid" "$b2_appkey" 2>&1; then
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
                if v-add-backup-host sftp "$sftp_host" "$sftp_user" "$sftp_pass" "$sftp_path" "$sftp_port" 2>&1; then
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
                if v-add-backup-host ftp "$ftp_host" "$ftp_user" "$ftp_pass" "$ftp_path" "$ftp_port" 2>&1; then
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
fi

# ---------------------------------------------------------------------------
# STEP 3: CRON SETUP (from wizard or --setup-crons flag)
# ---------------------------------------------------------------------------

if [ "$SETUP_CRONS" = true ]; then
    echo ""
    echo "--- Setting Up Cron Jobs ---"

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

    chmod 644 "$CRON_FILE"
fi

# ---------------------------------------------------------------------------
# DONE
# ---------------------------------------------------------------------------

backup_system=$(grep "^BACKUP_SYSTEM=" "$HESTIA_CONF" 2>/dev/null | cut -d"'" -f2)

echo ""
echo "========================================"
echo " ✅ Installation complete!"
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
