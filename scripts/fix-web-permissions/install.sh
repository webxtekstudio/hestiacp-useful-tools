#!/bin/bash
# Installer for Fix Web Permissions module

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-fix-web-permissions ---"

target_bin="$HESTIA_BIN/v-fix-web-permissions"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-fix-web-permissions" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-fix-web-permissions.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-fix-web-permissions.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
rm -f "$target_bin"
install -o root -g root -m 0755 "$SCRIPT_DIR/v-fix-web-permissions" "$target_bin"
echo "  -> [OK] Installed script: $target_bin"
