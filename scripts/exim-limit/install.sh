#!/bin/bash
# Installer for Exim Limit module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="/usr/local/hestia/bin"

echo "--- Installing v-add-exim-limit ---"

# Script
target_bin="$HESTIA_BIN/v-add-exim-limit"
[ -f "$target_bin" ] && cp "$target_bin" "${target_bin}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SCRIPT_DIR/v-add-exim-limit" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

# Config
if [ ! -f "/etc/hestiacp-exim-limit.conf" ]; then
    cp "$SCRIPT_DIR/exim-limit.conf.sample" "/etc/hestiacp-exim-limit.conf"
    chmod 600 "/etc/hestiacp-exim-limit.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-exim-limit.conf"
else
    echo "  -> [INFO] Config exists (skipped): /etc/hestiacp-exim-limit.conf"
fi
