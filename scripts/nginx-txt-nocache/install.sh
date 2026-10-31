#!/bin/bash
# =============================================================================
# scripts/nginx-txt-nocache/install.sh
# Installer module for HestiaCP Nginx .txt Cache Hardener (robots.txt / llms.txt)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing Nginx .txt Cache Hardener (v-patch-nginx-txt-nocache) ---"

target_bin="$HESTIA_BIN/v-patch-nginx-txt-nocache"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-patch-nginx-txt-nocache" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-patch-nginx-txt-nocache.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-patch-nginx-txt-nocache.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-patch-nginx-txt-nocache" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed CLI script: $target_bin"

"$target_bin"
echo "  -> [OK] Applied Nginx .txt cache hardening across templates & domains"
