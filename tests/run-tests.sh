#!/bin/bash
# =============================================================================
# HestiaCP Useful Tools — Automated Test Suite
#
# Validates syntax, Fail2Ban <-> iptables drift detection & post-reboot healing,
# web log permission hygiene (B40/B61), security audit accuracy (S15c/S38/S59),
# and public-repo privacy rules.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  [PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  [FAIL] $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "================================================================="
echo " Running hestiacp-useful-tools Test Suite"
echo "================================================================="

# -----------------------------------------------------------------------------
# 1. Bash Syntax Check (bash -n)
# -----------------------------------------------------------------------------
echo ""
echo "[1/6] Checking Bash syntax across all shell scripts..."
syntax_errors=0
while IFS= read -r -d '' sh_file; do
    if head -n 1 "$sh_file" 2>/dev/null | grep -qE '^#!.*(ba)?sh'; then
        if ! bash -n "$sh_file" 2>/dev/null; then
            fail "Syntax error in ${sh_file#$REPO_ROOT/}"
            syntax_errors=$((syntax_errors + 1))
        fi
    fi
done < <(find "$REPO_ROOT" -type f \( -name "*.sh" -o -path "*/scripts/*/v-*" -o -path "*/scripts/*/bin/v-*" -o -path "*/scripts/*/hooks/v-*" \) -print0)

if [ "$syntax_errors" -eq 0 ]; then
    pass "All shell scripts passed 'bash -n' syntax check"
fi

# -----------------------------------------------------------------------------
# 2. Fail2Ban <-> iptables Partial Drift (>20%) Detection in v-harden-server
# -----------------------------------------------------------------------------
echo ""
echo "[2/6] Testing Fail2Ban <-> iptables drift detection (check_f2b_desync_count)..."

SAND_BASE="${TMPDIR:-/tmp}"
[ -d /run ] && [ -w /run ] && SAND_BASE="/run"
SAND_DIR=$(mktemp -d "${SAND_BASE}/hestia-test.XXXXXX")
trap 'rm -rf "$SAND_DIR"' EXIT

mkdir -p "$SAND_DIR/bin"
cat > "$SAND_DIR/bin/systemctl" << 'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SAND_DIR/bin/systemctl"

# Extract check_f2b_desync_count from v-harden-server
F2B_FN_SCRIPT="$SAND_DIR/f2b_fn.sh"
sed -n '/^check_f2b_desync_count()/,/^}/p' "$REPO_ROOT/scripts/server-hardening/v-harden-server" > "$F2B_FN_SCRIPT"

# Mock fail2ban-client & iptables for Case A: 170 banned in ssh-iptables, 134 rules in fail2ban-SSH (>20% drift)
cat > "$SAND_DIR/bin/fail2ban-client" << 'EOF'
#!/bin/bash
if [ "$1" = "status" ] && [ "${2:-}" = "ssh-iptables" ]; then
    echo "Status for the jail: ssh-iptables"
    echo "|- Filter"
    echo "\`- Actions"
    echo "   |- Currently banned: 170"
    echo "   \`- Banned IP list: 192.0.2.1 192.0.2.2"
    exit 0
elif [ "$1" = "status" ] && [ "${2:-}" = "dovecot-iptables" ]; then
    echo "   |- Currently banned: 2"
    exit 0
elif [ "$1" = "status" ] && [ "${2:-}" = "exim-iptables" ]; then
    echo "   |- Currently banned: 10"
    exit 0
fi
exit 1
EOF
chmod +x "$SAND_DIR/bin/fail2ban-client"

cat > "$SAND_DIR/bin/iptables" << 'EOF'
#!/bin/bash
if [ "$1" = "-L" ] && [ "${2:-}" = "fail2ban-SSH" ]; then
    for i in $(seq 1 "${MOCK_SSH_RULES:-134}"); do
        echo "DROP all -- 192.0.2.$((i % 250 + 1)) 0.0.0.0/0"
    done
    exit 0
