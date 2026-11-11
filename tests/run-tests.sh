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
for cand_dir in /run /dev/shm "${TMPDIR:-/tmp}" /tmp; do
    [ -d "$cand_dir" ] && [ -w "$cand_dir" ] || continue
    probe_f=$(mktemp "${cand_dir}/.hestia-exec-probe.XXXXXX" 2>/dev/null || true)
    [ -n "$probe_f" ] || continue
    printf '#!/bin/sh\nexit 0\n' > "$probe_f"
    chmod +x "$probe_f" 2>/dev/null || true
    if "$probe_f" >/dev/null 2>&1; then
        rm -f "$probe_f"
        SAND_BASE="$cand_dir"
        break
    fi
    rm -f "$probe_f"
done
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

if grep -q 'NOTIFY_ON_SUCCESS="TRUE"' "$REPO_ROOT/scripts/clean-garbage/v-clean-garbage" && \
   grep -q 'NOTIFY_ON_SUCCESS="TRUE"' "$REPO_ROOT/scripts/clean-garbage/clean-garbage.conf.sample" && \
   grep -q -- '--force-notification' "$REPO_ROOT/scripts/clean-garbage/v-clean-garbage"; then
    pass "v-clean-garbage and clean-garbage.conf.sample support NOTIFY_ON_SUCCESS and --force-notification"
else
    fail "v-clean-garbage or clean-garbage.conf.sample is missing NOTIFY_ON_SUCCESS / --force-notification"
fi

if grep -q '^_ensure_user_top_dir()' "$REPO_ROOT/scripts/github-mirror/v-github-mirror" && \
   grep -q 'git/repo|overwrite' "$REPO_ROOT/scripts/github-mirror/github-mirror.conf.sample"; then
    pass "v-github-mirror defines O_NOFOLLOW _ensure_user_top_dir() and recommends git/<repo> layout"
else
    fail "v-github-mirror or github-mirror.conf.sample missing _ensure_user_top_dir() / git/<repo> defaults"
fi

# Test v-verify-backups monthly .tar schedule auto-detection + Restic snapshot verification
VB_DIR="$SAND_DIR/vb_test"
mkdir -p "$VB_DIR/hestia/conf" "$VB_DIR/hestia/data/users/alice" "$VB_DIR/backup" "$VB_DIR/bin"
cat > "$VB_DIR/hestia/conf/hestia.conf" << EOF
BACKUP='$VB_DIR/backup'
BACKUP_SYSTEM='local'
BACKUP_INCREMENTAL='yes'
EOF
cat > "$VB_DIR/hestia/conf/restic.conf" << 'EOF'
REPO='rclone:mockremote:mockbucket'
EOF
echo "SUSPENDED='no'" > "$VB_DIR/hestia/data/users/alice/user.conf"
echo "DATE='2026-01-01'" >> "$VB_DIR/hestia/data/users/alice/user.conf"
echo "mockpass" > "$VB_DIR/hestia/data/users/alice/restic.conf"
chmod 600 "$VB_DIR/hestia/data/users/alice/restic.conf"

# Create a valid >10KB local .tar archive dated 20 days ago (valid for monthly=35d, stale for weekly=8d)
dd if=/dev/zero of="$VB_DIR/payload.bin" bs=1024 count=16 >/dev/null 2>&1
tar -cf "$VB_DIR/backup/alice.2026-01-01.tar" -C "$VB_DIR" payload.bin
twenty_days_ago=$(date -d "20 days ago" +"%Y-%m-%d")
echo "BACKUP='alice.2026-01-01.tar' SIZE='0' TIME='03:30:00' DATE='$twenty_days_ago'" > "$VB_DIR/hestia/data/users/alice/backup.conf"
echo "30 03 1 * * sudo /usr/local/hestia/bin/v-backup-users" > "$VB_DIR/crontab.hestiaweb"

fresh_iso=$(date -u +"%Y-%m-%dT%H:%M:%S.123456789Z")
stale_iso=$(date -u -d "72 hours ago" +"%Y-%m-%dT%H:%M:%SZ")
cat > "$VB_DIR/bin/restic" << EOF
#!/bin/bash
echo '[{"short_id":"a1b2c3d4","time":"'"\${MOCK_RESTIC_TIME}"'"}]'
EOF
chmod +x "$VB_DIR/bin/restic"

