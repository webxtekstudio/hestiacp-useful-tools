#!/bin/bash
# Installer for Github Mirror module

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (or use sudo)" >&2
    exit 1
fi

export HESTIA="${HESTIA:-/usr/local/hestia}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HESTIA_BIN="$HESTIA/bin"
BAK_DIR="/var/backups/hestiacp-useful-tools"

echo "--- Installing v-github-mirror ---"

target_bin="$HESTIA_BIN/v-github-mirror"
if [ -f "$target_bin" ] && ! cmp -s "$SCRIPT_DIR/v-github-mirror" "$target_bin"; then
    install -d -m 0700 "$BAK_DIR"
    cp "$target_bin" "$BAK_DIR/v-github-mirror.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BAK_DIR"/v-github-mirror.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f -- 2>/dev/null || true
fi
cp --remove-destination "$SCRIPT_DIR/v-github-mirror" "$target_bin"
chmod +x "$target_bin"
echo "  -> [OK] Installed script: $target_bin"

if [ ! -f "/etc/hestiacp-github-mirror.conf" ]; then
    cp "$SCRIPT_DIR/github-mirror.conf.sample" "/etc/hestiacp-github-mirror.conf"
    chmod 600 "/etc/hestiacp-github-mirror.conf"
    echo "  -> [OK] Installed config: /etc/hestiacp-github-mirror.conf"
else
    chmod 600 "/etc/hestiacp-github-mirror.conf"
    echo "  -> [INFO] Config exists (permissions verified 0600): /etc/hestiacp-github-mirror.conf"
fi

if [ ! -f "/etc/hestiacp-github-mirror.settings" ]; then
    cp "$SCRIPT_DIR/github-mirror.settings.sample" "/etc/hestiacp-github-mirror.settings"
    chmod 600 "/etc/hestiacp-github-mirror.settings"
    echo "  -> [OK] Installed settings: /etc/hestiacp-github-mirror.settings"
else
    chmod 600 "/etc/hestiacp-github-mirror.settings"
    echo "  -> [INFO] Settings exist (permissions verified 0600): /etc/hestiacp-github-mirror.settings"
fi

# Ensure GitHub's official Ed25519 host key is pinned in /root/.ssh/known_hosts
# so non-interactive root cron staging never fails with "Host key verification failed".
GITHUB_ED25519_HOSTKEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
install -d -m 0700 -o root -g root /root/.ssh
touch /root/.ssh/known_hosts
chown root:root /root/.ssh/known_hosts
chmod 0600 /root/.ssh/known_hosts
if ! grep -qxF "$GITHUB_ED25519_HOSTKEY" /root/.ssh/known_hosts 2>/dev/null; then
    printf '%s\n' "$GITHUB_ED25519_HOSTKEY" >> /root/.ssh/known_hosts
    echo "  -> [OK] Pinned GitHub official Ed25519 host key in /root/.ssh/known_hosts"
else
    echo "  -> [INFO] GitHub official Ed25519 host key already pinned in /root/.ssh/known_hosts"
fi

