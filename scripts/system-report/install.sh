#!/bin/bash
# Installer for System Report module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-system-report ---"

# Script
target_bin="$HESTIA_BIN/v-system-report"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-system-report" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-system-report.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-system-report.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-system-report" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

# Config
if [ ! -f "/etc/hestiacp-system-report.conf" ]; then
    cp "$SCRIPT_DIR/system-report.conf.sample" "/etc/hestiacp-system-report.conf"
    chmod 600 "/etc/hestiacp-system-report.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-system-report.conf"
else
    echo "  -> [INFO] Config exists (skipped): /etc/hestiacp-system-report.conf"
fi
