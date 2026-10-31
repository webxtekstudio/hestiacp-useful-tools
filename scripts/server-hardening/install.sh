#!/bin/bash
# =============================================================================
# scripts/server-hardening/install.sh
# Installer module for HestiaCP Server Hardening & CrowdSec IPS (v-harden-server)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="/usr/local/hestia/bin"
TARGET_BIN="$HESTIA_BIN/v-harden-server"

echo "--- Installing HestiaCP Server Hardening Manager (v-harden-server) ---"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)"
    exit 1
fi

if [ -f "$TARGET_BIN" ]; then
    cp "$TARGET_BIN" "${TARGET_BIN}.bak.$(date +%Y%m%d-%H%M%S)"
fi

cp "$SCRIPT_DIR/v-harden-server" "$TARGET_BIN"
chmod +x "$TARGET_BIN"
echo "  -> [OK] Installed CLI script: $TARGET_BIN"

# Apply fast, non-lockout baseline hardening (Pillars 1-5) automatically
echo "  -> Applying HestiaCP baseline hardening (Pillars 1-5)..."
"$TARGET_BIN" --apply

if [[ "${1:-}" == "--crowdsec" || "${1:-}" == "--all" ]]; then
    "$TARGET_BIN" --crowdsec
else
    echo ""
    echo "  [TIP] To also enable CrowdSec Collaborative IPS + nftables bouncer, run:"
    echo "        v-harden-server --crowdsec"
fi
