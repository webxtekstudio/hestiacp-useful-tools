#!/bin/bash


check_firewall() {
    section "SYSTEM" "Firewall & Fail2Ban"

    if is_service_active fail2ban; then
        result_pass "S13" "Fail2Ban is running"
    else
        result_fail "S13" "Fail2Ban is NOT running"
    fi

    local ssh_jail
    ssh_jail=$(fail2ban-client status sshd 2>/dev/null || fail2ban-client status ssh-iptables 2>/dev/null)
    if [ $? -eq 0 ]; then
        local banned
        banned=$(echo "$ssh_jail" | grep "Currently banned" | awk '{print $NF}')
        result_pass "S14" "SSH jail is active (${banned} currently banned)"
    else
        result_fail "S14" "SSH Fail2Ban jail is NOT active"
    fi

    local recidive
    recidive=$(fail2ban-client status recidive 2>/dev/null)
    if [ $? -eq 0 ]; then
        result_pass "S15" "Recidive jail is active (repeat offender protection)"
    else
        result_warn "S15" "Recidive jail is not active (recommend enabling)"
    fi

    # S15b: WordPress Fail2Ban jail — must cover both xmlrpc.php AND wp-login.php
    local wp_jail
    wp_jail=$(fail2ban-client status wordpress-xmlrpc 2>/dev/null)
    if [ $? -eq 0 ]; then
        local wp_banned
        wp_banned=$(echo "$wp_jail" | grep "Currently banned" | awk '{print $NF}')
        result_pass "S15b" "WordPress jail is active (${wp_banned} currently banned)"

        # Check that the filter covers wp-login.php, not just xmlrpc.php
        local wp_filter="/etc/fail2ban/filter.d/wordpress-xmlrpc.conf"
        if [ -f "$wp_filter" ]; then
            if grep -q 'wp-login' "$wp_filter" 2>/dev/null; then
                result_pass "S15c" "WordPress filter covers wp-login.php brute-force"
            else
                result_fail "S15c" "WordPress filter does NOT cover wp-login.php (only xmlrpc.php) — brute-force attacks on wp-login will go unblocked"
            fi
        else
            result_warn "S15c" "WordPress filter file not found at ${wp_filter}"
        fi
    else
        # Check if any WordPress sites exist (look for wp-login in Apache logs)
        if find /var/log/apache2/domains/ -name '*.log' -exec grep -ql 'wp-login' {} + 2>/dev/null; then
            result_fail "S15b" "WordPress jail is NOT active but WordPress sites are being attacked"
        else
            result_pass "S15b" "WordPress jail is not active (no WordPress sites detected)"
        fi
    fi

    if [ -f /usr/local/hestia/conf/hestia.conf ]; then
        local fw
        fw=$(grep "^FIREWALL=" /usr/local/hestia/conf/hestia.conf 2>/dev/null | cut -d"'" -f2)
        if [ "$fw" = "yes" ]; then
            result_pass "S16" "HestiaCP firewall is enabled"
        else
            result_fail "S16" "HestiaCP firewall is DISABLED"
        fi
    fi

    local listen_ports
    listen_ports=$(ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | sed 's/.*://' | sort -un)
    if [ -z "$listen_ports" ]; then
        listen_ports=$(netstat -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | sed 's/.*://' | sort -un)
    fi
    local known_ports="22 25 53 80 110 143 443 465 587 993 995 3306 8083"
    local unknown_ports=""
    for p in $listen_ports; do
        local is_known=false
        for kp in $known_ports; do
            if [ "$p" = "$kp" ]; then is_known=true; break; fi
        done
        local ssh_port_val
        ssh_port_val=$(parse_sshd_config "Port")
        if [ "$p" = "$ssh_port_val" ]; then is_known=true; fi
        if ! $is_known && [ "$p" -gt 1024 ] 2>/dev/null; then
            unknown_ports="${unknown_ports} ${p}"
        fi
    done
    if [ -n "$unknown_ports" ]; then
        result_warn "S17" "Unexpected ports listening:${unknown_ports}"
    else
        result_pass "S17" "Only expected ports are listening"
    fi
}


check_f2b_iptables_sync() {
    section "SYSTEM" "Fail2Ban ↔ iptables Sync"

    # Maps jail names to their Hestia iptables chain names
    local jails="wordpress-xmlrpc:WEB dovecot-iptables:MAIL ssh-iptables:SSH exim-iptables:MAIL"
    local total_desync=0

    for jail_chain in $jails; do
        local jail="${jail_chain%%:*}"
        local chain="fail2ban-${jail_chain##*:}"

        local f2b_count
        f2b_count=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
        if [ -z "$f2b_count" ]; then continue; fi

        local ipt_count
        ipt_count=$(iptables -L "$chain" -n 2>/dev/null | grep -cE 'REJECT|DROP')

        # Allow small variance (shared chains like MAIL serve multiple jails)
        local diff=$(( f2b_count - ipt_count ))
        if [ $diff -lt 0 ]; then diff=$(( -diff )); fi

        if [ "$f2b_count" -gt 0 ] && [ "$ipt_count" -eq 0 ]; then
            result_fail "S18" "DESYNC: ${jail} has ${f2b_count} bans but ${chain} has 0 iptables rules — bans are NOT blocking traffic"
            total_desync=$((total_desync + 1))
        elif [ "$diff" -gt $(( f2b_count / 5 + 1 )) ]; then
            result_warn "S18" "DRIFT: ${jail} has ${f2b_count} bans vs ${ipt_count} iptables rules in ${chain} (>20% difference)"
            total_desync=$((total_desync + 1))
        fi
    done

    if [ $total_desync -eq 0 ]; then
        result_pass "S18" "Fail2Ban bans are in sync with iptables rules"
    fi
}


check_wp_xmlrpc_blocks() {
    section "SYSTEM" "WordPress xmlrpc.php Protection"

    local wp_sites
    wp_sites=$(find /home/*/web/*/public_html -maxdepth 1 -name "wp-config.php" -type f 2>/dev/null)

    if [ -z "$wp_sites" ]; then
        result_pass "S19" "No WordPress sites detected"
        return
    fi

    local total=0
    local unprotected=0
    local unprotected_list=""

    while IFS= read -r wp; do
        local domain user conf_dir
        domain=$(echo "$wp" | grep -oP '/web/\K[^/]+')
        user=$(echo "$wp" | grep -oP '/home/\K[^/]+')
        conf_dir="/home/${user}/conf/web/${domain}"

        total=$((total + 1))

        # Check for xmlrpc block: either _xmlrpc file or _security file containing xmlrpc
        local has_block=false
        if [ -f "${conf_dir}/nginx.ssl.conf_xmlrpc" ] || [ -f "${conf_dir}/nginx.conf_xmlrpc" ]; then
            has_block=true
        elif [ -f "${conf_dir}/nginx.ssl.conf_security" ] && grep -q 'xmlrpc' "${conf_dir}/nginx.ssl.conf_security" 2>/dev/null; then
            has_block=true
        fi

        if ! $has_block; then
            unprotected=$((unprotected + 1))
            unprotected_list="${unprotected_list} ${domain}"
        fi
    done <<< "$wp_sites"

    if [ $unprotected -gt 0 ]; then
        result_fail "S19" "${unprotected}/${total} WordPress site(s) missing xmlrpc.php nginx block:${unprotected_list}"
    else
        result_pass "S19" "All ${total} WordPress site(s) have xmlrpc.php blocked in nginx"
    fi
}


