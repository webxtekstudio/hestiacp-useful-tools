#!/bin/bash

# HestiaCP Custom Tools — Master Installer
# Installs scripts to /usr/local/hestia/bin and sets up configuration files in /etc
# Also cleans up old installations in /usr/local/bin
#
# Usage:
#   bash install.sh                           — install scripts + interactive setup wizard
#   bash install.sh --setup-crons             — install scripts + create/update cron entries
#   bash install.sh --setup-crons --crowdsec  — install all + crons + CrowdSec IPS
#   bash install.sh --all                     — install everything (scripts + crons + CrowdSec)
#   bash install.sh --fail2ban                — install only the Fail2Ban optimizer module
#   bash install.sh --harden                  — install only Server Hardening (Pillars 1-5)
#   bash install.sh --crowdsec                — install only Server Hardening + CrowdSec (All 6 Pillars)

set -o pipefail

# ---------------------------------------------------------------------------
# Recursion guard — prevent DPkg::Post-Invoke from re-entering this script
# when a sub-module runs apt-get during installation
# ---------------------------------------------------------------------------
[ "${HESTIA_TOOLS_INSTALLING:-}" = "1" ] && exit 0
export HESTIA_TOOLS_INSTALLING=1

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
export HESTIA="${HESTIA:-/usr/local/hestia}"
export PATH="$HESTIA/bin:/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:$PATH"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$HESTIA/bin"
CRON_FILE="/etc/cron.d/hestiacp-custom"
HESTIA_CONF="$HESTIA/conf/hestia.conf"
BAK_DIR="/var/backups/hestiacp-useful-tools"

SETUP_CRONS=false
SETUP_CROWDSEC=false
CROWDSEC_WIZARD_ONLY=false
RUN_ONLY_MODULE=""
INSTALL_ERRORS=0

# ---------------------------------------------------------------------------
# Parse arguments — flags are combinable (no early exit except single-module)
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --setup-crons) SETUP_CRONS=true ;;
        --crowdsec)    SETUP_CROWDSEC=true ;;
        --all)         SETUP_CRONS=true; SETUP_CROWDSEC=true ;;
        --fail2ban)    RUN_ONLY_MODULE="fail2ban-optimize" ;;
        --harden)      RUN_ONLY_MODULE="server-hardening" ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options (combinable):"
            echo "  --setup-crons   Create/update /etc/cron.d/hestiacp-custom with recommended schedules"
            echo "  --crowdsec      Also enable CrowdSec Collaborative IPS (Pillar 6)"
            echo "  --all           Install everything: scripts + crons + CrowdSec"
            echo ""
            echo "Single-module shortcuts:"
            echo "  --fail2ban      Install and apply only the Fail2Ban email optimizer"
            echo "  --harden        Install and apply Server Hardening (Pillars 1-5)"
            echo ""
            echo "Without flags:    Install scripts + interactive setup wizard"
            exit 0
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Single-module shortcuts (these still exit early by design)
# ---------------------------------------------------------------------------
if [ -n "$RUN_ONLY_MODULE" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Please run as root (or use sudo)"
        exit 1
    fi

    module_install="$SRC_DIR/scripts/$RUN_ONLY_MODULE/install.sh"
    if [ ! -f "$module_install" ]; then
        echo "ERROR: Module installer not found: $module_install"
        exit 1
    fi

    echo "Running single module: $RUN_ONLY_MODULE"
    bash "$module_install"
    exit $?
fi

# ---------------------------------------------------------------------------
# Full installation
# ---------------------------------------------------------------------------
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
# Helper: Smart backup — only backup when binary actually changed
# ---------------------------------------------------------------------------
safe_install_bin() {
    local src="$1"
    local name="$2"
    local dest="$DEST_DIR/$name"

    if [ ! -f "$src" ]; then
        echo "  -> [ERROR] Source not found: $src"
        return 1
    fi

    mkdir -p "$BAK_DIR"

    # Only backup if destination exists AND content differs
    if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
        cp "$dest" "$BAK_DIR/${name}.bak.$(date +%Y%m%d-%H%M%S)"
        # Keep max 3 backups per script
        ls -t "$BAK_DIR/${name}.bak."* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    fi

    cp "$src" "$dest"
    chmod +x "$dest"
    echo "  -> [OK] $name installed to $dest"
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

        # Pass --crowdsec to server-hardening if requested
        if [ "$module_name" = "server-hardening" ] && [ "$SETUP_CROWDSEC" = true ]; then
            bash "$module_dir/install.sh" --crowdsec
        else
            bash "$module_dir/install.sh"
        fi

        rc=$?
        if [ $rc -ne 0 ]; then
            echo "  -> [WARN] Module '$module_name' exited with code $rc"
            INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
        fi
    fi
done

# ---------------------------------------------------------------------------
# STEP 2: SETUP WIZARD (only on first install, only if interactive terminal)
# ---------------------------------------------------------------------------

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
# STEP 2.5: Apply CrowdSec if requested via wizard (after wizard completes)
# When --crowdsec or --all is passed via CLI, the module loop in STEP 1 already
# passes --crowdsec to server-hardening/install.sh. This block only runs when
# CrowdSec was requested interactively in the wizard.
# ---------------------------------------------------------------------------
if [ "$CROWDSEC_WIZARD_ONLY" = true ] && [ -f "$DEST_DIR/v-harden-server" ]; then
    echo ""
    echo "--- Applying CrowdSec IPS (Pillar 6) ---"
    "$DEST_DIR/v-harden-server" --crowdsec 2>&1 || {
        echo "  -> [WARN] CrowdSec setup had issues (exit code $?)"
        INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
fi

# ---------------------------------------------------------------------------
# STEP 3: CRON SETUP (from wizard or --setup-crons flag)
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
