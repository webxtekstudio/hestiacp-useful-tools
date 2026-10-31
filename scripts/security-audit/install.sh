#!/bin/bash
# Installer for Security Audit module

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-security-audit ---"

# Script
target_bin="$HESTIA_BIN/v-security-audit"
target_lib="$HESTIA_BIN/v-security-audit.d"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-security-audit" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-security-audit.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-security-audit.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi
cp "$SCRIPT_DIR/v-security-audit" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

# Library modules — always update (directory comparison is complex, just overwrite)
if [ -d "$target_lib" ]; then
    rm -rf "$target_lib"
fi
mkdir -p "$target_lib"
cp -a "$SCRIPT_DIR/lib/." "$target_lib/"
chmod -R u=rwX,go=rX "$target_lib"
echo "  -> [OK] Installed library: $target_lib"
