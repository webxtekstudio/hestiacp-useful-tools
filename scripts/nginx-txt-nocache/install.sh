#!/bin/bash
# =============================================================================
# scripts/nginx-txt-nocache/install.sh
# Installer module for HestiaCP Nginx .txt Cache Hardener (robots.txt / llms.txt)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="/usr/local/hestia/bin"

echo "--- Installing Nginx .txt Cache Hardener (v-patch-nginx-txt-nocache) ---"

target_bin="$HESTIA_BIN/v-patch-nginx-txt-nocache"
cp "$SCRIPT_DIR/v-patch-nginx-txt-nocache" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed CLI script: $target_bin"

"$target_bin"
echo "  -> [OK] Applied Nginx .txt cache hardening across templates & domains"
