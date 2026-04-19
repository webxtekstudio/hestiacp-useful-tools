#!/bin/bash
# Installer for Security Audit module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="/usr/local/hestia/bin"

echo "--- Installing v-security-audit ---"

# Script (we use a symlink or direct copy)
target_bin="$HESTIA_BIN/v-security-audit"
target_lib="$HESTIA_BIN/v-security-audit.d"
[ -f "$target_bin" ] && cp "$target_bin" "${target_bin}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SCRIPT_DIR/v-security-audit" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

# Library modules
if [ -d "$target_lib" ]; then
    cp -a "$target_lib" "${target_lib}.bak.$(date +%Y%m%d-%H%M%S)"
    rm -rf "$target_lib"
fi
mkdir -p "$target_lib"
cp -a "$SCRIPT_DIR/lib/." "$target_lib/"
chmod -R u=rwX,go=rX "$target_lib"
echo "  -> [OK] Installed library: $target_lib"
