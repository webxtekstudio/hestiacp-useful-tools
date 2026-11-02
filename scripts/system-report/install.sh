#!/bin/bash
# Installer for System Report module

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-system-report ---"

target_bin="$HESTIA_BIN/v-system-report"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-system-report" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-system-report.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-system-report.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
rm -f "$target_bin"
install -o root -g root -m 0755 "$SCRIPT_DIR/v-system-report" "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

if [ ! -f "/etc/hestiacp-system-report.conf" ]; then
    install -o root -g root -m 0600 "$SCRIPT_DIR/system-report.conf.sample" "/etc/hestiacp-system-report.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-system-report.conf"
else
    chown root:root "/etc/hestiacp-system-report.conf"
    chmod 600 "/etc/hestiacp-system-report.conf"
    echo "  -> [INFO] Config exists (permissions verified 0600): /etc/hestiacp-system-report.conf"
fi
