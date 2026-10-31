#!/bin/bash
# Installer for Clean Garbage module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-clean-garbage ---"

# Script
target_bin="$HESTIA_BIN/v-clean-garbage"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-clean-garbage" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-clean-garbage.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-clean-garbage.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-clean-garbage" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

# Config
if [ ! -f "/etc/hestiacp-clean-garbage.conf" ]; then
    cp "$SCRIPT_DIR/clean-garbage.conf.sample" "/etc/hestiacp-clean-garbage.conf"
    chmod 600 "/etc/hestiacp-clean-garbage.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-clean-garbage.conf"
else
    echo "  -> [INFO] Config exists (skipped): /etc/hestiacp-clean-garbage.conf"
fi
