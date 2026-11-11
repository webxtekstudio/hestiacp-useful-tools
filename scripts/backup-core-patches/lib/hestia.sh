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

    if [ -f "$tpl" ]; then
        [ ! -f "${tpl}.original" ] && cp -f "$tpl" "${tpl}.original" 2>/dev/null || true
        cat > "$tpl" << 'TPL_INC_EOF'
<!-- Begin toolbar -->
<div class="toolbar">
	<div class="toolbar-inner">
		<div class="toolbar-buttons">
			<a class="button button-secondary button-back js-button-back" href="/list/backup/">
				<i class="fas fa-arrow-left icon-blue"></i><?= tohtml( _("Back")) ?>
			</a>
		<?php if ($read_only !== true) { ?>
			<a href="/schedule/backup/incremental/?<?= tohtml(http_build_query(["token" => $_SESSION["token"]])) ?>" class="button button-secondary js-button-create">
				<i class="fas fa-circle-plus icon-green"></i><?= tohtml( _("Create Snapshot")) ?>
			</a>
			<a href="/list/backup/exclusions/" class="button button-secondary">
				<i class="fas fa-folder-minus icon-orange"></i><?= tohtml( _("Backup Exclusions")) ?>
			</a>
		<?php } ?>
		</div>
		<div class="toolbar-right">
			<div class="toolbar-sorting">
				<button class="toolbar-sorting-toggle js-toggle-sorting-menu" type="button" title="<?= tohtml( _("Sort items")) ?>">
					<?= tohtml( _("Sort by")) ?>:
					<span class="u-text-bold">
						<?php if ($_SESSION['userSortOrder'] === 'name') { $label = _('Name'); } else { $label = _('Date'); } ?>
						<?= tohtml($label) ?> <i class="fas fa-arrow-down-a-z"></i>
					</span>
				</button>
				<ul class="toolbar-sorting-menu js-sorting-menu u-hidden">
					<li data-entity="sort-date" data-sort-as-int="1">
						<span class="name <?php if ($_SESSION['userSortOrder'] === 'date') { echo 'active'; } ?>"><?= tohtml( _("Date")) ?> <i class="fas fa-arrow-down-a-z"></i></span><span class="up"><i class="fas fa-arrow-up-a-z"></i></span>
					</li>
					<li data-entity="sort-name">
						<span class="name <?php if ($_SESSION['userSortOrder'] === 'name') { echo 'active'; } ?>"><?= tohtml( _("Name")) ?> <i class="fas fa-arrow-down-a-z"></i></span><span class="up"><i class="fas fa-arrow-up-a-z"></i></span>
					</li>
				</ul>
			</div>
			<?php if ($read_only !== true) { ?>
				<form x-data x-bind="BulkEdit" action="/bulk/backup/incremental/" method="post">
					<input type="hidden" name="token" value="<?= tohtml($_SESSION["token"]) ?>">
					<select class="form-select" name="action">
						<option value=""><?= tohtml( _("Apply to selected")) ?></option>
						<option value="delete"><?= tohtml( _("Delete")) ?></option>
					</select>
					<button type="submit" class="toolbar-input-submit" title="<?= tohtml( _("Apply to selected")) ?>">
						<i class="fas fa-arrow-right"></i>
					</button>
				</form>
			<?php } ?>
			<div class="toolbar-search">
				<form action="/list/backup/incremental/" method="get">
					<input type="hidden" name="token" value="<?= tohtml($_SESSION["token"]) ?>">
						<input type="search" class="form-control js-search-input" name="q" value="<?= tohtml($_GET['q'] ?? '') ?>" title="<?= tohtml( _("Search")) ?>">
					<button type="submit" class="toolbar-input-submit" title="<?= tohtml( _("Search")) ?>">
						<i class="fas fa-magnifying-glass"></i>
					</button>
				</form>
			</div>
		</div>
	</div>
</div>
<!-- End toolbar -->

<div class="container">

<h1 class="u-text-center u-hide-desktop u-mt20 u-pr30 u-mb20 u-pl30"><?= tohtml( _("Snapshots")) ?></h1>

