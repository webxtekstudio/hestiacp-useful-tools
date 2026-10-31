#!/bin/bash
# =============================================================================
# scripts/fail2ban-optimize/install.sh
# Installer module for Fail2Ban Email Optimizer
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing Fail2Ban Email Optimizer (v-optimize-fail2ban) ---"

# 1. Install CLI binary into Hestia bin
target_bin="$HESTIA_BIN/v-optimize-fail2ban"
need_apply=false

if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-optimize-fail2ban" "$target_bin"; then
    mkdir -p "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-optimize-fail2ban.bak.$(date +%Y%m%d-%H%M%S)"
    ls -t "$BAK_DIR"/v-optimize-fail2ban.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    need_apply=true
elif [ ! -f "$target_bin" ]; then
    need_apply=true
fi

cp "$SCRIPT_DIR/v-optimize-fail2ban" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed CLI script: $target_bin"

# 2. Run optimization only if binary changed or is new
if [ "$need_apply" = true ]; then
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo "  -> Applying Fail2Ban email hardening configuration..."
        "$target_bin"
    else
        echo "  -> [INFO] fail2ban-client not found, skipping auto-apply"
    fi
else
    echo "  -> [INFO] Script unchanged, skipping auto-apply"
fi

echo ""
echo "Installation complete. You can run 'v-optimize-fail2ban' anytime."
