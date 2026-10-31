#!/bin/bash
# Installer for Security Audit module

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-security-audit ---"

target_bin="$HESTIA_BIN/v-security-audit"
target_lib="$HESTIA_BIN/v-security-audit.d"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-security-audit" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-security-audit.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-security-audit.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
cp --remove-destination "$SCRIPT_DIR/v-security-audit" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

# Library modules — atomic swap into place so concurrent runs never see partial lib/
tmp_lib="${target_lib}.tmp.$$"
rm -rf "$tmp_lib"
mkdir -p "$tmp_lib"
cp -a "$SCRIPT_DIR/lib/." "$tmp_lib/"
chmod -R u=rwX,go=rX "$tmp_lib"
rm -rf "$target_lib"
mv "$tmp_lib" "$target_lib"
echo "  -> [OK] Installed library: $target_lib"
