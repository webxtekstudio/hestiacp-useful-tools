#!/bin/bash
# =============================================================================
# scripts/server-hardening/install.sh
# Installer module for HestiaCP Server Hardening & CrowdSec IPS (v-harden-server)
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
TARGET_BIN="$HESTIA_BIN/v-harden-server"

echo "--- Installing HestiaCP Server Hardening Manager (v-harden-server) ---"

if [ -f "$TARGET_BIN" ] && ! cmp -s "$SCRIPT_DIR/v-harden-server" "$TARGET_BIN"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$TARGET_BIN" "$BAK_DIR/v-harden-server.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-harden-server.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
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
