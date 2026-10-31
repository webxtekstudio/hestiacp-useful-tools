#!/bin/bash
# Installer for Github Mirror module

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-github-mirror ---"

target_bin="$HESTIA_BIN/v-github-mirror"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-github-mirror" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-github-mirror.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-github-mirror.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-github-mirror" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

if [ ! -f "/etc/hestiacp-github-mirror.conf" ]; then
    cp "$SCRIPT_DIR/github-mirror.conf.sample" "/etc/hestiacp-github-mirror.conf"
    chmod 600 "/etc/hestiacp-github-mirror.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-github-mirror.conf"
else
    echo "  -> [INFO] Config exists (skipped): /etc/hestiacp-github-mirror.conf"
fi

if [ ! -f "/etc/hestiacp-github-mirror.settings" ]; then
    cp "$SCRIPT_DIR/github-mirror.settings.sample" "/etc/hestiacp-github-mirror.settings"
    chmod 600 "/etc/hestiacp-github-mirror.settings"
    echo "  -> [OK] Installed settings: /etc/hestiacp-github-mirror.settings"
else
    echo "  -> [INFO] Settings exist (skipped): /etc/hestiacp-github-mirror.settings"
fi