elif [ "$1" = "-L" ] && [ "${2:-}" = "fail2ban-MAIL" ]; then
    for i in $(seq 1 12); do
        echo "DROP all -- 198.51.100.$i 0.0.0.0/0"
    done
    exit 0
fi
exit 0
EOF
chmod +x "$SAND_DIR/bin/iptables"

drift_count=$(PATH="$SAND_DIR/bin:$PATH" MOCK_SSH_RULES=134 bash -c "source '$F2B_FN_SCRIPT'; check_f2b_desync_count")
if [ "$drift_count" = "1" ]; then
    pass "Detects partial >20% drift (170 Fail2Ban bans vs 134 iptables rules)"
else
    fail "Expected check_f2b_desync_count=1 for 170 vs 134 drift, got '$drift_count'"
fi

sync_count=$(PATH="$SAND_DIR/bin:$PATH" MOCK_SSH_RULES=170 bash -c "source '$F2B_FN_SCRIPT'; check_f2b_desync_count")
if [ "$sync_count" = "0" ]; then
    pass "Reports 0 desync when ssh-iptables (170) matches fail2ban-SSH (170) and shared MAIL chain has 12 rules"
else
    fail "Expected check_f2b_desync_count=0 when synced, got '$sync_count'"
fi

# -----------------------------------------------------------------------------
# 3. Post-Reboot banlist.conf Stale Entry Healing (heal_f2b_desync)
# -----------------------------------------------------------------------------
echo ""
echo "[3/6] Testing post-reboot banlist.conf <-> iptables healing..."

HEAL_FN_SCRIPT="$SAND_DIR/heal_fn.sh"
sed -n '/^heal_f2b_desync()/,/^}/p' "$REPO_ROOT/scripts/server-hardening/v-harden-server" > "$HEAL_FN_SCRIPT"

if [ ! -s "$HEAL_FN_SCRIPT" ]; then
    fail "heal_f2b_desync() function is missing from v-harden-server"
else
    mkdir -p "$SAND_DIR/hestia/data/firewall" "$SAND_DIR/hestia/bin"
    # Simulate 192.0.2.50 already left in banlist.conf from before reboot, while 192.0.2.99 is excluded
    echo "IP='192.0.2.50' CHAIN='SSH' TIME='00:00:00' DATE='2026-01-01'" > "$SAND_DIR/hestia/data/firewall/banlist.conf"
    : > "$SAND_DIR/iptables_live.txt"

    # Stock v-add-firewall-ban exits early if IP is already in banlist.conf OR if IP is excluded (192.0.2.99)
    cat > "$SAND_DIR/hestia/bin/v-add-firewall-ban" << EOF
#!/bin/bash
ip="\$1"
chain="\$2"
[ "\$ip" = "192.0.2.99" ] && exit 0
if grep -q "IP='\$ip' CHAIN='\$chain'" "$SAND_DIR/hestia/data/firewall/banlist.conf" 2>/dev/null; then
    exit 0
fi
echo "IP='\$ip' CHAIN='\$chain'" >> "$SAND_DIR/hestia/data/firewall/banlist.conf"
echo "fail2ban-\$chain \$ip" >> "$SAND_DIR/iptables_live.txt"
EOF
    cat > "$SAND_DIR/hestia/bin/v-add-firewall-chain" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$SAND_DIR/hestia/bin/v-add-firewall-ban" "$SAND_DIR/hestia/bin/v-add-firewall-chain"

    cat > "$SAND_DIR/bin/fail2ban-client" << 'EOF'
#!/bin/bash
if [ "$1" = "status" ] && [ "${2:-}" = "ssh-iptables" ]; then
    echo "   |- Currently banned: 2"
    echo "   \`- Banned IP list: 192.0.2.50 192.0.2.99"
    exit 0
fi
exit 1
EOF
    cat > "$SAND_DIR/bin/iptables" << EOF
