#!/bin/bash
# lib/hestia.sh - HestiaCP Patches
#
# Patches:
#   backup.sh → b2_backup/b2_download/b2_delete use organized YYYY/MM paths
#   v-delete-user-backup → follows symlinks
#
# All patches are idempotent (safe to re-run).

export HESTIA="${HESTIA:-/usr/local/hestia}"

# ── Patch b2 functions in backup.sh ────────────────────────────────
patch_b2_functions() {
    local script="$HESTIA/func/backup.sh"
    [ ! -f "$script" ] && return 1
    grep -q "hestia-custom-b2-v5-retry" "$script" 2>/dev/null && return 0

    [ ! -f "${script}.original" ] && cp "$script" "${script}.original" 2>/dev/null

    if ! grep -q "^b2_backup() {" "$script" || ! grep -q "^b2_download() {" "$script" || ! grep -q "^b2_delete() {" "$script"; then
        return 1
    fi

    local temp repl_file
    temp=$(mktemp /tmp/patch-b2-v5.XXXXXX)
    repl_file=$(mktemp /tmp/patch-b2-v5-body.XXXXXX)
    chmod 600 "$temp" "$repl_file"

    cat > "$repl_file" << 'PATCH_EOF'
b2_backup() {
	# hestia-custom-b2-v5-retry
	# Defining backblaze b2 settings
	source_conf "$HESTIA/conf/b2.backup.conf"

	_b2_year=$(date +%Y)
	_b2_month=$(LC_TIME=C date +%m_%B | tr '[:lower:]' '[:upper:]')
	_b2_remote_path="${_b2_year}/${_b2_month}/${user}/${user}.${backup_new_date}.tar"
	echo -e "$(date "+%F %T") Upload to B2: $_b2_remote_path"

	if [ "$localbackup" != 'yes' ]; then
		cd "$tmpdir"
		tar -cf "$BACKUP/$user.$backup_new_date.tar" .
	fi
	cd "$BACKUP/"

	rc=1
	_b2_err=""
	for _b2_attempt in 1 2 3; do
		b2 clear-account > /dev/null 2>&1
		b2 authorize-account "$B2_KEYID" "$B2_KEY" > /dev/null 2>&1
		_b2_err=$(b2 upload-file --no-progress "$BUCKET" "$user.$backup_new_date.tar" "$_b2_remote_path" 2>&1 >/dev/null)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			break
		fi
		_b2_err_line=$(printf '%s' "$_b2_err" | tr '\r\n' '  ' | sed 's/  */ /g')
		echo -e "$(date "+%F %T") WARN: B2 upload attempt ${_b2_attempt}/3 failed (rc=${rc}): ${_b2_err_line}"
		if [ "$_b2_attempt" -lt 3 ]; then
			sleep $((_b2_attempt * 10))
		fi
	done

	if [ "$localbackup" != 'yes' ]; then
		rm -f "$user.$backup_new_date.tar"
	fi
	if [ "$rc" -ne 0 ]; then
		check_result "$E_CONNECT" "b2 failed to upload $user.$backup_new_date.tar"
	fi

	# Checking retention (compatible with both B2 CLI v4 b2:// URI and v3 positional bucket)
	backup_list=$({ b2 ls "b2://$BUCKET" --recursive --long 2>/dev/null || b2 ls "$BUCKET" --recursive --long 2>/dev/null; } | awk -v user="$user" '
		$NF ~ ("(^|/)" user "/" user "\\.[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\\.tar$") {
			archive = $NF
			sub(/^.*\//, "", archive)
			print archive "|" $1 "|" $NF
		}
	' | sort -t'|' -k1,1)
	backups_count=$(echo "$backup_list" | sed '/^$/d' | wc -l)
	if [ "$backups_count" -gt "$BACKUPS" ]; then
		backups_rm_number=$((backups_count - BACKUPS))
		echo "$backup_list" | head -n "$backups_rm_number" | while IFS='|' read -r backup_archive backup_id backup_file_name; do
			[ -z "$backup_id" ] && continue
			if b2 delete-file-version "$backup_id" > /dev/null 2>&1; then
				echo -e "$(date "+%F %T") Rotated b2 backup: $backup_file_name"
			else
				echo -e "$(date "+%F %T") Failed to rotate b2 backup: $backup_file_name"
			fi
		done
	fi
}

b2_download() {
	# hestia-custom-b2-v5-download
	source_conf "$HESTIA/conf/b2.backup.conf"

	b2 clear-account > /dev/null 2>&1
	b2 authorize-account "$B2_KEYID" "$B2_KEY" > /dev/null 2>&1
	cd "$BACKUP"

	_b2_remote=$({ b2 ls "b2://$BUCKET" --recursive 2>/dev/null || b2 ls "$BUCKET" --recursive 2>/dev/null; } | awk -v target="$1" '
		{
			base = $0
			sub(/^.*\//, "", base)
			if (base == target) { print $0; exit }
		}
	')
	if [ -n "$_b2_remote" ]; then
		for _b2_attempt in 1 2 3; do
			if b2 download-file-by-name --no-progress "$BUCKET" "$_b2_remote" "$1" > /dev/null 2>&1; then
				return 0
			fi
			[ "$_b2_attempt" -lt 3 ] && sleep 5
		done
	fi
	b2 download-file-by-name --no-progress "$BUCKET" "$user/$1" "$1" > /dev/null 2>&1
	if [ "$?" -ne 0 ]; then
		check_result "$E_CONNECT" "b2 failed to download $user.$1"
	fi
}

b2_delete() {
	# hestia-custom-b2-v5-delete
	source_conf "$HESTIA/conf/b2.backup.conf"

	b2 clear-account > /dev/null 2>&1
	b2 authorize-account "$B2_KEYID" "$B2_KEY" > /dev/null 2>&1

	_del_ids=$({ b2 ls "b2://$BUCKET" --recursive --long 2>/dev/null || b2 ls "$BUCKET" --recursive --long 2>/dev/null; } | awk -v target="$2" '
		{
			base = $NF
			sub(/^.*\//, "", base)
			if (base == target) { print $1 }
		}
	')
	for _did in $_del_ids; do
		b2 delete-file-version "$_did" > /dev/null 2>&1
	done
}
PATCH_EOF

    awk -v repl_file="$repl_file" '
        /^b2_backup\(\) \{/ {
            while ((getline line < repl_file) > 0) print line
            close(repl_file)
            in_skip = 1
            next
        }
        /^b2_(download|delete)\(\) \{/ {
            in_skip = 1
            next
        }
        in_skip && /^\}$/ {
            in_skip = 0
            next
        }
        !in_skip { print }
    ' "$script" > "$temp"

    rm -f "$repl_file" 2>/dev/null

    if grep -q "hestia-custom-b2-v5-retry" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
        # Remove empty gap lines if consecutive skipped blocks left extra blank lines
        mv "$temp" "$script" && chmod +x "$script"
        _log "[$(date)] : Patched b2_backup/b2_download/b2_delete (v5 retry + B2 CLI v4 URI support)"
        return 0
    fi

    rm -f "$temp" 2>/dev/null
    return 1
}

# ── Patch v-backup-user (Local Organization Hook) ───────────────────
patch_v_backup_user() {
    local script="$HESTIA/bin/v-backup-user"
    [ ! -f "$script" ] && return 1
    grep -q "hestia-custom-hook-v1" "$script" 2>/dev/null && return 0

    [ ! -f "${script}.original" ] && cp "$script" "${script}.original" 2>/dev/null

    local temp=$(mktemp /tmp/patch-backup-user.XXXXXX)
    local line_num=$(grep -n 'log_event "$OK" "$ARGUMENTS"' "$script" | cut -d: -f1 | head -1)

    if [ -n "$line_num" ]; then
        sed -n "1,$((line_num-1))p" "$script" > "$temp"
        cat >> "$temp" << 'PATCH_EOF'
# hestia-custom-hook-v1: automatic local organization
if [ -f "/usr/local/hestia/bin/v-backup-user-hook" ]; then
    bash /usr/local/hestia/bin/v-backup-user-hook "$user" "$user.$backup_new_date.tar" || true
fi

PATCH_EOF
        sed -n "$line_num,\$p" "$script" >> "$temp"

        if grep -q "hestia-custom-hook-v1" "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod +x "$script"
            _log "[$(date)] : Patched v-backup-user (Local Organization Hook)"
            return 0
        fi
    fi
    rm -f "$temp" 2>/dev/null
    return 1
}

# ── Patch v-delete-user-backup ──────────────────────────────────────
patch_delete_command() {
    local script="$HESTIA/bin/v-delete-user-backup"
    [ ! -f "$script" ] && return 1
    grep -q "hestia-backup-symlink-handler" "$script" 2>/dev/null && return 0

    [ ! -f "${script}.original" ] && cp "$script" "${script}.original" 2>/dev/null

    local temp=$(mktemp /tmp/patch-delete.XXXXXX)
    local line_num=$(grep -n 'rm -f "$backup_folder/$2"' "$script" | cut -d: -f1 | head -1)

    if [ -n "$line_num" ]; then
        sed -n "1,$((line_num-1))p" "$script" > "$temp"
        cat >> "$temp" << 'PATCH_EOF'
		# hestia-backup-symlink-handler
		backup_file_path="$backup_folder/$2"
		if [ -L "$backup_file_path" ]; then
			real_file=$(readlink -f "$backup_file_path" 2>/dev/null)
			rm -f "$backup_file_path"
			[ -n "$real_file" ] && [ -f "$real_file" ] && rm -f "$real_file" "${real_file%.tar}.log" 2>/dev/null
		else
			rm -f "$backup_file_path"
		fi
PATCH_EOF
        sed -n "$((line_num+1)),\$p" "$script" >> "$temp"

        if grep -q "hestia-backup-symlink-handler" "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod +x "$script"
            _log "[$(date)] : Patched v-delete-user-backup (symlink-aware)"
            return 0
        fi
    fi
    rm -f "$temp" 2>/dev/null
    return 1
}

# ── Phase 0: Patch v-backup-user (Database Auto-Repair) ─────────────
patch_v_backup_user_db_repair() {
    local script="$HESTIA/bin/v-backup-user"
    [ ! -f "$script" ] && return 1
    grep -q "hestia-custom-db-repair" "$script" 2>/dev/null && return 0

    [ ! -f "${script}.original" ] && cp "$script" "${script}.original" 2>/dev/null

    local temp=$(mktemp /tmp/patch-db-repair.XXXXXX)
    local line_num=$(grep -n 'case $TYPE in' "$script" | cut -d: -f1 | head -1)

    if [ -n "$line_num" ]; then
        sed -n "1,$((line_num-1))p" "$script" > "$temp"
		cat >> "$temp" << 'PATCH_EOF'
			# hestia-custom-db-repair
			if [ "$TYPE" = "mysql" ]; then
				echo "$database (Auto-Check & Repair)"
				if command -v mariadb-check >/dev/null 2>&1; then
					mariadb-check --check --auto-repair "$database" >> $BACKUP/$user.log 2>&1
				elif command -v mysqlcheck >/dev/null 2>&1; then
					mysqlcheck --check --auto-repair "$database" >> $BACKUP/$user.log 2>&1
				else
					mysqlrepair --check --auto-repair "$database" >> $BACKUP/$user.log 2>&1
				fi
			fi
PATCH_EOF
        sed -n "$line_num,\$p" "$script" >> "$temp"

        if grep -q "hestia-custom-db-repair" "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod +x "$script"
            _log "[$(date)] : Patched v-backup-user (DB Auto-Repair)"
            return 0
        fi
    fi
    rm -f "$temp" 2>/dev/null
    return 1
}

# ── Phase 1: Patch v-backup-users (Interactive Console) ─────────────
patch_v_backup_users_interactive() {
    local script="$HESTIA/bin/v-backup-users"
    [ ! -f "$script" ] && return 1
    grep -q "hestia-custom-interactive" "$script" 2>/dev/null && return 0

    local temp=$(mktemp /tmp/patch-interactive.XXXXXX)
    local line_num=$(grep -n 'nice -n 19 ionice -c2 -n7 $BIN/v-backup-user $user >> $log' "$script" | cut -d: -f1 | head -1)

    if [ -n "$line_num" ]; then
        sed -n "1,$((line_num-1))p" "$script" > "$temp"
        cat >> "$temp" << 'PATCH_EOF'
		# hestia-custom-interactive
		if [ -t 1 ]; then
			nice -n 19 ionice -c2 -n7 $BIN/v-backup-user $user 2>&1 | tee -a $log
		else
			nice -n 19 ionice -c2 -n7 $BIN/v-backup-user $user >> $log 2>&1
		fi
PATCH_EOF
        sed -n "$((line_num+1)),\$p" "$script" >> "$temp"

        if grep -q "hestia-custom-interactive" "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod +x "$script"
            _log "[$(date)] : Patched v-backup-users (Interactive Console Mode)"
            return 0
        fi
    fi
    rm -f "$temp" 2>/dev/null
    return 1
}

# ── Phase 2: Patch v-backup-user (Individual HTML Email) ────────────
patch_v_backup_user_notify() {
    local script="$HESTIA/bin/v-backup-user"
    [ ! -f "$script" ] && return 1
    grep -q "hestia-custom-notify-hook" "$script" 2>/dev/null && return 0

    local temp=$(mktemp /tmp/patch-notify.XXXXXX)
    local line_num=$(grep -n '\$SENDMAIL -s "$subj" "$email" "$notify"' "$script" | cut -d: -f1 | head -1)

    if [ -n "$line_num" ]; then
        sed -n "1,$((line_num-1))p" "$script" > "$temp"
        cat >> "$temp" << 'PATCH_EOF'
	# hestia-custom-notify-hook
	if [ -f "/usr/local/hestia/bin/v-backup-user-notify-hook" ]; then
		bash /usr/local/hestia/bin/v-backup-user-notify-hook "$user" "$subj" "$email" "$notify" "$BACKUP/$user.log"
	else
		cat $BACKUP/$user.log | $SENDMAIL -s "$subj" "$email" "$notify"
	fi
PATCH_EOF
        sed -n "$((line_num+1)),\$p" "$script" >> "$temp"

        if grep -q "hestia-custom-notify-hook" "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod +x "$script"
            _log "[$(date)] : Patched v-backup-user (Individual HTML Email)"
            return 0
        fi
    fi
    rm -f "$temp" 2>/dev/null
    return 1
}

# ── Phase 3: Patch v-backup-users (Global Master HTML Email) ────────
patch_v_backup_users_notify() {
    local script="$HESTIA/bin/v-backup-users"
    [ ! -f "$script" ] && return 1
    grep -q "hestia-custom-notify-global-hook" "$script" 2>/dev/null && return 0

    local temp=$(mktemp /tmp/patch-global-notify.XXXXXX)
    local line_num=$(grep -n '^exit' "$script" | tail -1 | cut -d: -f1)

    if [ -n "$line_num" ]; then
        sed -n "1,$((line_num-1))p" "$script" > "$temp"
        cat >> "$temp" << 'PATCH_EOF'
# hestia-custom-notify-global-hook
if [ -f "/usr/local/hestia/bin/v-backup-users-notify-hook" ]; then
    bash /usr/local/hestia/bin/v-backup-users-notify-hook
fi

exit
PATCH_EOF
        sed -n "$((line_num+1)),\$p" "$script" >> "$temp"

        if grep -q "hestia-custom-notify-global-hook" "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod +x "$script"
            _log "[$(date)] : Patched v-backup-users (Global HTML Email)"
            return 0
        fi
    fi
    rm -f "$temp" 2>/dev/null
    return 1
}

# ── Phase 4: Patch Queued Removals (Silence 'rm' cron errors) ───────
# Phase 3.1: Patch v-backup-users (Optional Retention Hook)
patch_v_backup_users_retention() {
    local script="$HESTIA/bin/v-backup-users"
    [ ! -f "$script" ] && return 1
    grep -q "hestia-custom-retention-hook" "$script" 2>/dev/null && return 0

    [ ! -f "${script}.original" ] && cp "$script" "${script}.original" 2>/dev/null

    local temp=$(mktemp /tmp/patch-retention-hook.XXXXXX)
    local line_num=$(grep -n '^exit' "$script" | tail -1 | cut -d: -f1)

    if [ -n "$line_num" ]; then
        sed -n "1,$((line_num-1))p" "$script" > "$temp"
        cat >> "$temp" << 'PATCH_EOF'
# hestia-custom-retention-hook
if [ -f "/usr/local/hestia/bin/v-backup-users-retention-hook" ]; then
    bash /usr/local/hestia/bin/v-backup-users-retention-hook || true
fi

PATCH_EOF
        sed -n "$line_num,\$p" "$script" >> "$temp"

        if grep -q "hestia-custom-retention-hook" "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod +x "$script"
            _log "[$(date)] : Patched v-backup-users (Optional Retention Hook)"
            return 0
        fi
    fi
    rm -f "$temp" 2>/dev/null
    return 1
}

# Phase 4: Patch Queued Removals (Silence 'rm' cron errors)
patch_cron_rm_silence() {
    local scripts=(
        "$HESTIA/bin/v-download-backup"
        "$HESTIA/bin/v-dump-database"
        "$HESTIA/bin/v-dump-site"
    )
    local patched=0
    for script in "${scripts[@]}"; do
        if [ -f "$script" ]; then
            if ! grep -q 'echo "rm -f $BACKUP' "$script" 2>/dev/null; then
                [ ! -f "${script}.original" ] && cp "$script" "${script}.original" 2>/dev/null
                sed -i 's|echo "rm \$BACKUP|echo "rm -f \$BACKUP|g' "$script"
                patched=$((patched+1))
            fi
        fi
    done
    if [ "$patched" -gt 0 ]; then
        _log "[$(date)] : Patched $patched scripts to silence queued 'rm' tasks (added -f)"
        return 0
    fi
    return 1
}

# ── Entry point ──────────────────────────────────────────────────────
apply_hestia_patches() {
    _log "[$(date)] : Applying Hestia patches..."
    patch_delete_command || true
    patch_b2_functions || true
    patch_v_backup_user_db_repair || true
    patch_v_backup_user || true
    patch_v_backup_user_notify || true
    patch_v_backup_users_interactive || true
    patch_v_backup_users_notify || true
    patch_v_backup_users_retention || true
    patch_cron_rm_silence || true
    return 0
}
