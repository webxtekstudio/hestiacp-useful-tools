#!/bin/bash
# Installer for Logrotate Optimize module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-optimize-logrotate ---"

# Script
target_bin="$HESTIA_BIN/v-optimize-logrotate"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-optimize-logrotate" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-optimize-logrotate.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-optimize-logrotate.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-optimize-logrotate" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

echo ""
echo "To apply the optimization, run:"
echo "  v-optimize-logrotate              # Apply + force immediate rotation"
echo "  v-optimize-logrotate --dry-run    # Preview changes without applying"
echo ""
