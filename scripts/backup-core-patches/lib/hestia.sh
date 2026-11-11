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
    grep -q "hestia-custom-b2-v5.5-staticx-tmpdir" "$script" 2>/dev/null && return 0

    if grep -q "hestia-custom-b2-v" "$script" 2>/dev/null; then
        [ -f "${script}.original" ] && cp "${script}.original" "$script" 2>/dev/null || true
    else
        # Fresh upstream HestiaCP file (e.g. after apt upgrade) — refresh .original snapshot
        cp -f "$script" "${script}.original" 2>/dev/null || true
    fi

    if ! grep -q "^b2_backup() {" "$script" || ! grep -q "^b2_download() {" "$script" || ! grep -q "^b2_delete() {" "$script"; then
        return 1
    fi

    local temp repl_file
    temp=$(mktemp /run/patch-b2-v5.XXXXXX) || return 1
    repl_file=$(mktemp /run/patch-b2-v5-body.XXXXXX) || { rm -f "$temp"; return 1; }
    chmod 600 "$temp" "$repl_file"

    cat > "$repl_file" << 'PATCH_EOF'
b2_backup() {
	# hestia-custom-b2-v5.5-staticx-tmpdir
	# hestia-custom-b2-v5.4-verify
	# hestia-custom-b2-v5.3-retry
	# hestia-custom-b2-v4-retention
	# Defining backblaze b2 settings
	source_conf "$HESTIA/conf/b2.backup.conf"
	_b2_tmpdir="${TMPDIR:-/tmp}"
	if [ "$(id -u)" -eq 0 ] && install -d -m 0700 -o root -g root /var/cache/b2-staticx 2>/dev/null; then
		_b2_tmpdir="/var/cache/b2-staticx"
	fi

	_bkp_root="${BACKUP%/}"
	if [ -z "$_bkp_root" ] || [ ! -d "$_bkp_root" ]; then
		check_result "$E_NOTEXIST" "Backup directory $_bkp_root does not exist"
	fi

	_b2_year=$(date +%Y)
	_b2_month=$(LC_TIME=C date +%m_%B | tr '[:lower:]' '[:upper:]')
	_b2_remote_path="${_b2_year}/${_b2_month}/${user}/${user}.${backup_new_date}.tar"
	echo -e "$(date "+%F %T") Upload to B2: $_b2_remote_path"

	if [ "$localbackup" != 'yes' ]; then
		if [ -z "$tmpdir" ] || [ ! -d "$tmpdir" ] || ! cd "$tmpdir"; then
			[ -n "$tmpdir" ] && [[ "$tmpdir" == "$_bkp_root/tmp."* ]] && rm -rf "$tmpdir"
			check_result "$E_NOTEXIST" "Failed to enter backup staging directory $tmpdir"
		fi
		tar -cf "$_bkp_root/$user.$backup_new_date.tar" .
		_tar_rc=$?
		if [ "$_tar_rc" -gt 1 ] || [ ! -s "$_bkp_root/$user.$backup_new_date.tar" ]; then
			rm -f "$_bkp_root/$user.$backup_new_date.tar"
			[ -n "$tmpdir" ] && [[ "$tmpdir" == "$_bkp_root/tmp."* ]] && rm -rf "$tmpdir"
			check_result "$E_DISK" "tar failed (rc=$_tar_rc) creating $user.$backup_new_date.tar"
		fi
	fi
	if ! cd "$_bkp_root"; then
		[ "$localbackup" != 'yes' ] && rm -f "$_bkp_root/$user.$backup_new_date.tar"
		[ -n "$tmpdir" ] && [[ "$tmpdir" == "$_bkp_root/tmp."* ]] && rm -rf "$tmpdir"
		check_result "$E_NOTEXIST" "Failed to enter backup directory $_bkp_root"
	fi

	rc=1
	_b2_err=""
	for _b2_attempt in 1 2 3; do
		_b2_err=$(TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 file upload --no-progress "$BUCKET" "$user.$backup_new_date.tar" "$_b2_remote_path" 2>&1 >/dev/null)
		rc=$?
		if [ "$rc" -ne 0 ] && printf '%s' "$_b2_err" | grep -qiE "invalid choice|unrecognized|unknown|usage:"; then
			_b2_err=$(TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 upload-file --noProgress "$BUCKET" "$user.$backup_new_date.tar" "$_b2_remote_path" 2>&1 >/dev/null)
			rc=$?
		fi
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
		rm -f "$_bkp_root/$user.$backup_new_date.tar"
	fi
	if [ "$rc" -ne 0 ]; then
		[ -n "$tmpdir" ] && [[ "$tmpdir" == "$_bkp_root/tmp."* ]] && rm -rf "$tmpdir"
		check_result "$E_CONNECT" "b2 failed to upload $user.$backup_new_date.tar"
	fi

	# Record standalone v-backup-user B2 uploads in global backup.log so monitoring sees retries immediately
	_global_bkp_log="$HESTIA/log/backup.log"
	if [ -f "$_global_bkp_log" ] && [ "$(stat -c '%d:%i' /proc/$$/fd/1 2>/dev/null)" != "$(stat -c '%d:%i' "$_global_bkp_log" 2>/dev/null)" ]; then
		printf '\n-- SUMMARY (SINGLE-USER RETRY: %s) --\n%s Upload to B2: %s\n' "$user" "$(date "+%F %T")" "$_b2_remote_path" >> "$_global_bkp_log" 2>/dev/null || true
		[ -x "$HESTIA/bin/v-verify-backups" ] && "$HESTIA/bin/v-verify-backups" --quiet >/dev/null 2>&1 || true
	fi

	# Checking retention (compatible with both B2 CLI v4 b2:// URI and v3 positional bucket)
	backup_list=$({ TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 ls "b2://$BUCKET" --recursive --long 2>/dev/null || TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 ls "$BUCKET" --recursive --long 2>/dev/null; } | awk -v user="$user" '
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
			if TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 delete-file-version "$backup_file_name" "$backup_id" > /dev/null 2>&1; then
				echo -e "$(date "+%F %T") Rotated b2 backup: $backup_file_name"
			else
				echo -e "$(date "+%F %T") Failed to rotate b2 backup: $backup_file_name"
			fi
		done
	fi
}

b2_download() {
	# hestia-custom-b2-v5.5-download
	source_conf "$HESTIA/conf/b2.backup.conf"
	_b2_tmpdir="${TMPDIR:-/tmp}"
	if [ "$(id -u)" -eq 0 ] && install -d -m 0700 -o root -g root /var/cache/b2-staticx 2>/dev/null; then
		_b2_tmpdir="/var/cache/b2-staticx"
	fi

	_bkp_root="${BACKUP%/}"
	if [ -z "$_bkp_root" ] || [ ! -d "$_bkp_root" ] || ! cd "$_bkp_root"; then
		check_result "$E_NOTEXIST" "Failed to enter backup directory $_bkp_root"
	fi

	_b2_remote=$({ TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 ls "b2://$BUCKET" --recursive 2>/dev/null || TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 ls "$BUCKET" --recursive 2>/dev/null; } | awk -v usr="$user" -v target="$1" '
		{
			line = $0
			base = line
			sub(/^.*\//, "", base)
			if (base != target) next
			if (usr != "") {
				suffix = "/" usr "/" target
				exact = usr "/" target
				if (line == exact || (length(line) >= length(suffix) && substr(line, length(line) - length(suffix) + 1) == suffix)) {
					print line
					exit
				}
			} else {
				print line
				exit
			}
		}
	')
	if [ -n "$_b2_remote" ]; then
		for _b2_attempt in 1 2 3; do
			if TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 file download --no-progress "b2://$BUCKET/$_b2_remote" "$1" > /dev/null 2>&1 || \
			   TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 download-file-by-name --noProgress "$BUCKET" "$_b2_remote" "$1" > /dev/null 2>&1; then
				return 0
			fi
			[ "$_b2_attempt" -lt 3 ] && sleep 5
		done
	fi
	if ! TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 file download --no-progress "b2://$BUCKET/$user/$1" "$1" > /dev/null 2>&1 && \
	   ! TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 download-file-by-name --noProgress "$BUCKET" "$user/$1" "$1" > /dev/null 2>&1; then
		check_result "$E_CONNECT" "b2 failed to download $user.$1"
	fi
}

b2_delete() {
	# hestia-custom-b2-v5.5-delete
	source_conf "$HESTIA/conf/b2.backup.conf"
	_b2_tmpdir="${TMPDIR:-/tmp}"
	if [ "$(id -u)" -eq 0 ] && install -d -m 0700 -o root -g root /var/cache/b2-staticx 2>/dev/null; then
		_b2_tmpdir="/var/cache/b2-staticx"
	fi

	{ TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 ls "b2://$BUCKET" --recursive --long 2>/dev/null || TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 ls "$BUCKET" --recursive --long 2>/dev/null; } | awk -v usr="$1" -v target="$2" '
		{
			path = $NF
			base = path
			sub(/^.*\//, "", base)
			if (base != target) next
			if (usr != "") {
				suffix = "/" usr "/" target
				exact = usr "/" target
				if (path == exact || (length(path) >= length(suffix) && substr(path, length(path) - length(suffix) + 1) == suffix)) {
					print $1 "|" path
				}
			} else {
				print $1 "|" path
			}
		}
	' | while IFS='|' read -r _did _dpath; do
		[ -n "$_did" ] || continue
		TMPDIR="$_b2_tmpdir" B2_APPLICATION_KEY_ID="$B2_KEYID" B2_APPLICATION_KEY="$B2_KEY" b2 delete-file-version "$_dpath" "$_did" > /dev/null 2>&1
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

    if grep -q "hestia-custom-b2-v5.5-staticx-tmpdir" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
        mv "$temp" "$script" && chmod 755 "$script"
        _log "[$(date)] : Patched b2_backup/b2_download/b2_delete (v5.5 staticx tmpdir + verify + retry + global log sync + B2 CLI v4/v3)"
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

    local temp=$(mktemp /run/patch-backup-user.XXXXXX)
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

        if grep -q "hestia-custom-hook-v1" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod 755 "$script"
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
    grep -q "hestia-backup-symlink-handler-v2" "$script" 2>/dev/null && return 0

    if grep -q "hestia-backup-symlink-handler" "$script" 2>/dev/null; then
        [ -f "${script}.original" ] && cp "${script}.original" "$script" 2>/dev/null || true
    else
        cp -f "$script" "${script}.original" 2>/dev/null || true
    fi

    local temp
    temp=$(umask 077 && mktemp /run/patch-delete.XXXXXX) || return 1
    local line_num=$(grep -n 'rm -f "$backup_folder/$2"' "$script" | cut -d: -f1 | head -1)

    if [ -n "$line_num" ]; then
        sed -n "1,$((line_num-1))p" "$script" > "$temp"
        cat >> "$temp" << 'PATCH_EOF'
		# hestia-backup-symlink-handler-v2
		backup_file_path="$backup_folder/$2"
		if [ -L "$backup_file_path" ]; then
			real_root=$(readlink -f "$backup_folder" 2>/dev/null)
			real_file=$(readlink -f "$backup_file_path" 2>/dev/null)
			rm -f -- "$backup_file_path"
			if [ -n "$real_file" ] && [ -n "$real_root" ] && [[ "$real_file" == "${real_root%/}/"* ]] && [ -f "$real_file" ]; then
				rm -f -- "$real_file" "${real_file%.tar}.log" 2>/dev/null
			fi
		else
			rm -f -- "$backup_file_path"
		fi
PATCH_EOF
        sed -n "$((line_num+1)),\$p" "$script" >> "$temp"

        if grep -q "hestia-backup-symlink-handler-v2" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod 755 "$script"
            _log "[$(date)] : Patched v-delete-user-backup (symlink-aware v2)"
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

    if ! grep -q "hestia-custom-" "$script" 2>/dev/null; then
        cp -f "$script" "${script}.original" 2>/dev/null || true
    elif [ ! -f "${script}.original" ]; then
        cp "$script" "${script}.original" 2>/dev/null || true
    fi

    local temp=$(mktemp /run/patch-db-repair.XXXXXX)
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

        if grep -q "hestia-custom-db-repair" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod 755 "$script"
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

    if ! grep -q "hestia-custom-" "$script" 2>/dev/null; then
        cp -f "$script" "${script}.original" 2>/dev/null || true
    elif [ ! -f "${script}.original" ]; then
        cp "$script" "${script}.original" 2>/dev/null || true
    fi

    local temp=$(mktemp /run/patch-interactive.XXXXXX)
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

        if grep -q "hestia-custom-interactive" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod 755 "$script"
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

    local temp=$(mktemp /run/patch-notify.XXXXXX)
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

        if grep -q "hestia-custom-notify-hook" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod 755 "$script"
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

    local temp=$(mktemp /run/patch-global-notify.XXXXXX)
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

        if grep -q "hestia-custom-notify-global-hook" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod 755 "$script"
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

    local temp=$(mktemp /run/patch-retention-hook.XXXXXX)
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

        if grep -q "hestia-custom-retention-hook" "$temp" 2>/dev/null && bash -n "$temp" 2>/dev/null; then
            mv "$temp" "$script" && chmod 755 "$script"
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
                cp -f "$script" "${script}.original" 2>/dev/null || true
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

# Phase 5: Install Restic Snapshot .tar Download endpoint & UI button
patch_restic_web_download_ui() {
    local dl_dir="$HESTIA/web/download/backup/incremental"
    local dl_index="$dl_dir/index.php"
    local tpl="$HESTIA/web/templates/pages/list_backup_incremental.php"
    [ -d "$HESTIA/web" ] || return 0

    mkdir -p "$dl_dir"
    cat > "$dl_index" << 'PHP_EOF'
<?php
use function Hestiacp\quoteshellarg\quoteshellarg;

ob_start();
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Check token
verify_csrf($_GET);

if ($read_only === true || empty($_GET["snapshot"])) {
	header("Location: /list/backup/incremental/");
	exit();
}

$snapshot = quoteshellarg($_GET["snapshot"]);
exec(
	HESTIA_CMD . "v-restic-manager --web-download " . $user . " " . $snapshot,
	$output,
	$return_var,
);

$last_line = !empty($output) ? trim(end($output)) : "";
if ($return_var === 0 && strpos($last_line, "READY|") === 0) {
	$archive = substr($last_line, 6);
	if (
		$_SESSION["userContext"] === "admin" ||
		(!empty($_SESSION["user"]) && strpos($archive, $_SESSION["user"] . ".") === 0)
	) {
		header("Content-type: application/x-tar");
		header('Content-Disposition: attachment; filename="' . $archive . '";');
		header("X-Accel-Redirect: /backup/" . $archive);
		exit();
	}
}

if ($return_var === 0 && strpos($last_line, "QUEUED|") === 0) {
	$_SESSION["error_msg"] = _(
		"Export of Restic snapshot to .tar archive has started in the background. It will appear in your Backups list shortly.",
	);
	header("Location: /list/backup/");
	exit();
}

$_SESSION["error_msg"] = !empty($output)
	? implode("<br>", $output)
	: _("Error: Unable to export Restic snapshot.");
header("Location: /list/backup/incremental/");
exit();
PHP_EOF
    chown root:root "$dl_index" 2>/dev/null || true
    chmod 0644 "$dl_index" 2>/dev/null || true

    if [ -f "$tpl" ] && ! grep -q "hestia-custom-restic-download-btn" "$tpl" 2>/dev/null; then
        [ ! -f "${tpl}.original" ] && cp -f "$tpl" "${tpl}.original" 2>/dev/null || true
        local temp
        temp=$(mktemp /run/patch-restic-ui.XXXXXX) || return 1
        awk '
            /fa-folder-open/ && !inserted {
                print "\t\t\t\t\t\t<!-- hestia-custom-restic-download-btn -->"
                print "\t\t\t\t\t\t<li class=\"units-table-row-action shortcut-d\" data-key-action=\"href\">"
                print "\t\t\t\t\t\t\t<a href=\"/download/backup/incremental/?<?= tohtml(http_build_query([\"snapshot\" => $value[\x27short_id\x27], \"token\" => $_SESSION[\"token\"]])) ?>\" title=\"<?= tohtml( _(\"Download\")) ?>\"><i class=\"fas fa-file-arrow-down icon-lightblue icon-dim\"></i></a>"
                print "\t\t\t\t\t\t</li>"
                inserted = 1
            }
            { print }
        ' "$tpl" > "$temp"
        if grep -q "hestia-custom-restic-download-btn" "$temp" 2>/dev/null; then
            chmod 0644 "$temp"
            mv -f "$temp" "$tpl"
            _log "[$(date)] : Patched list_backup_incremental.php (added Restic .tar Download button)"
        else
            rm -f "$temp"
        fi
    fi
    return 0
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
    patch_restic_web_download_ui || true
    return 0
}
