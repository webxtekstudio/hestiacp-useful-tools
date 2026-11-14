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

for arg in "$@"; do
    case "$arg" in
        --allow-untested-hestia) export ALLOW_UNTESTED_HESTIA=1 ;;
        --apt-hook)              export HESTIA_APT_HOOK=1 ;;
    esac
done

VERSION_GATE_LIB="$SCRIPT_DIR/../lib/version-gate.sh"
CORE_PATCH_GATE_RC=0
if [ -f "$VERSION_GATE_LIB" ]; then
    # shellcheck source=../lib/version-gate.sh
    source "$VERSION_GATE_LIB"
    if [ "${HESTIA_APT_HOOK:-0}" = "1" ]; then
        check_hestia_core_patch_compatibility "apt-hook" || CORE_PATCH_GATE_RC=$?
    else
        check_hestia_core_patch_compatibility "manual" || exit 1
    fi
fi

echo "--- Installing Nginx .txt Cache Hardener (v-patch-nginx-txt-nocache) ---"

target_bin="$HESTIA_BIN/v-patch-nginx-txt-nocache"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-patch-nginx-txt-nocache" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-patch-nginx-txt-nocache.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-patch-nginx-txt-nocache.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
rm -f "$target_bin"
install -o root -g root -m 0755 "$SCRIPT_DIR/v-patch-nginx-txt-nocache" "$target_bin"
echo "  -> [OK] Installed CLI script: $target_bin"

if [ "$CORE_PATCH_GATE_RC" -eq 0 ]; then
    "$target_bin"
    echo "  -> [OK] Applied Nginx .txt cache hardening across templates & domains"
else
    echo "  -> [INFO] Skipped applying core Nginx template mutations (version gate held)"
fi