<div class="units-table js-units-container">
	<div class="units-table-header">
		<div class="units-table-cell">
			<input type="checkbox" class="js-toggle-all-checkbox" title="<?= tohtml( _("Select all")) ?>" <?= tohtml($display_mode) ?>>
		</div>
		<div class="units-table-cell"><?= tohtml( _("Snapshot")) ?></div>
		<div class="units-table-cell"></div>
		<div class="units-table-cell u-text-center"><?= tohtml( _("Date")) ?></div>
		<div class="units-table-cell u-text-center"><?= tohtml( _("Type")) ?></div>
		<div class="units-table-cell u-text-center"><?= tohtml( _("Hostname")) ?></div>
	</div>
	<!-- Begin user backup list item loop -->
	<?php
		$i = 0;
		foreach ($data as $key => $value) {
			$i++;
	?>
		<div class="units-table-row js-unit"
			data-sort-date="<?= tohtml(strtotime($value['time'])) ?>"
			data-sort-name="<?= tohtml($value['short_id']) ?>">
			<div class="units-table-cell">
				<div>
					<input id="check<?= tohtml($i) ?>" class="js-unit-checkbox" type="checkbox" title="<?= tohtml( _("Select")) ?>" name="backup[]" value="<?= tohtml($value['short_id']) ?>" <?= tohtml($display_mode) ?>>					<span class="u-hide-desktop"><label for="check<?= tohtml($i) ?>" class="u-hide-desktop"><?= tohtml( _("Select")) ?></label></span>
				</div>
			</div>
			<div class="units-table-cell units-table-heading-cell u-text-bold">
				<b>
					<?php if ($read_only === true) { ?>
							<span class="u-hide-desktop"><?= tohtml( _("Snapshot")) ?>:</span>
							<?= tohtml($value['short_id']) ?>
					<?php } else { ?>
						<span class="u-hide-desktop"><?= tohtml( _("Snapshot")) ?>:</span>
						<a href="/list/backup/incremental/?<?= tohtml(http_build_query(["snapshot" => $value['short_id'], "token" => $_SESSION["token"]])) ?>" title="<?= tohtml( _("Restore")) ?>"><?= tohtml($value['short_id']) ?></a>
					<?php } ?>
				</b>
			</div>
			<div class="units-table-cell">
				<?php if (!$read_only) { ?>
					<ul class="units-table-row-actions">
						<li class="units-table-row-action u-mr10 shortcut-b" data-key-action="href">
							<a
								class="units-table-row-action-link"
								href="/list/backup/incremental/?<?= tohtml(http_build_query(["snapshot" => $value['short_id'], "browse" => 'yes', "token" => $_SESSION["token"]])) ?>"
								title="<?= tohtml( _("Browse")) ?>"
							>
								<i class="fas fa-folder-open icon-lightblue"></i>
								<span class="u-hide-desktop"><?= tohtml( _("Browse")) ?></span>
							</a>
						</li>
						<li class="units-table-row-action u-mr10 shortcut-d" data-key-action="href">
							<a
								class="units-table-row-action-link"
								href="/download/backup/incremental/?<?= tohtml(http_build_query(["snapshot" => $value['short_id'], "token" => $_SESSION["token"]])) ?>"
								title="<?= tohtml( _("Download")) ?>"
							>
								<i class="fas fa-file-arrow-down icon-lightblue"></i>
								<span class="u-hide-desktop"><?= tohtml( _("Download")) ?></span>
							</a>
						</li>
						<li class="units-table-row-action shortcut-enter" data-key-action="href">
							<a
								class="units-table-row-action-link data-controls"
								href="/list/backup/incremental/?<?= tohtml(http_build_query(["snapshot" => $value['short_id'], "token" => $_SESSION["token"]])) ?>"
								title="<?= tohtml( _("Restore")) ?>"
							>
								<i class="fas fa-arrow-rotate-left icon-green"></i>
								<span class="u-hide-desktop"><?= tohtml( _("Restore")) ?></span>
							</a>
						</li>
					</ul>
				<?php } ?>
			</div>
			<div class="units-table-cell">
				<span class="u-hide-desktop u-text-bold"><?= tohtml( _("Date")) ?>:</span>
				<span class="u-text-bold">
					<?= tohtml(convert_datetime($value['time'])) ?>
				</span>
			</div>
			<div class="units-table-cell">
				<span class="u-hide-desktop u-text-bold"><?= tohtml( _("Type")) ?>:</span>
				<span class="u-text-bold">
					Restic
				</span>
			</div>
				<div class="units-table-cell">
					<span class="u-hide-desktop u-text-bold"><?= tohtml( _("Hostname")) ?>:</span>
					<span class="u-text-bold">
						<?= tohtml($value['hostname']) ?>
					</span>
				</div>
		</div>
	<?php
	}
	 ?>
