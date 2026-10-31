#!/bin/bash
# =============================================================================
# scripts/nginx-txt-nocache/install.sh
# Installer module for HestiaCP Nginx .txt Cache Hardener (robots.txt / llms.txt)
# =============================================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing Nginx .txt Cache Hardener (v-patch-nginx-txt-nocache) ---"

target_bin="$HESTIA_BIN/v-patch-nginx-txt-nocache"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-patch-nginx-txt-nocache" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-patch-nginx-txt-nocache.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-patch-nginx-txt-nocache.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
cp --remove-destination "$SCRIPT_DIR/v-patch-nginx-txt-nocache" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed CLI script: $target_bin"

"$target_bin"
echo "  -> [OK] Applied Nginx .txt cache hardening across templates & domains"
