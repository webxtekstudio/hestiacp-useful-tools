#!/bin/bash
# Installer for Exim Limit module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-add-exim-limit ---"

# Script
target_bin="$HESTIA_BIN/v-add-exim-limit"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-add-exim-limit" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-add-exim-limit.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-add-exim-limit.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-add-exim-limit" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

target_monitor="$HESTIA_BIN/monitor_large_emails.py"
if [ -f "$target_monitor" ] && ! cmp -s "$SCRIPT_DIR/monitor_large_emails.py" "$target_monitor"; then
    mkdir -p "$BAK_DIR"
    cp "$target_monitor" "$BAK_DIR/monitor_large_emails.py.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/monitor_large_emails.py.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/monitor_large_emails.py" "$target_monitor"
chmod +x "$target_monitor"
echo "  -> [OK] Installed monitor helper: $target_monitor"

# Config
if [ ! -f "/etc/hestiacp-exim-limit.conf" ]; then
    cp "$SCRIPT_DIR/exim-limit.conf.sample" "/etc/hestiacp-exim-limit.conf"
    chmod 600 "/etc/hestiacp-exim-limit.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-exim-limit.conf"
else
    echo "  -> [INFO] Config exists (skipped): /etc/hestiacp-exim-limit.conf"
fi
