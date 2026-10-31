#!/bin/bash
# Installer for Exim Limit module

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-add-exim-limit ---"

target_bin="$HESTIA_BIN/v-add-exim-limit"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-add-exim-limit" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-add-exim-limit.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-add-exim-limit.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
cp --remove-destination "$SCRIPT_DIR/v-add-exim-limit" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

target_monitor="$HESTIA_BIN/monitor_large_emails.py"
if [ -f "$target_monitor" ] && ! cmp -s "$SCRIPT_DIR/monitor_large_emails.py" "$target_monitor"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_monitor" "$BAK_DIR/monitor_large_emails.py.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/monitor_large_emails.py.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
cp --remove-destination "$SCRIPT_DIR/monitor_large_emails.py" "$target_monitor"
chmod +x "$target_monitor"
echo "  -> [OK] Installed monitor helper: $target_monitor"

# Migrate legacy /usr/local/bin duplicate & cron path so updates are always live
if [ -f /etc/cron.d/exim-large-monitor ] && grep -q "/usr/local/bin/monitor_large_emails.py" /etc/cron.d/exim-large-monitor 2>/dev/null; then
    sed -i "s|/usr/local/bin/monitor_large_emails.py|$target_monitor|g" /etc/cron.d/exim-large-monitor
    echo "  -> [OK] Migrated /etc/cron.d/exim-large-monitor to $target_monitor"
fi
if [ -f /usr/local/bin/monitor_large_emails.py ]; then
    rm -f /usr/local/bin/monitor_large_emails.py
    echo "  -> [OK] Removed outdated legacy duplicate: /usr/local/bin/monitor_large_emails.py"
fi

if [ ! -f "/etc/hestiacp-exim-limit.conf" ]; then
    cp "$SCRIPT_DIR/exim-limit.conf.sample" "/etc/hestiacp-exim-limit.conf"
    chmod 600 "/etc/hestiacp-exim-limit.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-exim-limit.conf"
else
    echo "  -> [INFO] Config exists (skipped): /etc/hestiacp-exim-limit.conf"
fi
