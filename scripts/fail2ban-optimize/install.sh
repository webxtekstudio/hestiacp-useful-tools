#!/bin/bash
# =============================================================================
# scripts/fail2ban-optimize/install.sh
# Installer module for Fail2Ban Email Optimizer
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="/usr/local/hestia/bin"

echo "--- Installing Fail2Ban Email Optimizer (v-optimize-fail2ban) ---"

# 1. Install CLI binary into Hestia bin
target_bin="$HESTIA_BIN/v-optimize-fail2ban"
if [ -f "$target_bin" ]; then
    cp "$target_bin" "${target_bin}.bak.$(date +%Y%m%d-%H%M%S)"
fi

cp "$SCRIPT_DIR/v-optimize-fail2ban" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed CLI script: $target_bin"

# 2. Run optimization to apply immediately
echo "  -> Applying Fail2Ban email hardening configuration..."
"$target_bin"

echo ""
echo "Installation complete. You can run 'v-optimize-fail2ban' anytime."