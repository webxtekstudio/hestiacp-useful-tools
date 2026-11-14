#!/bin/bash
# scripts/lib/version-gate.sh
# Pins HestiaCP core file mutations to a verified upstream HestiaCP version.
# Standalone tools continue running even when core patches are placed on hold
# during an unattended HestiaCP upgrade.

SUPPORTED_HESTIA_VERSION="${SUPPORTED_HESTIA_VERSION:-1.10.7}"

hestia_detected_version() {
    local hestia_root="${HESTIA:-/usr/local/hestia}"
    local conf="${hestia_root}/conf/hestia.conf"
    [ -f "$conf" ] || return 0
    sed -n "s/^VERSION=['\"]\?\([^'\"]*\)['\"]\?/\1/p" "$conf" 2>/dev/null | head -n1
}

# Arguments:
#   $1 = mode: "manual" (default) or "apt-hook"
# Return codes:
#   0 = compatible (or explicitly bypassed via ALLOW_UNTESTED_HESTIA=1): apply core patches
#   1 = mismatch in manual mode: abort installation with clear error
#   2 = mismatch in apt-hook mode: hold core patches safely, alert once, keep standalone tools active
check_hestia_core_patch_compatibility() {
    local mode="${1:-manual}"
    local hestia_root="${HESTIA:-/usr/local/hestia}"
    local conf="${hestia_root}/conf/hestia.conf"
    local tools_conf="${HESTIA_TOOLS_CONF:-/etc/hestiacp-useful-tools.conf}"
    local state_dir="${HESTIA_TOOLS_STATE_DIR:-/var/log/hestia}"
    local state_file="${HESTIA_TOOLS_HOLD_FILE:-$state_dir/hestia-tools-version-hold.state}"
    local log_file="${HESTIA_TOOLS_VERSION_LOG:-$state_dir/custom-patches-version.log}"
    local detected=""

    if [ -f "$tools_conf" ]; then
        # shellcheck disable=SC1090
        source "$tools_conf" 2>/dev/null || true
    fi

    detected="$(hestia_detected_version)"

    if [ "${ALLOW_UNTESTED_HESTIA:-0}" = "1" ]; then
        echo "  -> [WARN] Bypassing HestiaCP version gate (--allow-untested-hestia): detected='${detected:-unknown}', supported='${SUPPORTED_HESTIA_VERSION}'" >&2
        return 0
    fi

    if [ "$detected" = "$SUPPORTED_HESTIA_VERSION" ]; then
        rm -f -- "$state_file" 2>/dev/null || true
        return 0
    fi

    if [ "$mode" = "apt-hook" ]; then
        local warn_msg="[WARN] HestiaCP version '${detected:-unknown}' is not yet verified for core file patches (supported: ${SUPPORTED_HESTIA_VERSION}). Skipping core file mutations; standalone tools remain active."
        echo "  -> $warn_msg" >&2

        if (umask 077 && mkdir -p "$state_dir") 2>/dev/null && [ -w "$state_dir" ]; then
            chmod 0700 "$state_dir" 2>/dev/null || true
            printf '%s %s\n' "$(date '+%F %T' 2>/dev/null || echo 'now')" "$warn_msg" >> "$log_file" 2>/dev/null || true

            local prev_held=""
            [ -f "$state_file" ] && prev_held="$(sed -n 's/^held_version=//p' "$state_file" 2>/dev/null | head -n1)"
            if [ "$prev_held" != "${detected:-unknown}" ]; then
                (umask 077 && printf 'held_version=%s\nsupported_version=%s\nheld_at=%s\n' "${detected:-unknown}" "$SUPPORTED_HESTIA_VERSION" "$(date -u '+%FT%TZ' 2>/dev/null || echo 'unknown')" > "$state_file") 2>/dev/null || true
                chmod 0600 "$state_file" 2>/dev/null || true

                local root_user="admin"
                if [ -f "$conf" ]; then
                    local cfg_root=""
                    cfg_root="$(sed -n "s/^ROOT_USER=['\"]\?\([^'\"]*\)['\"]\?/\1/p" "$conf" 2>/dev/null | head -n1)"
                    [ -n "$cfg_root" ] && root_user="$cfg_root"
                fi

                if [ -x "$hestia_root/bin/v-log-action" ]; then
                    "$hestia_root/bin/v-log-action" "system" "Warning" "Updates" "hestiacp-useful-tools held core patches on HestiaCP ${detected:-unknown} (verified: ${SUPPORTED_HESTIA_VERSION})." >/dev/null 2>&1 || true
                fi
                if [ -x "$hestia_root/bin/v-add-user-notification" ]; then
                    "$hestia_root/bin/v-add-user-notification" "$root_user" "hestiacp-useful-tools awaiting update" "HestiaCP updated to ${detected:-unknown}. Core file patches are held until hestiacp-useful-tools is verified for this release (current pin: ${SUPPORTED_HESTIA_VERSION}). Standalone security/backup helpers remain active." >/dev/null 2>&1 || true
                fi

                local admin_email=""
                if [ -f "$hestia_root/data/users/$root_user/user.conf" ]; then
                    admin_email="$(sed -n "s/^CONTACT=['\"]\?\([^'\"]*\)['\"]\?/\1/p" "$hestia_root/data/users/$root_user/user.conf" 2>/dev/null | head -n1)"
                fi
                if [ -z "$admin_email" ] && [ -f "$conf" ]; then
                    admin_email="$(sed -n "s/^CONTACT=['\"]\?\([^'\"]*\)['\"]\?/\1/p" "$conf" 2>/dev/null | head -n1)"
                fi
                local sendmail_bin="$hestia_root/web/inc/mail-wrapper.php"
                if [ -n "$admin_email" ] && [ -x "$sendmail_bin" ]; then
                    {
                        echo "HestiaCP updated to version '${detected:-unknown}' on $(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 'server')."
                        echo ""
                        echo "hestiacp-useful-tools core file patches are pinned to HestiaCP ${SUPPORTED_HESTIA_VERSION} and have been safely held so upstream files are not overwritten blindly."
                        echo "Standalone scripts (v-harden-server, v-restic-manager, v-verify-backups, v-security-audit, v-clean-garbage, custom JS) remain active."
                        echo ""
                        echo "Next step: review and update hestiacp-useful-tools for HestiaCP ${detected:-unknown}, then re-run install.sh."
                    } | "$sendmail_bin" -s "[HOLD] HestiaCP ${detected:-unknown}: hestiacp-useful-tools awaiting update" "$admin_email" "yes" >/dev/null 2>&1 || true
                fi

                if [ -n "${HESTIA_TOOLS_ALERT_HOOK:-}" ] && [ -x "${HESTIA_TOOLS_ALERT_HOOK}" ]; then
                    "${HESTIA_TOOLS_ALERT_HOOK}" "${detected:-unknown}" "$SUPPORTED_HESTIA_VERSION" >/dev/null 2>&1 || true
                fi
            fi
        fi
        return 2
    fi

    echo "ERROR: hestiacp-useful-tools core patches are pinned to HestiaCP ${SUPPORTED_HESTIA_VERSION}, but detected '${detected:-unknown}'." >&2
    echo "Update hestiacp-useful-tools to a release verified for '${detected:-unknown}', or pass --allow-untested-hestia to force." >&2
    return 1
}