#!/bin/bash
if [ "\$1" = "-C" ]; then
    chain="\$2"
    ip="\$4"
    grep -q "^\$chain \$ip\$" "$SAND_DIR/iptables_live.txt" 2>/dev/null
    exit \$?
elif [ "\$1" = "-I" ]; then
    chain="\$2"
    ip="\$5"
    echo "\$chain \$ip" >> "$SAND_DIR/iptables_live.txt"
    exit 0
fi
exit 0
EOF
    chmod +x "$SAND_DIR/bin/fail2ban-client" "$SAND_DIR/bin/iptables"

    PATH="$SAND_DIR/bin:$PATH" HESTIA="$SAND_DIR/hestia" bash -c "source '$F2B_FN_SCRIPT'; source '$HEAL_FN_SCRIPT'; heal_f2b_desync"
    if grep -q "^fail2ban-SSH 192.0.2.50$" "$SAND_DIR/iptables_live.txt" && ! grep -q "192.0.2.99" "$SAND_DIR/iptables_live.txt"; then
        pass "heal_f2b_desync() re-inserts stale banlist.conf IP (192.0.2.50) into iptables while respecting excluded IPs"
    else
        fail "heal_f2b_desync() did not properly reconcile iptables_live.txt (contents: $(tr '\n' ',' < "$SAND_DIR/iptables_live.txt"))"
    fi
fi

# -----------------------------------------------------------------------------
# 4. Web Log Hygiene (B61 0-byte debug.log & B40 world-readable *.log files)
# -----------------------------------------------------------------------------
echo ""
echo "[4/6] Testing web log permission & debug.log hygiene (B40 / B61)..."

WEB_FN_SCRIPT="$SAND_DIR/web_log_hygiene.sh"
sed -n '/^sanitize_tenant_web_logs()/,/^}/p' "$REPO_ROOT/scripts/server-hardening/v-harden-server" > "$WEB_FN_SCRIPT"

if [ ! -s "$WEB_FN_SCRIPT" ]; then
    fail "sanitize_tenant_web_logs() function is missing from v-harden-server"
else
    mkdir -p "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/uploads/wc-logs" \
             "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/yaymail-logs" \
             "$SAND_DIR/home/user1/web/example.org/public_html/wp-content"

    # 1. Empty 0-byte debug.log (0644) -> should be removed
    : > "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/debug.log"
    chmod 0644 "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/debug.log"

    # 2. Non-empty debug.log (0644) -> should be kept and clamped to 0640
    echo "PHP Notice: test" > "$SAND_DIR/home/user1/web/example.org/public_html/wp-content/debug.log"
    chmod 0644 "$SAND_DIR/home/user1/web/example.org/public_html/wp-content/debug.log"

    # 3. World-readable WooCommerce & plugin logs (0644) -> should be clamped to 0640
    echo "wc log entry" > "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/uploads/wc-logs/fatal-errors.log"
    chmod 0644 "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/uploads/wc-logs/fatal-errors.log"
    echo "yaymail entry" > "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/yaymail-logs/yaymail.log"
    chmod 0644 "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/yaymail-logs/yaymail.log"

    : > "$SAND_DIR/chmod_calls.txt"
    cat > "$SAND_DIR/bin/chmod" << EOF
#!/bin/bash
for arg in "\$@"; do
    echo "\$1 \$arg" >> "$SAND_DIR/chmod_calls.txt"
