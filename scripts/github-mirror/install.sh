#!/bin/bash
# Installer for Github Mirror module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-github-mirror ---"

# Script
target_bin="$HESTIA_BIN/v-github-mirror"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-github-mirror" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-github-mirror.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-github-mirror.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-github-mirror" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

# Main Config
if [ ! -f "/etc/hestiacp-github-mirror.conf" ]; then
    cp "$SCRIPT_DIR/github-mirror.conf.sample" "/etc/hestiacp-github-mirror.conf"
    chmod 600 "/etc/hestiacp-github-mirror.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-github-mirror.conf"
else
    echo "  -> [INFO] Config exists (skipped): /etc/hestiacp-github-mirror.conf"
fi

# Settings Config
if [ ! -f "/etc/hestiacp-github-mirror.settings" ]; then
    cp "$SCRIPT_DIR/github-mirror.settings.sample" "/etc/hestiacp-github-mirror.settings"
    chmod 600 "/etc/hestiacp-github-mirror.settings"
    echo "  -> [OK] Installed settings: /etc/hestiacp-github-mirror.settings"
else
    echo "  -> [INFO] Settings exist (skipped): /etc/hestiacp-github-mirror.settings"
fi