vb_ok_out=$(PATH="$VB_DIR/bin:$PATH" HESTIA="$VB_DIR/hestia" HESTIA_CRONTAB_FILE="$VB_DIR/crontab.hestiaweb" MOCK_RESTIC_TIME="$fresh_iso" bash "$REPO_ROOT/scripts/backup-core-patches/bin/v-verify-backups" --status-file="$VB_DIR/status.txt" 2>&1)
vb_ok_rc=$?
if [ "$vb_ok_rc" -eq 0 ] && printf '%s\n' "$vb_ok_out" | grep -q '^tar_schedule=monthly$' && printf '%s\n' "$vb_ok_out" | grep -q '^restic_verified_users=1$' && printf '%s\n' "$vb_ok_out" | grep -q 'restic_snapshot=a1b2c3d4'; then
    pass "v-verify-backups auto-detects monthly .tar schedule (35d) and verifies fresh Restic snapshots"
else
    fail "v-verify-backups failed monthly+Restic OK check (rc=$vb_ok_rc): $vb_ok_out"
fi

vb_stale_out=$(PATH="$VB_DIR/bin:$PATH" HESTIA="$VB_DIR/hestia" HESTIA_CRONTAB_FILE="$VB_DIR/crontab.hestiaweb" MOCK_RESTIC_TIME="$stale_iso" bash "$REPO_ROOT/scripts/backup-core-patches/bin/v-verify-backups" --status-file="$VB_DIR/status2.txt" 2>&1)
vb_stale_rc=$?
if [ "$vb_stale_rc" -ne 0 ] && printf '%s\n' "$vb_stale_out" | grep -q 'STALE_RESTIC_SNAPSHOT'; then
    pass "v-verify-backups fails with STALE_RESTIC_SNAPSHOT when Restic snapshot exceeds 36h"
else
    fail "v-verify-backups did not flag stale 72h Restic snapshot (rc=$vb_stale_rc): $vb_stale_out"
fi

# Invalid provider output must not overwrite a known counter; array ordering must not select an old snapshot.
echo "U_BACKUPS_INCREMENTAL='12'" >> "$VB_DIR/hestia/data/users/alice/user.conf"
cat > "$VB_DIR/bin/restic" <<'EOF'
#!/bin/bash
printf '%s' "$MOCK_RESTIC_JSON"
EOF
vb_invalid_out=$(PATH="$VB_DIR/bin:$PATH" HESTIA="$VB_DIR/hestia" HESTIA_CRONTAB_FILE="$VB_DIR/crontab.hestiaweb" MOCK_RESTIC_JSON='not-json' bash "$REPO_ROOT/scripts/backup-core-patches/bin/v-verify-backups" --status-file="$VB_DIR/status3.txt" 2>&1)
vb_invalid_rc=$?
if [ "$vb_invalid_rc" -ne 0 ] && grep -q "^U_BACKUPS_INCREMENTAL='12'" "$VB_DIR/hestia/data/users/alice/user.conf" && printf '%s' "$vb_invalid_out" | grep -q 'RESTIC_JSON_PARSE_FAILED'; then
    pass "v-verify-backups preserves the cached count on malformed Restic JSON"
else
    fail "Malformed Restic JSON changed the cached count or was accepted"
fi
vb_ordered_json="[{\"short_id\":\"a1b2c3d4\",\"time\":\"$fresh_iso\"},{\"short_id\":\"deadbeef\",\"time\":\"$stale_iso\"}]"
vb_ordered_out=$(PATH="$VB_DIR/bin:$PATH" HESTIA="$VB_DIR/hestia" HESTIA_CRONTAB_FILE="$VB_DIR/crontab.hestiaweb" MOCK_RESTIC_JSON="$vb_ordered_json" bash "$REPO_ROOT/scripts/backup-core-patches/bin/v-verify-backups" --status-file="$VB_DIR/status4.txt" 2>&1)
vb_ordered_rc=$?
if [ "$vb_ordered_rc" -eq 0 ] && printf '%s' "$vb_ordered_out" | grep -q 'restic_snapshot=a1b2c3d4' && grep -q '^verification_scope=metadata$' "$VB_DIR/status4.txt" && grep -q '^data_integrity=not_checked$' "$VB_DIR/status4.txt"; then
    pass "v-verify-backups selects the newest snapshot independently of array order and declares metadata scope"
else
    fail "Restic ordering or verification-scope regression"
fi

