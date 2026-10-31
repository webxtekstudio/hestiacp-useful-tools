#!/bin/bash
# Installer for Fix Web Permissions module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-fix-web-permissions ---"

# Script
target_bin="$HESTIA_BIN/v-fix-web-permissions"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-fix-web-permissions" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-fix-web-permissions.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-fix-web-permissions.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-fix-web-permissions" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"
