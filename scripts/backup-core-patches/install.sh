#!/bin/bash
# scripts/backup-core-patches/install.sh
# Installation module for the Backup Native Patches

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
HESTIA_BIN="$HESTIA/bin"
HESTIA_CONF="$HESTIA/conf/hestia.conf"
RETENTION_CONF="/etc/hestiacp-backup-retention.conf"

echo "--- Installing Backup Core Patches ---"

# 1. Cleanup old wrapper system (Migration from v1 architecture)
if [ -L "$HESTIA_BIN/v-backup-users-custom" ] || [ -f "$HESTIA_BIN/v-backup-users-custom" ]; then
    rm -f "$HESTIA_BIN/v-backup-users-custom"
    rm -f "/etc/hestiacp-backup-custom.conf"
    echo "  -> Cleaned up old v-backup-users-custom wrapper (Arch v1)."
fi
if [ -d "$HESTIA_BIN/lib" ] && [ -f "$HESTIA_BIN/lib/core.sh" ] && [ -f "$HESTIA_BIN/lib/retention.sh" ] && [ -f "$HESTIA_BIN/lib/remote.sh" ]; then
    rm -rf "$HESTIA_BIN/lib"
    echo "  -> Cleaned up orphaned Arch v1 backup library ($HESTIA_BIN/lib)."
fi

# 2. Install the new local organization hook
ln -sf "$SCRIPT_DIR/hooks/v-backup-user-hook" "$HESTIA_BIN/v-backup-user-hook"
chmod +x "$SCRIPT_DIR/hooks/v-backup-user-hook"
echo "  -> Installed backup organization hook: v-backup-user-hook"

# 2.1 Install the new notification hooks
ln -sf "$SCRIPT_DIR/hooks/v-backup-user-notify-hook" "$HESTIA_BIN/v-backup-user-notify-hook"
chmod +x "$SCRIPT_DIR/hooks/v-backup-user-notify-hook"
ln -sf "$SCRIPT_DIR/hooks/v-backup-users-notify-hook" "$HESTIA_BIN/v-backup-users-notify-hook"
chmod +x "$SCRIPT_DIR/hooks/v-backup-users-notify-hook"
echo "  -> Installed HTML notification hooks"

# 2.2 Install optional retention command and native v-backup-users hook
ln -sf "$SCRIPT_DIR/bin/v-prune-backups" "$HESTIA_BIN/v-prune-backups"
chmod +x "$SCRIPT_DIR/bin/v-prune-backups"
ln -sf "$SCRIPT_DIR/hooks/v-backup-users-retention-hook" "$HESTIA_BIN/v-backup-users-retention-hook"
chmod +x "$SCRIPT_DIR/hooks/v-backup-users-retention-hook"
if [ ! -f "$RETENTION_CONF" ]; then
    cp "$SCRIPT_DIR/config/backup-retention.conf.sample" "$RETENTION_CONF"
    chmod 600 "$RETENTION_CONF"
    echo "  -> Installed optional retention config: $RETENTION_CONF"
else
    chmod 600 "$RETENTION_CONF" 2>/dev/null || true
    echo "  -> Retention config already exists (skipped): $RETENTION_CONF"
fi
echo "  -> Installed optional native retention hook: v-prune-backups"

# 3. Apply core Hestia patches (B2 paths, symlink delete, v-backup-user post-hook)
if [ -f "$LIB_DIR/hestia.sh" ]; then
    _log() { echo "  -> $1"; }
    source "$LIB_DIR/hestia.sh"
    apply_hestia_patches
fi

# 3.1 Ensure APT DPkg::Post-Invoke hook re-applies patches automatically after HestiaCP updates
APT_HOOK_FILE="/etc/apt/apt.conf.d/99hestia-custom-patches"
REPO_ROOT="$(readlink -f "$SCRIPT_DIR/../.." 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"
if [ -d "/etc/apt/apt.conf.d" ] && [ -f "$REPO_ROOT/install.sh" ] && [ ! -L "$REPO_ROOT/install.sh" ]; then
    repo_perm="$(stat -c '%a' "$REPO_ROOT" 2>/dev/null || echo '777')"
    inst_perm="$(stat -c '%a' "$REPO_ROOT/install.sh" 2>/dev/null || echo '777')"
    if [[ "$REPO_ROOT" =~ ^/[A-Za-z0-9_./-]+$ ]] && \
       [[ "$REPO_ROOT" != /tmp/* && "$REPO_ROOT" != /var/tmp/* && "$REPO_ROOT" != /dev/shm/* ]] && \
       [ -O "$REPO_ROOT" ] && [ -O "$REPO_ROOT/install.sh" ] && \
       [[ ! "$repo_perm" =~ [2367].$ && ! "$repo_perm" =~ [2367]$ ]] && \
       [[ ! "$inst_perm" =~ [2367].$ && ! "$inst_perm" =~ [2367]$ ]]; then
        tmp_apt_hook="$(mktemp /etc/apt/apt.conf.d/.99hestia-custom-patches.XXXXXX)"
        cat > "$tmp_apt_hook" << APT_EOF
// Managed by hestiacp-useful-tools (backup-core-patches)
// Automatically re-applies HestiaCP custom patches after apt/dpkg package updates
DPkg::Post-Invoke { "if [ -f '$REPO_ROOT/install.sh' ] && [ ! -L '$REPO_ROOT/install.sh' ] && [ -O '$REPO_ROOT' ] && [ -O '$REPO_ROOT/install.sh' ]; then /bin/bash '$REPO_ROOT/install.sh' </dev/null >/dev/null 2>&1 || true; fi"; };
APT_EOF
        chown root:root "$tmp_apt_hook"
        chmod 0644 "$tmp_apt_hook"
        if [ -f "$APT_HOOK_FILE" ] && cmp -s "$tmp_apt_hook" "$APT_HOOK_FILE"; then
            rm -f "$tmp_apt_hook"
            echo "  -> APT post-invoke hook already up to date: $APT_HOOK_FILE"
        else
            mv -f "$tmp_apt_hook" "$APT_HOOK_FILE"
            echo "  -> Installed APT post-invoke auto-heal hook: $APT_HOOK_FILE"
        fi
    else
        echo "  -> [WARN] Skipped APT hook ($APT_HOOK_FILE): repo path '$REPO_ROOT' must be root-owned and non-world/group-writable"
    fi
fi

# 4. Check remote backup status and guide user
echo ""
b2_conf="$HESTIA/conf/b2.backup.conf"
if [ -f "$b2_conf" ] && grep -q "BUCKET=" "$b2_conf" 2>/dev/null; then
    b2_bucket=$(grep "^BUCKET=" "$b2_conf" | cut -d"'" -f2 || true)
    echo "  ✅ B2 cloud backup configured (bucket: $b2_bucket)"
    echo "  Backups will be uploaded to organized paths: YYYY/MM_MONTH/user/"
else
    echo "  ℹ️  Cloud backup is not configured (local-only mode)"
    echo ""
    echo "  To enable cloud backups natively, run ONE of these:"
    echo ""
    echo "    Backblaze B2:"
    echo "      v-add-backup-host b2 BUCKET_NAME KEY_ID APP_KEY"
    echo ""
    echo "  See README.md for detailed setup instructions."
fi

echo ""
echo "[OK] Backup Native Patches installed successfully."
