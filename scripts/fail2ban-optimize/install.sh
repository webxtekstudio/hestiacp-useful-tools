#!/bin/bash
# =============================================================================
# scripts/fail2ban-optimize/install.sh
# Installer module for Fail2Ban Email Optimizer
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
F2B_TARGET_CONF="/etc/fail2ban/jail.d/99-hestiacp-email-hardening.local"
F2B_LEGACY_CONF="/etc/fail2ban/jail.d/webxtek-hardening.conf"

echo "--- Installing Fail2Ban Email Optimizer (v-optimize-fail2ban) ---"

target_bin="$HESTIA_BIN/v-optimize-fail2ban"
need_apply=false

if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-optimize-fail2ban" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-optimize-fail2ban.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-optimize-fail2ban.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
    need_apply=true
elif [ ! -f "$target_bin" ]; then
    need_apply=true
fi

if [ ! -f "$F2B_TARGET_CONF" ] || [ -f "$F2B_LEGACY_CONF" ] || [ "${1:-}" = "--force" ]; then
    need_apply=true
fi

rm -f "$target_bin"
install -o root -g root -m 0755 "$SCRIPT_DIR/v-optimize-fail2ban" "$target_bin"
echo "  -> [OK] Installed CLI script: $target_bin"

if [ "$need_apply" = true ]; then
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo "  -> Applying Fail2Ban email hardening configuration..."
        "$target_bin"
    else
        echo "  -> [INFO] fail2ban-client not found, skipping auto-apply"
    fi
else
    echo "  -> [INFO] Script & .local override already up to date, skipping reload"
fi

echo ""
echo "Installation complete. You can run 'v-optimize-fail2ban' anytime."