# Test v-restic-manager (--init-master-key, --run-daily, staging cleanup, key enrollment & BACKUPS_INCREMENTAL propagation)
RM_DIR="$SAND_DIR/rm_test"
mkdir -p "$RM_DIR/hestia/bin" "$RM_DIR/hestia/conf" "$RM_DIR/hestia/data/packages" "$RM_DIR/hestia/data/users/bob" "$RM_DIR/home/bob/backup/pam" "$RM_DIR/bin"
cat > "$RM_DIR/hestia/conf/hestia.conf" << 'EOF'
BACKUP_SYSTEM='local'
BACKUP_INCREMENTAL='yes'
EOF
cat > "$RM_DIR/hestia/conf/restic.conf" << 'EOF'
REPO='rclone:mockremote:mockbucket'
SNAPSHOTS='-1'
KEEP_DAILY='7'
KEEP_WEEKLY='4'
KEEP_MONTHLY='3'
KEEP_YEARLY='-1'
EOF
echo "BACKUPS_INCREMENTAL='no'" > "$RM_DIR/hestia/data/packages/default.pkg"
cat > "$RM_DIR/hestia/data/users/bob/user.conf" << 'EOF'
SUSPENDED='no'
BACKUPS_INCREMENTAL='no'
EOF
echo "shadowhash" > "$RM_DIR/home/bob/backup/pam/shadow"

cat > "$RM_DIR/hestia/bin/v-list-sys-users" << 'EOF'
#!/bin/bash
echo "bob"
EOF
cat > "$RM_DIR/hestia/bin/v-backup-user-restic" << EOF
#!/bin/bash
u="\$1"
mkdir -p "$RM_DIR/home/\$u/backup/pam"
echo "shadowhash" > "$RM_DIR/home/\$u/backup/pam/shadow"
echo "userpass32chars" > "$RM_DIR/hestia/data/users/\$u/restic.conf"
chmod 644 "$RM_DIR/hestia/data/users/\$u/restic.conf"
exit 0
EOF
cat > "$RM_DIR/bin/restic" << EOF
#!/bin/bash
echo "\$*" >> "$RM_DIR/restic_calls.log"
if echo "\$*" | grep -q "key list"; then
    if [ -f "$RM_DIR/enrolled.flag" ]; then
        echo '[{"id":"1"},{"id":"2"}]'
        exit 0
    fi
    exit 1
fi
if echo "\$*" | grep -q "key add"; then
    touch "$RM_DIR/enrolled.flag"
    exit 0
fi
exit 0
EOF
chmod +x "$RM_DIR/hestia/bin/v-list-sys-users" "$RM_DIR/hestia/bin/v-backup-user-restic" "$RM_DIR/bin/restic"

RESTIC_MANAGER_ALLOW_NONROOT=1 RESTIC_MASTER_KEY_FILE="$RM_DIR/master.key" bash "$REPO_ROOT/scripts/backup-core-patches/bin/v-restic-manager" --init-master-key >/dev/null 2>&1
mk_first="$(cat "$RM_DIR/master.key" 2>/dev/null || true)"
RESTIC_MANAGER_ALLOW_NONROOT=1 RESTIC_MASTER_KEY_FILE="$RM_DIR/master.key" bash "$REPO_ROOT/scripts/backup-core-patches/bin/v-restic-manager" --init-master-key >/dev/null 2>&1
mk_second="$(cat "$RM_DIR/master.key" 2>/dev/null || true)"

if [ "${#mk_first}" -eq 48 ] && [ "$mk_first" = "$mk_second" ]; then
    pass "v-restic-manager --init-master-key generates an idempotent 48-character Master Recovery Key"
else
    fail "v-restic-manager --init-master-key failed length/idempotency check (len=${#mk_first})"
fi

rm_daily_out=$(PATH="$RM_DIR/bin:$PATH" HESTIA="$RM_DIR/hestia" HESTIA_HOME_ROOT="$RM_DIR/home" RESTIC_MANAGER_ALLOW_NONROOT=1 RESTIC_MASTER_KEY_FILE="$RM_DIR/master.key" RESTIC_LOCK_FILE="$RM_DIR/restic.lock" RESTIC_VERIFY_STATUS_FILE="$RM_DIR/verify.status" bash "$REPO_ROOT/scripts/backup-core-patches/bin/v-restic-manager" --run-daily 2>&1)
rm_daily_rc=$?
if [ "$rm_daily_rc" -eq 0 ] && \
   [ ! -e "$RM_DIR/home/bob/backup" ] && \
   [ -f "$RM_DIR/enrolled.flag" ] && \
   grep -q "^BACKUPS_INCREMENTAL='yes'" "$RM_DIR/hestia/data/packages/default.pkg" && \
   grep -q "^BACKUPS_INCREMENTAL='yes'" "$RM_DIR/hestia/data/users/bob/user.conf"; then
    pass "v-restic-manager --run-daily enables BACKUPS_INCREMENTAL, enrolls Master Key, and removes /home/<user>/backup staging dir"
