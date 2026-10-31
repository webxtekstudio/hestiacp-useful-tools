#!/bin/bash
# Installer for Logrotate Optimize module

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-optimize-logrotate ---"

target_bin="$HESTIA_BIN/v-optimize-logrotate"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-optimize-logrotate" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-optimize-logrotate.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-optimize-logrotate.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-optimize-logrotate" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

echo ""
echo "To apply the optimization, run:"
echo "  v-optimize-logrotate              # Apply + force immediate rotation"
echo "  v-optimize-logrotate --dry-run    # Preview changes without applying"
echo ""
