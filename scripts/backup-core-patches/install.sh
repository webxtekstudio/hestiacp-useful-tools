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