else
    fail "v-restic-manager --run-daily failed (rc=$rm_daily_rc): $rm_daily_out"
fi

# Test v-restic-manager --export-tar (reconstructs HestiaCP v-restore-user compatible .tar archive from Restic snapshot)
mkdir -p "$RM_DIR/backup"
cat >> "$RM_DIR/hestia/conf/hestia.conf" << EOF
BACKUP='$RM_DIR/backup'
BACKUP_MODE='gzip'
BACKUP_GZIP='6'
EOF
echo "U_BACKUPS='0'" >> "$RM_DIR/hestia/data/users/bob/user.conf"
cat > "$RM_DIR/bin/restic" << EOF
#!/bin/bash
if echo "\$*" | grep -q "restore"; then
    target=""
    while [ \$# -gt 0 ]; do
        if [ "\$1" = "--target" ]; then
            target="\$2"
            shift 2
            continue
        fi
        shift
    done
    mkdir -p "\$target$RM_DIR/home/bob/backup/hestia" "\$target$RM_DIR/home/bob/backup/pam" "\$target$RM_DIR/home/bob/backup/web/example.com/hestia" "\$target$RM_DIR/home/bob/web/example.com/public_html"
    echo "SUSPENDED='no'" > "\$target$RM_DIR/home/bob/backup/hestia/user.conf"
    echo "bob:x:1001:1001::/home/bob:/bin/bash" > "\$target$RM_DIR/home/bob/backup/pam/passwd"
    echo "DOMAIN='example.com'" > "\$target$RM_DIR/home/bob/backup/web/example.com/hestia/web.conf"
    echo "hello world" > "\$target$RM_DIR/home/bob/web/example.com/public_html/index.html"
    echo "alias ll='ls -l'" > "\$target$RM_DIR/home/bob/.bashrc"
    echo "BACKUP='snapshot' TYPE='restic' WEB='example.com' DNS='' MAIL='' DB='' CRON='0' UDIR='' RUNTIME='1' TIME='16:30:26' DATE='2026-11-11' BACKUP_MODE='gzip'" > "\$target$RM_DIR/home/bob/backup/backup.conf"
    exit 0
fi
exit 0
EOF
chmod +x "$RM_DIR/bin/restic"

rm_export_out=$(PATH="$RM_DIR/bin:$PATH" HESTIA="$RM_DIR/hestia" HESTIA_HOME_ROOT="$RM_DIR/home" RESTIC_MANAGER_ALLOW_NONROOT=1 RESTIC_MASTER_KEY_FILE="$RM_DIR/master.key" RESTIC_EXPORT_LOCK_DIR="$RM_DIR/export-locks" bash "$REPO_ROOT/scripts/backup-core-patches/bin/v-restic-manager" --export-tar bob latest 2>&1)
rm_export_rc=$?
exported_tar="$RM_DIR/backup/bob.2026-11-11_16-30-26.tar"
if [ "$rm_export_rc" -eq 0 ] && \
   [ -f "$exported_tar" ] && \
   tar -tf "$exported_tar" | grep -q "^\./web/example.com/domain_data.tar.gz$" && \
   tar -tf "$exported_tar" | grep -q "^\./user_dir/\.bashrc.tar.gz$" && \
   grep -q "BACKUP='bob.2026-11-11_16-30-26.tar' TYPE='local'" "$RM_DIR/hestia/data/users/bob/backup.conf" && \
   grep -q "^U_BACKUPS='1'" "$RM_DIR/hestia/data/users/bob/user.conf"; then
    pass "v-restic-manager --export-tar reconstructs a HestiaCP-compatible .tar archive and registers it in backup.conf"
else
    fail "v-restic-manager --export-tar failed (rc=$rm_export_rc): $rm_export_out"
fi

# -----------------------------------------------------------------------------
if bash "$REPO_ROOT/tests/restic-export.test.sh"; then
    pass "Restic exports publish complete archives atomically and serialize concurrent downloads"
else
    fail "Restic export regression suite failed"
fi

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