done
/usr/bin/chmod "\$@" 2>/dev/null || /bin/chmod "\$@" 2>/dev/null || true
EOF
    chmod +x "$SAND_DIR/bin/chmod"

    PATH="$SAND_DIR/bin:$PATH" HESTIA_HOME_ROOT="$SAND_DIR/home" bash -c "source '$WEB_FN_SCRIPT'; sanitize_tenant_web_logs"

    if [ ! -e "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/debug.log" ]; then
        pass "Removes 0-byte wp-content/debug.log automatically (fixes B61 FAIL)"
    else
        fail "0-byte wp-content/debug.log was not removed"
    fi

    nonempty_perm=$(stat -c '%a' "$SAND_DIR/home/user1/web/example.org/public_html/wp-content/debug.log" 2>/dev/null || echo "missing")
    wc_perm=$(stat -c '%a' "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/uploads/wc-logs/fatal-errors.log" 2>/dev/null || echo "missing")
    ym_perm=$(stat -c '%a' "$SAND_DIR/home/user1/web/example.com/public_html/wp-content/yaymail-logs/yaymail.log" 2>/dev/null || echo "missing")

    if { [ "$nonempty_perm" = "640" ] && [ "$wc_perm" = "640" ] && [ "$ym_perm" = "640" ]; } || \
       { grep -q "0640 .*example.org/public_html/wp-content/debug.log" "$SAND_DIR/chmod_calls.txt" && \
         grep -q "0640 .*wc-logs/fatal-errors.log" "$SAND_DIR/chmod_calls.txt" && \
         grep -q "0640 .*yaymail-logs/yaymail.log" "$SAND_DIR/chmod_calls.txt"; }; then
        pass "Clamps non-empty debug.log and world-readable *.log files in public_html to 0640 (fixes B40 WARN)"
    else
        fail "Expected 640 on non-empty logs, got debug.log=$nonempty_perm wc=$wc_perm yaymail=$ym_perm"
    fi
fi

if grep -q "CLEAN_WEB_LOGS" "$REPO_ROOT/scripts/clean-garbage/v-clean-garbage" && \
   grep -q "CLEAN_WEB_LOGS" "$REPO_ROOT/scripts/clean-garbage/clean-garbage.conf.sample"; then
    pass "v-clean-garbage and clean-garbage.conf.sample include CLEAN_WEB_LOGS hygiene task"
else
    fail "v-clean-garbage or clean-garbage.conf.sample is missing CLEAN_WEB_LOGS"
fi

# -----------------------------------------------------------------------------
# 5. v-security-audit Accuracy (S15c .local filter & S38/S59 ACCOUNTS='0')
# -----------------------------------------------------------------------------
echo ""
echo "[5/6] Testing v-security-audit S15c (.local filter) and S38/S59 (ACCOUNTS='0' skip)..."

if grep -q "wordpress-xmlrpc.local" "$REPO_ROOT/scripts/security-audit/lib/system/firewall.sh"; then
    pass "S15c in firewall.sh checks wordpress-xmlrpc.local as well as wordpress-xmlrpc.conf"
else
    fail "S15c in firewall.sh only checks wordpress-xmlrpc.conf and ignores wordpress-xmlrpc.local"
fi

if grep -q "ACCOUNTS='0'" "$REPO_ROOT/scripts/security-audit/lib/system/mail.sh"; then
    pass "S38/S59 in mail.sh skips inactive mail domains (ACCOUNTS='0' without catchall)"
else
    fail "S38/S59 in mail.sh does not skip inactive ACCOUNTS='0' mail domains"
fi

# -----------------------------------------------------------------------------
# 6. Public Repo Privacy Check (RFC 5737 / RFC 1918 IPv4 allowlist)
# -----------------------------------------------------------------------------
echo ""
echo "[6/6] Running public repository privacy check..."
leaked_ips=$(git -C "$REPO_ROOT" grep -Proh '\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b' -- ':!*.git*' 2>/dev/null | \
    grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|169\.254\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|0\.0\.0\.0|255\.255\.255\.|1\.1\.1\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9|[0-9]\.[0-9]\.[0-9]\.[0-9]$)' || true)
if [ -n "$leaked_ips" ]; then
    fail "Non-placeholder public IPv4 address(es) found in repository: $(echo "$leaked_ips" | tr '\n' ' ')"
else
    pass "Zero non-placeholder public IPv4 addresses found in repository"
fi

echo ""
echo "================================================================="
echo " Summary: $PASS_COUNT PASSED, $FAIL_COUNT FAILED"
echo "================================================================="
[ "$FAIL_COUNT" -eq 0 ]