</div>

<footer class="app-footer">
	<div class="container app-footer-inner">
		<p>
			<?php printf(ngettext("%d snapshot", "%d snapshots", $i), $i); ?>
		</p>
	</div>
</footer>
TPL_INC_EOF
        chmod 0644 "$tpl"
        _log "[$(date)] : Patched list_backup_incremental.php (Browse -> Download -> Restore aligned)"
    fi

    # Sorting & in-page search on list_backup.php
    local tpl_bk="$HESTIA/web/templates/pages/list_backup.php"
    if [ -f "$tpl_bk" ] && ! grep -q "toolbar-sorting" "$tpl_bk" 2>/dev/null; then
        [ ! -f "${tpl_bk}.original" ] && cp -f "$tpl_bk" "${tpl_bk}.original" 2>/dev/null || true
        local temp_bk
        temp_bk=$(mktemp /run/patch-bk-sort.XXXXXX) || return 1
        awk '
            /<div class="toolbar-right">/ {
                print
                print "\t\t\t<div class=\"toolbar-sorting\">"
                print "\t\t\t\t<button class=\"toolbar-sorting-toggle js-toggle-sorting-menu\" type=\"button\" title=\"<?= tohtml( _(\"Sort items\")) ?>\">"
                print "\t\t\t\t\t<?= tohtml( _(\"Sort by\")) ?>:"
                print "\t\t\t\t\t<span class=\"u-text-bold\">"
                print "\t\t\t\t\t\t<?php if ($_SESSION[\x27userSortOrder\x27] === \x27name\x27) { $label = _(\x27Name\x27); } else { $label = _(\x27Date\x27); } ?>"
                print "\t\t\t\t\t\t<?= tohtml($label) ?> <i class=\"fas fa-arrow-down-a-z\"></i>"
                print "\t\t\t\t\t</span>"
                print "\t\t\t\t</button>"
                print "\t\t\t\t<ul class=\"toolbar-sorting-menu js-sorting-menu u-hidden\">"
                print "\t\t\t\t\t<li data-entity=\"sort-date\" data-sort-as-int=\"1\">"
                print "\t\t\t\t\t\t<span class=\"name <?php if ($_SESSION[\x27userSortOrder\x27] === \x27date\x27) { echo \x27active\x27; } ?>\"><?= tohtml( _(\"Date\")) ?> <i class=\"fas fa-arrow-down-a-z\"></i></span><span class=\"up\"><i class=\"fas fa-arrow-up-a-z\"></i></span>"
                print "\t\t\t\t\t</li>"
                print "\t\t\t\t\t<li data-entity=\"sort-disk\" data-sort-as-int=\"1\">"
                print "\t\t\t\t\t\t<span class=\"name\"><?= tohtml( _(\"Size\")) ?> <i class=\"fas fa-arrow-down-a-z\"></i></span><span class=\"up\"><i class=\"fas fa-arrow-up-a-z\"></i></span>"
                print "\t\t\t\t\t</li>"
                print "\t\t\t\t\t<li data-entity=\"sort-name\">"
                print "\t\t\t\t\t\t<span class=\"name <?php if ($_SESSION[\x27userSortOrder\x27] === \x27name\x27) { echo \x27active\x27; } ?>\"><?= tohtml( _(\"Name\")) ?> <i class=\"fas fa-arrow-down-a-z\"></i></span><span class=\"up\"><i class=\"fas fa-arrow-up-a-z\"></i></span>"
                print "\t\t\t\t\t</li>"
                print "\t\t\t\t</ul>"
                print "\t\t\t</div>"
                next
            }
            /<form action="\/search\/" method="get">/ {
                sub(/\/search\//, "/list/backup/")
                print
                next
            }
            /name="q" value="<\?= tohtml\(\$_POST\[\x27q\x27\] \?\? \x27\x27\) \?>"/ {
                sub(/\$_POST\[\x27q\x27\]/, "$_GET[\x27q\x27] ?? $_POST[\x27q\x27]")
                print
                next
            }
            /<div class="units-table-row js-unit">/ {
                print "\t\t\t<div class=\"units-table-row js-unit\""
                print "\t\t\t\tdata-sort-date=\"<?= tohtml(strtotime($data[$key][\x27DATE\x27] . \x27 \x27 . $data[$key][\x27TIME\x27])) ?>\""
                print "\t\t\t\tdata-sort-name=\"<?= tohtml($key) ?>\""
                print "\t\t\t\tdata-sort-disk=\"<?= tohtml($data[$key][\x27SIZE\x27]) ?>\">"
                next
            }
            { print }
        ' "$tpl_bk" > "$temp_bk"
        if grep -q "toolbar-sorting" "$temp_bk" 2>/dev/null; then
            chmod 0644 "$temp_bk"
            mv -f "$temp_bk" "$tpl_bk"
            _log "[$(date)] : Patched list_backup.php (added sorting and in-page search)"
        else
            rm -f "$temp_bk"
        fi
    fi

    # Sorting & in-page search on list_files_incremental.php
    local tpl_files="$HESTIA/web/templates/pages/list_files_incremental.php"
    if [ -f "$tpl_files" ] && ! grep -q "toolbar-sorting" "$tpl_files" 2>/dev/null; then
        [ ! -f "${tpl_files}.original" ] && cp -f "$tpl_files" "${tpl_files}.original" 2>/dev/null || true
        local temp_fl
        temp_fl=$(mktemp /run/patch-fl-sort.XXXXXX) || return 1
        awk '
            /<div class="toolbar-right">/ {
                print
                print "\t\t\t<div class=\"toolbar-sorting\">"
                print "\t\t\t\t<button class=\"toolbar-sorting-toggle js-toggle-sorting-menu\" type=\"button\" title=\"<?= tohtml( _(\"Sort items\")) ?>\">"
                print "\t\t\t\t\t<?= tohtml( _(\"Sort by\")) ?>:"
                print "\t\t\t\t\t<span class=\"u-text-bold\">"
                print "\t\t\t\t\t\t<?= tohtml(_(\"Name\")) ?> <i class=\"fas fa-arrow-down-a-z\"></i>"
                print "\t\t\t\t\t</span>"
                print "\t\t\t\t</button>"
                print "\t\t\t\t<ul class=\"toolbar-sorting-menu js-sorting-menu u-hidden\">"
                print "\t\t\t\t\t<li data-entity=\"sort-date\" data-sort-as-int=\"1\">"
                print "\t\t\t\t\t\t<span class=\"name\"><?= tohtml( _(\"Date\")) ?> <i class=\"fas fa-arrow-down-a-z\"></i></span><span class=\"up\"><i class=\"fas fa-arrow-up-a-z\"></i></span>"
                print "\t\t\t\t\t</li>"
                print "\t\t\t\t\t<li data-entity=\"sort-name\">"
                print "\t\t\t\t\t\t<span class=\"name active\"><?= tohtml( _(\"Name\")) ?> <i class=\"fas fa-arrow-down-a-z\"></i></span><span class=\"up\"><i class=\"fas fa-arrow-up-a-z\"></i></span>"
                print "\t\t\t\t\t</li>"
                print "\t\t\t\t\t<li data-entity=\"sort-type\">"
                print "\t\t\t\t\t\t<span class=\"name\"><?= tohtml( _(\"Type\")) ?> <i class=\"fas fa-arrow-down-a-z\"></i></span><span class=\"up\"><i class=\"fas fa-arrow-up-a-z\"></i></span>"
                print "\t\t\t\t\t</li>"
                print "\t\t\t\t</ul>"
                print "\t\t\t</div>"
                next
            }
            /<form action="\/search\/" method="get">/ {
                print "\t\t\t\t\t<form action=\"/list/backup/incremental/\" method=\"get\">"
                print "\t\t\t\t\t\t<input type=\"hidden\" name=\"snapshot\" value=\"<?= tohtml($_GET[\"snapshot\"]) ?>\">"
                print "\t\t\t\t\t\t<input type=\"hidden\" name=\"browse\" value=\"yes\">"
                print "\t\t\t\t\t\t<input type=\"hidden\" name=\"folder\" value=\"<?= tohtml($_GET[\"folder\"]) ?>\">"
                next
            }
            /name="q" value="<\?= tohtml\(\$_POST\[\x27q\x27\] \?\? \x27\x27\) \?>"/ {
                sub(/\$_POST\[\x27q\x27\]/, "$_GET[\x27q\x27] ?? $_POST[\x27q\x27]")
                print
                next
            }
            /<div class="units-table-row js-unit">/ {
                unit_cnt++
                if (unit_cnt == 1) {
                    print "\t\t\t\t\t<div class=\"units-table-row\">"
                } else {
                    print "\t\t\t\t\t<div class=\"units-table-row js-unit\""
                    print "\t\t\t\t\t\tdata-sort-date=\"<?= tohtml(strtotime($file[\x27ctime\x27])) ?>\""
                    print "\t\t\t\t\t\tdata-sort-name=\"<?= tohtml($file[\x27name\x27]) ?>\""
                    print "\t\t\t\t\t\tdata-sort-type=\"<?= tohtml($file[\x27type\x27]) ?>\">"
                }
                next
            }
            { print }
        ' "$tpl_files" > "$temp_fl"
        if grep -q "toolbar-sorting" "$temp_fl" 2>/dev/null; then
            chmod 0644 "$temp_fl"
            mv -f "$temp_fl" "$tpl_files"
            _log "[$(date)] : Patched list_files_incremental.php (added sorting and in-page search)"
        else
            rm -f "$temp_fl"
        fi
    fi

    # Search filtering in web/list/backup/index.php
    local bk_ctrl="$HESTIA/web/list/backup/index.php"
    if [ -f "$bk_ctrl" ] && ! grep -q 'ARRAY_FILTER_USE_BOTH' "$bk_ctrl" 2>/dev/null; then
        [ ! -f "${bk_ctrl}.original" ] && cp -f "$bk_ctrl" "${bk_ctrl}.original" 2>/dev/null || true
        sed -i '/unset(\$output);/i \
\tif (!empty($_GET["q"])) {\
\t\t$q = $_GET["q"];\
\t\t$data = array_filter(\
\t\t\t$data,\
\t\t\tfunction ($value, $key) use ($q) {\
\t\t\t\t$haystack = implode(" ", [\
\t\t\t\t\t$key,\
\t\t\t\t\t$value["DATE"] ?? "",\
\t\t\t\t\t$value["TIME"] ?? "",\
\t\t\t\t\t$value["TYPE"] ?? "",\
\t\t\t\t\t$value["WEB"] ?? "",\
\t\t\t\t\t$value["DNS"] ?? "",\
\t\t\t\t\t$value["MAIL"] ?? "",\
\t\t\t\t\t$value["DB"] ?? "",\
\t\t\t\t]);\
\t\t\t\treturn stripos($haystack, $q) !== false;\
\t\t\t},\
\t\t\tARRAY_FILTER_USE_BOTH,\
\t\t);\
\t}' "$bk_ctrl"
    fi

    # Search filtering & fixes in web/list/backup/incremental/index.php
    local inc_ctrl="$HESTIA/web/list/backup/incremental/index.php"
    if [ -f "$inc_ctrl" ] && ! grep -q 'U_BACKUPS_INCREMENTAL' "$inc_ctrl" 2>/dev/null; then
        [ ! -f "${inc_ctrl}.original" ] && cp -f "$inc_ctrl" "${inc_ctrl}.original" 2>/dev/null || true
        cat > "$inc_ctrl" << 'INC_CTRL_EOF'
<?php
use function Hestiacp\quoteshellarg\quoteshellarg;
$TAB = "BACKUP";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

function getTransByType($type) {
	switch ($type) {
		case "dir":
			return _("Directory");
		case "file":
			return _("File");
		case "symlink":
			return _("Symlink");
		default:
			return _("Unknown");
	}
}

// Data & Render page
if (empty($_GET["snapshot"])) {
	exec(HESTIA_CMD . "v-list-user-backups-restic $user json", $output, $return_var);
	$data = json_decode(implode("", $output), true);
	if (is_array($data)) {
		$panel[$user]["U_BACKUPS_INCREMENTAL"] = count($data);
		if ($_SESSION["userSortOrder"] == "name") {
			usort($data, function ($a, $b) {
				return strcmp($a["short_id"] ?? "", $b["short_id"] ?? "");
			});
		} else {
			$data = array_reverse($data);
		}
		if (!empty($_GET["q"])) {
			$q = $_GET["q"];
			$data = array_values(
				array_filter($data, function ($value) use ($q) {
					$haystack = implode(" ", [
						$value["short_id"] ?? "",
						$value["time"] ?? "",
						convert_datetime($value["time"] ?? ""),
						$value["hostname"] ?? "",
						"Restic",
					]);
					return stripos($haystack, $q) !== false;
				}),
			);
		}
	} else {
		$data = [];
	}

	render_page($user, $TAB, "list_backup_incremental");
} else {
	if (empty($_GET["browse"])) {
		$snapshot = quoteshellarg($_GET["snapshot"]);
		exec(HESTIA_CMD . "v-list-user-backup-restic $user $snapshot json", $output, $return_var);
		$data = json_decode(implode("", $output), true);
		render_page($user, $TAB, "list_backup_detail_incremental");
	} else {
		if (empty($_GET["folder"])) {
			$_GET["folder"] = "/home/" . $user_plain;
		}
		$folder = quoteshellarg($_GET["folder"]);
		$snapshot = quoteshellarg($_GET["snapshot"]);
		exec(HESTIA_CMD . "v-list-user-files-restic $user $snapshot $folder", $output, $return_var);
		$info = json_decode($output[0], true);
		unset($output[0]);
		$files = [];
		$q = $_GET["q"] ?? "";
		foreach ($output as $key => $value) {
			$item = json_decode($value, true);
			if ($q !== "" && $key !== 1 && ($item["path"] ?? "") !== $_GET["folder"]) {
				$haystack = implode(" ", [
					$item["name"] ?? "",
					$item["type"] ?? "",
					$item["ctime"] ?? "",
				]);
				if (stripos($haystack, $q) === false) {
					continue;
				}
			}
			$files[] = $item;
		}
		render_page($user, $TAB, "list_files_incremental");
	}
}
INC_CTRL_EOF
        chmod 0644 "$inc_ctrl" 2>/dev/null || true
        _log "[$(date)] : Patched web/list/backup/incremental/index.php (search filtering + empty array guard)"
    fi

    # Top menu 2nd line ('Snapshots: X') in panel.php + U_BACKUPS_INCREMENTAL in v-list-user & syshealth.sh
    local panel_tpl="$HESTIA/web/templates/includes/panel.php"
    if [ -f "$panel_tpl" ] && ! grep -q "U_BACKUPS_INCREMENTAL" "$panel_tpl" 2>/dev/null; then
        [ ! -f "${panel_tpl}.original" ] && cp -f "$panel_tpl" "${panel_tpl}.original" 2>/dev/null || true
        local temp_pnl
        temp_pnl=$(mktemp /run/patch-panel.XXXXXX) || return 1
        awk '
            /href="\/list\/backup\/"/ {
                sub(/\$panel\[\$user\]\["BACKUPS"\] \?>"/, "$panel[$user][\"BACKUPS\"] ?><?php if ($panel[$user][\"BACKUPS_INCREMENTAL\"] == \"yes\") { ?>\\&#13;<?= _(\"Snapshots\") ?>: <?= $panel[$user][\"U_BACKUPS_INCREMENTAL\"] ?? 0 ?><?php } ?>\"")
                print
                in_backup_tab = 1
                next
            }
            in_backup_tab && /<\/ul>/ {
                print "\t\t\t\t\t\t\t\t\t<?php if ($panel[$user][\"BACKUPS_INCREMENTAL\"] == \"yes\") { ?>"
                print "\t\t\t\t\t\t\t\t\t\t<li>"
                print "\t\t\t\t\t\t\t\t\t\t\t<?= _(\"Snapshots\") ?>: <?= $panel[$user][\"U_BACKUPS_INCREMENTAL\"] ?? 0 ?>"
                print "\t\t\t\t\t\t\t\t\t\t</li>"
                print "\t\t\t\t\t\t\t\t\t<?php } ?>"
                print
                in_backup_tab = 0
                next
            }
            { print }
        ' "$panel_tpl" > "$temp_pnl"
        if grep -q "U_BACKUPS_INCREMENTAL" "$temp_pnl" 2>/dev/null; then
            chmod 0644 "$temp_pnl"
            mv -f "$temp_pnl" "$panel_tpl"
            _log "[$(date)] : Patched panel.php (added Snapshots counter under BACKUP)"
        else
            rm -f "$temp_pnl"
        fi
    fi

    if [ -f "$HESTIA/bin/v-list-user" ] && ! grep -q "U_BACKUPS_INCREMENTAL" "$HESTIA/bin/v-list-user" 2>/dev/null; then
        sed -i '/"U_BACKUPS":/a \        "U_BACKUPS_INCREMENTAL": "\x27${U_BACKUPS_INCREMENTAL:-0}\x27",' "$HESTIA/bin/v-list-user"
    fi
    if [ -f "$HESTIA/func/syshealth.sh" ] && ! grep -q "U_BACKUPS_INCREMENTAL" "$HESTIA/func/syshealth.sh" 2>/dev/null; then
        sed -i 's/U_BACKUPS LANGUAGE/U_BACKUPS U_BACKUPS_INCREMENTAL BACKUPS_INCREMENTAL LANGUAGE/' "$HESTIA/func/syshealth.sh"
    fi
    if [ -f "$HESTIA/bin/v-add-user" ] && ! grep -q "U_BACKUPS_INCREMENTAL=" "$HESTIA/bin/v-add-user" 2>/dev/null; then
        sed -i "/^U_BACKUPS='0'/a U_BACKUPS_INCREMENTAL='0'" "$HESTIA/bin/v-add-user"
    fi
    if [ -f "$HESTIA/bin/v-change-user-package" ] && ! grep -q "U_BACKUPS_INCREMENTAL=" "$HESTIA/bin/v-change-user-package" 2>/dev/null; then
        sed -i '/^U_BACKUPS=/a U_BACKUPS_INCREMENTAL=\x27${U_BACKUPS_INCREMENTAL:-0}\x27' "$HESTIA/bin/v-change-user-package"
    fi
    patch_restic_snapshot_counter || return 1
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

# Update only the known JSON-list function; preserve the rest of the upstream CLI.
patch_restic_snapshot_counter() {
    local cli="$HESTIA/bin/v-list-user-backups-restic"
    [ -f "$cli" ] || return 0
    local work patched
    work=$(umask 077 && mktemp -d /run/hestia-restic-cli.XXXXXX) || return 1
    patched=$(umask 077 && mktemp "${cli}.patch.XXXXXX") || { rm -rf -- "$work"; return 1; }
    cat > "$work/function" << 'COUNTER_EOF'
function json_list() {
	# hestia-restic-counter-v2: preserve errors and validate JSON before updating
	local snapshots_json u_snapshots
	snapshots_json=$(restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" --json snapshots) || return $?
	u_snapshots=$(printf '%s' "$snapshots_json" | jq -er 'if type == "array" and all(.[]; type == "object" and (.id | type == "string")) then length else error("Invalid Restic snapshot list") end') || return $?
	if grep -q "^U_BACKUPS_INCREMENTAL=" "$USER_DATA/user.conf"; then
		update_user_value "$user" '$U_BACKUPS_INCREMENTAL' "$u_snapshots"
	else
		sed -i "s/^U_BACKUPS=/U_BACKUPS_INCREMENTAL='$u_snapshots'\nU_BACKUPS=/" "$USER_DATA/user.conf"
	fi
	printf '%s\n' "$snapshots_json"
}
COUNTER_EOF
    if awk -v replacement="$work/function" '
        /^function json_list\(\) \{/ {
            while ((getline line < replacement) > 0) print line
            close(replacement)
            replacing = 1
            found = 1
            next
        }
        replacing && /^}/ { replacing = 0; next }
        !replacing { print }
        END { if (!found) exit 1 }
    ' "$cli" > "$patched" && bash -n "$patched"; then
        if ! cmp -s "$cli" "$patched"; then
            chmod 0755 "$patched"
            mv -f -- "$patched" "$cli"
            _log "Patched Restic JSON counter error handling"
        fi
    else
        _log "[WARN] Unsupported Restic JSON-list function; left CLI unchanged"
        rm -f -- "$patched"
        rm -rf -- "$work"
        return 1
    fi
    rm -f -- "$patched"
    rm -rf -- "$work"
}
