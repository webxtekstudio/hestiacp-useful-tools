#!/bin/bash
# lib/hestia.sh - HestiaCP Patches
#
# Patches:
#   backup.sh → b2_backup/b2_download/b2_delete use organized YYYY/MM paths
#   v-delete-user-backup → follows symlinks
#
# All patches are idempotent (safe to re-run).

export HESTIA="${HESTIA:-/usr/local/hestia}"
_BCP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# Phase 5: Install Restic Snapshot .tar Download & Delete endpoints, instant search JS, and UI buttons
patch_restic_web_download_ui() {
    local dl_dir="$HESTIA/web/download/backup/incremental"
    local dl_index="$dl_dir/index.php"
    local del_dir="$HESTIA/web/delete/backup/incremental"
    local del_index="$del_dir/index.php"
    local tpl="$HESTIA/web/templates/pages/list_backup_incremental.php"
    local tpl_src="$_BCP_ROOT/templates/list_backup_incremental.php"
    local js_src="$_BCP_ROOT/js/backup-instant-search.js"
    local js_dst_dir="$HESTIA/web/js/custom_scripts"
    local js_dst="$js_dst_dir/backup-instant-search.js"
    [ -d "$HESTIA/web" ] || return 0

    mkdir -p "$dl_dir" "$del_dir"
    chmod 0755 "$dl_dir" "$del_dir" 2>/dev/null || true
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
    chown root:root "$dl_dir" "$dl_index" 2>/dev/null || true
    chmod 0644 "$dl_index" 2>/dev/null || true

    cat > "$del_index" << 'DEL_PHP_EOF'
<?php
use function Hestiacp\quoteshellarg\quoteshellarg;

ob_start();
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

if ($_SESSION["userContext"] === "admin" && !empty($_GET["user"])) {
	$user = quoteshellarg($_GET["user"]);
}

// Check token
verify_csrf($_GET);

if ($read_only === true) {
	header("Location: /list/backup/incremental/");
	exit();
}

if (!empty($_GET["snapshot"])) {
	$v_snapshot = quoteshellarg($_GET["snapshot"]);
	exec(
		HESTIA_CMD . "v-delete-user-backup-restic " . $user . " " . $v_snapshot,
		$output,
		$return_var,
	);
	check_return_code($return_var, $output);
	unset($output);
}

header("Location: /list/backup/incremental/");
exit();
DEL_PHP_EOF
    chown root:root "$del_dir" "$del_index" 2>/dev/null || true
    chmod 0644 "$del_index" 2>/dev/null || true

    if [ -f "$js_src" ]; then
        mkdir -p "$js_dst_dir"
        chmod 0755 "$js_dst_dir" 2>/dev/null || true
        if ! cmp -s "$js_src" "$js_dst" 2>/dev/null; then
            if [ "${EUID:-$(id -u)}" -eq 0 ]; then
                install -o root -g root -m 0644 "$js_src" "$js_dst"
            else
                cp -f "$js_src" "$js_dst" && chmod 0644 "$js_dst"
            fi
            _log "[$(date)] : Installed custom script backup-instant-search.js (instant search & pagination)"
        fi
    fi

    if [ -f "$tpl" ] && [ -f "$tpl_src" ]; then
        if ! grep -q '/download/backup/incremental/' "$tpl" 2>/dev/null || [ ! -f "${tpl}.original" ]; then
            cp -f "$tpl" "${tpl}.original" 2>/dev/null || true
        fi
        if ! cmp -s "$tpl_src" "$tpl" 2>/dev/null; then
            if [ "${EUID:-$(id -u)}" -eq 0 ]; then
                install -o root -g root -m 0644 "$tpl_src" "$tpl"
            else
                cp -f "$tpl_src" "$tpl" && chmod 0644 "$tpl"
            fi
            _log "[$(date)] : Patched list_backup_incremental.php (Browse -> Download -> Restore -> Delete aligned)"
        fi
    fi

    # Sorting & in-page search on list_backup.php
    local tpl_bk="$HESTIA/web/templates/pages/list_backup.php"
    if [ -f "$tpl_bk" ] && ! grep -q "toolbar-sorting" "$tpl_bk" 2>/dev/null; then
        cp -f "$tpl_bk" "${tpl_bk}.original" 2>/dev/null || true
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
        cp -f "$tpl_files" "${tpl_files}.original" 2>/dev/null || true
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
        cp -f "$bk_ctrl" "${bk_ctrl}.original" 2>/dev/null || true
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

    # Search filtering, cache refresh toggle & back URL in web/list/backup/incremental/index.php
    local inc_ctrl="$HESTIA/web/list/backup/incremental/index.php"
    if [ -f "$inc_ctrl" ] && ! grep -q 'hestia-restic-inc-ctrl-v2' "$inc_ctrl" 2>/dev/null; then
        if ! grep -qE 'U_BACKUPS_INCREMENTAL|hestia-restic-inc-ctrl-v' "$inc_ctrl" 2>/dev/null || [ ! -f "${inc_ctrl}.original" ]; then
            cp -f "$inc_ctrl" "${inc_ctrl}.original" 2>/dev/null || true
        fi
        cat > "$inc_ctrl" << 'INC_CTRL_EOF'
<?php
// hestia-restic-inc-ctrl-v2
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
	$refresh_arg = !empty($_GET["refresh"]) ? " no-cache" : "";
	exec(HESTIA_CMD . "v-list-user-backups-restic $user json" . $refresh_arg, $output, $return_var);
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

// Back uri
$_SESSION["back"] = $_SERVER["REQUEST_URI"];
INC_CTRL_EOF
        chmod 0644 "$inc_ctrl" 2>/dev/null || true
        _log "[$(date)] : Patched web/list/backup/incremental/index.php (search filtering + refresh bypass + empty array guard)"
    fi

    # Top menu 2nd line ('Snapshots: X') in panel.php + U_BACKUPS_INCREMENTAL in v-list-user & syshealth.sh
    local panel_tpl="$HESTIA/web/templates/includes/panel.php"
    if [ -f "$panel_tpl" ] && ! grep -q "U_BACKUPS_INCREMENTAL" "$panel_tpl" 2>/dev/null; then
        cp -f "$panel_tpl" "${panel_tpl}.original" 2>/dev/null || true
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
    patch_restic_read_and_delete || true
    patch_restic_staging_perms || true
    patch_restic_bulk_cron_restore || true
    patch_restic_backup_exclusions || true
    return 0
}

# Update only the known JSON-list function (plus --no-lock / no-cache pass-through); preserve the rest of the upstream CLI.
patch_restic_snapshot_counter() {
    local cli="$HESTIA/bin/v-list-user-backups-restic"
    [ -f "$cli" ] || return 0
    grep -q "hestia-restic-counter-v3" "$cli" 2>/dev/null && return 0

    if grep -q "hestia-restic-counter-v" "$cli" 2>/dev/null; then
        [ -f "${cli}.original" ] && cp -f "${cli}.original" "$cli" 2>/dev/null || true
    else
        cp -f "$cli" "${cli}.original" 2>/dev/null || true
    fi

    local patch_tmp_root="/run"
    [ -d "$patch_tmp_root" ] && [ -w "$patch_tmp_root" ] || patch_tmp_root="${TMPDIR:-/tmp}"

    local work patched
    work=$(umask 077 && mktemp -d "$patch_tmp_root/hestia-restic-cli.XXXXXX") || return 1
    patched=$(umask 077 && mktemp "${cli}.patch.XXXXXX") || { rm -rf -- "$work"; return 1; }
    cat > "$work/function" << 'COUNTER_EOF'
function json_list() {
	# hestia-restic-counter-v3: --no-lock read-only listing, short-TTL root-owned JSON cache, and counter validation
	local cache_opt="${1:-}"
	local cache_dir="${RESTIC_SNAPSHOT_CACHE_DIR:-/run/hestia-restic-cache}"
	local cache_ttl="${RESTIC_SNAPSHOT_CACHE_TTL:-120}"
	local cache_file="" snapshots_json="" u_snapshots="" cur_snapshots="" now_ts=0 file_ts=0 tmp_cache=""

	if [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
		cache_file="$cache_dir/${user}.json"
	fi

	if [ -n "$cache_file" ] &&
		[ "${RESTIC_NO_CACHE:-0}" != "1" ] &&
		[ "$cache_opt" != "no-cache" ] && [ "$cache_opt" != "--no-cache" ] &&
		[[ "$cache_ttl" =~ ^[0-9]+$ ]] && [ "$cache_ttl" -gt 0 ] &&
		[ -d "$cache_dir" ] && [ ! -L "$cache_dir" ] && [ -O "$cache_dir" ] &&
		[ -f "$cache_file" ] && [ ! -L "$cache_file" ] && [ -O "$cache_file" ] &&
		! [ "$HESTIA/conf/restic.conf" -nt "$cache_file" ] &&
		! [ "$USER_DATA/restic.conf" -nt "$cache_file" ]; then
		now_ts=$(date +%s 2>/dev/null || echo 0)
		file_ts=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
		if [ "$((now_ts - file_ts))" -ge 0 ] && [ "$((now_ts - file_ts))" -lt "$cache_ttl" ]; then
			snapshots_json=$(cat "$cache_file" 2>/dev/null || true)
			if u_snapshots=$(printf '%s' "$snapshots_json" | jq -er 'if type == "array" and all(.[]; type == "object" and (.id | type == "string")) then length else error("Invalid Restic snapshot list") end' 2>/dev/null); then
				if [ -f "$USER_DATA/user.conf" ]; then
					if grep -q "^U_BACKUPS_INCREMENTAL=" "$USER_DATA/user.conf"; then
						cur_snapshots=$(grep "^U_BACKUPS_INCREMENTAL=" "$USER_DATA/user.conf" | head -n1 | cut -d"'" -f2)
						if [ "$cur_snapshots" != "$u_snapshots" ]; then
							update_user_value "$user" '$U_BACKUPS_INCREMENTAL' "$u_snapshots"
						fi
					else
						sed -i "s/^U_BACKUPS=/U_BACKUPS_INCREMENTAL='$u_snapshots'\nU_BACKUPS=/" "$USER_DATA/user.conf"
					fi
				fi
				printf '%s\n' "$snapshots_json"
				return 0
			fi
		fi
	fi

	snapshots_json=$(restic --no-lock --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" --json snapshots) || return $?
	u_snapshots=$(printf '%s' "$snapshots_json" | jq -er 'if type == "array" and all(.[]; type == "object" and (.id | type == "string")) then length else error("Invalid Restic snapshot list") end') || return $?

	if [ -n "$cache_file" ]; then
		if (umask 077 && mkdir -p "$cache_dir") 2>/dev/null && [ -d "$cache_dir" ] && [ ! -L "$cache_dir" ] && [ -O "$cache_dir" ]; then
			chmod 0700 "$cache_dir" 2>/dev/null || true
			tmp_cache=$(umask 077 && mktemp "$cache_dir/.${user}.XXXXXX" 2>/dev/null || true)
			if [ -n "$tmp_cache" ]; then
				if printf '%s\n' "$snapshots_json" > "$tmp_cache"; then
					chmod 0600 "$tmp_cache" 2>/dev/null || true
					mv -f -- "$tmp_cache" "$cache_file" 2>/dev/null || rm -f -- "$tmp_cache"
				else
					rm -f -- "$tmp_cache"
				fi
			fi
		fi
	fi

	if [ -f "$USER_DATA/user.conf" ]; then
		if grep -q "^U_BACKUPS_INCREMENTAL=" "$USER_DATA/user.conf"; then
			update_user_value "$user" '$U_BACKUPS_INCREMENTAL' "$u_snapshots"
		else
			sed -i "s/^U_BACKUPS=/U_BACKUPS_INCREMENTAL='$u_snapshots'\nU_BACKUPS=/" "$USER_DATA/user.conf"
		fi
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
        !replacing {
            if ($0 ~ /restic --repo / && $0 !~ /--no-lock/) {
                sub(/restic --repo/, "restic --no-lock --repo")
            }
            if ($0 ~ /json\) json_list ;;/) {
                sub(/json\) json_list ;;/, "json) json_list \"${3-}\" ;;")
            }
            print
        }
        END { if (!found) exit 1 }
    ' "$cli" > "$patched" && bash -n "$patched"; then
        if ! cmp -s "$cli" "$patched"; then
            chmod 0755 "$patched"
            mv -f -- "$patched" "$cli"
            _log "Patched Restic JSON counter (--no-lock + 120s cache)"
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

# Harden read-only Restic commands (--no-lock + tmpdir cleanup), cache invalidation on backup, and v-delete-user-backup-restic.
patch_restic_read_and_delete() {
    local patch_tmp_root="/run"
    [ -d "$patch_tmp_root" ] && [ -w "$patch_tmp_root" ] || patch_tmp_root="${TMPDIR:-/tmp}"

    # 1. v-list-user-backup-restic (--no-lock + tmpdir cleanup on failure)
    local cli_detail="$HESTIA/bin/v-list-user-backup-restic"
    if [ -f "$cli_detail" ] && ! grep -q "hestia-restic-nolock-v2" "$cli_detail" 2>/dev/null; then
        if grep -q "hestia-restic-nolock-v" "$cli_detail" 2>/dev/null; then
            [ -f "${cli_detail}.original" ] && cp -f "${cli_detail}.original" "$cli_detail" 2>/dev/null || true
        elif ! grep -q "hestia-restic-" "$cli_detail" 2>/dev/null || [ ! -f "${cli_detail}.original" ]; then
            cp -f "$cli_detail" "${cli_detail}.original" 2>/dev/null || true
        fi
        if grep -q '^tmpdir=' "$cli_detail" && grep -q '^rm -fr "\$tmpdir"$' "$cli_detail"; then
            local work_det patched_det
            work_det=$(umask 077 && mktemp -d "$patch_tmp_root/hestia-restic-det.XXXXXX") || return 1
            patched_det=$(umask 077 && mktemp "${cli_detail}.patch.XXXXXX") || { rm -rf -- "$work_det"; return 1; }
            cat > "$work_det/block" << 'DETAIL_EOF'
# hestia-restic-nolock-v2: read-only dump without remote B2 lock and clean up tmpdir on all failure paths
tmpdir=$(mktemp -p "${BACKUP_TEMP:-$BACKUP}" -d)
if ! restic --no-lock --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" --json dump "$snapshot" "/home/$user/backup/backup.conf" > "$tmpdir/backup.conf"; then
	rm -rf -- "$tmpdir"
	check_result "$E_NOTEXIST" "Unable to read snapshot metadata"
fi

parse_untrusted_conf_file "$tmpdir/backup.conf" \
	BACKUP TYPE SIZE WEB DNS MAIL DB CRON UDIR RUNTIME TIME DATE || {
	_parse_rc=$?
	rm -rf -- "$tmpdir"
	exit "$_parse_rc"
}

rm -rf -- "$tmpdir"
DETAIL_EOF
            if awk -v repl="$work_det/block" '
                /^tmpdir=\$\(mktemp/ {
                    while ((getline line < repl) > 0) print line
                    close(repl)
                    in_skip = 1
                    found = 1
                    next
                }
                in_skip && /^rm -fr "\$tmpdir"$/ { in_skip = 0; next }
                !in_skip { print }
                END { if (!found) exit 1 }
            ' "$cli_detail" > "$patched_det" && grep -q "hestia-restic-nolock-v2" "$patched_det" && bash -n "$patched_det"; then
                chmod 0755 "$patched_det"
                mv -f -- "$patched_det" "$cli_detail"
                _log "[$(date)] : Patched v-list-user-backup-restic (--no-lock + tmpdir cleanup v2)"
            else
                rm -f -- "$patched_det"
            fi
            rm -rf -- "$work_det"
        fi
    fi

    # 2. v-list-user-files-restic (--no-lock)
    local cli_files="$HESTIA/bin/v-list-user-files-restic"
    if [ -f "$cli_files" ] && ! grep -q "hestia-restic-nolock-v1" "$cli_files" 2>/dev/null; then
        if ! grep -q "hestia-restic-" "$cli_files" 2>/dev/null || [ ! -f "${cli_files}.original" ]; then
            cp -f "$cli_files" "${cli_files}.original" 2>/dev/null || true
        fi
        if grep -q '^restic --repo .* --json ls ' "$cli_files"; then
            local patched_fl
            patched_fl=$(umask 077 && mktemp "${cli_files}.patch.XXXXXX") || return 1
            awk '
                /^restic --repo .* --json ls / {
                    print "# hestia-restic-nolock-v1: read-only file listing without remote B2 lock"
                    sub(/^restic --repo/, "restic --no-lock --repo")
                    print
                    found = 1
                    next
                }
                { print }
                END { if (!found) exit 1 }
            ' "$cli_files" > "$patched_fl" && grep -q "hestia-restic-nolock-v1" "$patched_fl" && bash -n "$patched_fl" && {
                chmod 0755 "$patched_fl"
                mv -f -- "$patched_fl" "$cli_files"
                _log "[$(date)] : Patched v-list-user-files-restic (--no-lock)"
            } || rm -f -- "$patched_fl"
        fi
    fi

    # 3. v-backup-user-restic (--no-lock pre-check + cache invalidation/refresh after backup)
    local cli_bkp="$HESTIA/bin/v-backup-user-restic"
    if [ -f "$cli_bkp" ] && ! grep -q "hestia-restic-cache-inv-v1" "$cli_bkp" 2>/dev/null; then
        if ! grep -q "hestia-restic-" "$cli_bkp" 2>/dev/null || [ ! -f "${cli_bkp}.original" ]; then
            cp -f "$cli_bkp" "${cli_bkp}.original" 2>/dev/null || true
        fi
        if grep -q 'log_event "\$OK" "\$ARGUMENTS"' "$cli_bkp"; then
            local patched_bkp
            patched_bkp=$(umask 077 && mktemp "${cli_bkp}.patch.XXXXXX") || return 1
            awk '
                /restic --repo "\$\{REPO%\/\}\/\$user" --password-file \$USER_DATA\/restic\.conf --json snapshots/ && $0 !~ /--no-lock/ {
                    sub(/restic --repo/, "restic --no-lock --repo")
                }
                /log_event "\$OK" "\$ARGUMENTS"/ {
                    print "# hestia-restic-cache-inv-v1: invalidate and refresh snapshot list cache after creating/pruning snapshots"
                    print "rm -f -- \"${RESTIC_SNAPSHOT_CACHE_DIR:-/run/hestia-restic-cache}/${user}.json\" \"/run/hestia-restic-cache/${user}.json\" 2>/dev/null || true"
                    print "\"$BIN/v-list-user-backups-restic\" \"$user\" json >/dev/null 2>&1 || true"
                    found = 1
                }
                { print }
                END { if (!found) exit 1 }
            ' "$cli_bkp" > "$patched_bkp" && grep -q "hestia-restic-cache-inv-v1" "$patched_bkp" && bash -n "$patched_bkp" && {
                chmod 0755 "$patched_bkp"
                mv -f -- "$patched_bkp" "$cli_bkp"
                _log "[$(date)] : Patched v-backup-user-restic (--no-lock pre-check + cache invalidation)"
            } || rm -f -- "$patched_bkp"
        fi
    fi

    # 4. v-delete-user-backup-restic (validate snapshot, skip redundant dump/tmpdir leak, check forget result, sync cache & counter)
    local cli_del="$HESTIA/bin/v-delete-user-backup-restic"
    if [ -f "$cli_del" ] && ! grep -q "hestia-restic-delete-v1" "$cli_del" 2>/dev/null; then
        if grep -q "hestia-restic-delete-v" "$cli_del" 2>/dev/null; then
            [ -f "${cli_del}.original" ] && cp -f "${cli_del}.original" "$cli_del" 2>/dev/null || true
        else
            cp -f "$cli_del" "${cli_del}.original" 2>/dev/null || true
        fi
        if grep -q '^tmpdir=' "$cli_del" && grep -q 'forget "\$snapshot"$' "$cli_del"; then
            local work_del patched_del
            work_del=$(umask 077 && mktemp -d "$patch_tmp_root/hestia-restic-del.XXXXXX") || return 1
            patched_del=$(umask 077 && mktemp "${cli_del}.patch.XXXXXX") || { rm -rf -- "$work_del"; return 1; }
            cat > "$work_del/block" << 'DEL_EOF'
# hestia-restic-delete-v1: validate snapshot ID, skip redundant dump/tmpdir leak, verify forget result, and sync cache/counter
if [[ ! "$snapshot" =~ ^[a-fA-F0-9]{8,64}$ ]]; then
	check_result "$E_INVALID" "Invalid snapshot ID format"
fi
if [ ! -f "$USER_DATA/restic.conf" ]; then
	check_result "$E_NOTEXIST" "Restic configuration for user $user does not exist"
fi

forget_out=$(restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" forget -- "$snapshot" 2>&1)
forget_rc=$?
if [ "$forget_rc" -ne 0 ]; then
	check_result "$E_CONNECT" "Unable to delete Restic snapshot $snapshot"
fi
if printf '%s\n' "$forget_out" | grep -qi 'no matching ID found'; then
	check_result "$E_NOTEXIST" "Snapshot $snapshot does not exist"
fi

rm -f -- "${RESTIC_SNAPSHOT_CACHE_DIR:-/run/hestia-restic-cache}/${user}.json" "/run/hestia-restic-cache/${user}.json" 2>/dev/null || true
if [ -f "$USER_DATA/user.conf" ] && grep -q "^U_BACKUPS_INCREMENTAL=" "$USER_DATA/user.conf" 2>/dev/null; then
	_cur_inc=$(grep "^U_BACKUPS_INCREMENTAL=" "$USER_DATA/user.conf" | head -n1 | cut -d"'" -f2)
	if [[ "$_cur_inc" =~ ^[0-9]+$ ]] && [ "$_cur_inc" -gt 0 ]; then
		update_user_value "$user" '$U_BACKUPS_INCREMENTAL' "$((_cur_inc - 1))"
	fi
fi
DEL_EOF
            if awk -v repl="$work_del/block" '
                /^tmpdir=\$\(mktemp/ {
                    while ((getline line < repl) > 0) print line
                    close(repl)
                    in_skip = 1
                    found = 1
                    next
                }
                in_skip && /forget "\$snapshot"$/ { in_skip = 0; next }
                !in_skip { print }
                END { if (!found) exit 1 }
            ' "$cli_del" > "$patched_del" && grep -q "hestia-restic-delete-v1" "$patched_del" && bash -n "$patched_del"; then
                chmod 0755 "$patched_del"
                mv -f -- "$patched_del" "$cli_del"
                _log "[$(date)] : Patched v-delete-user-backup-restic (hardened validation, cleanup & cache/counter sync)"
            else
                rm -f -- "$patched_del"
            fi
            rm -rf -- "$work_del"
        fi
    fi
    return 0
}

# Harden Restic staging directory permissions, restic.conf creation permissions, and /backup/*.log modes.
patch_restic_staging_perms() {
    local patch_tmp_root="/run"
    [ -d "$patch_tmp_root" ] && [ -w "$patch_tmp_root" ] || patch_tmp_root="${TMPDIR:-/tmp}"

    # 1. v-backup-user-config (0700 root:root staging dir + no trailing slash unlink + 0660 $BACKUP/$user.log)
    local cli_cfg="$HESTIA/bin/v-backup-user-config"
    if [ -f "$cli_cfg" ] && ! grep -q "hestia-restic-staging-v1" "$cli_cfg" 2>/dev/null; then
        if ! grep -q "hestia-restic-" "$cli_cfg" 2>/dev/null || [ ! -f "${cli_cfg}.original" ]; then
            cp -f "$cli_cfg" "${cli_cfg}.original" 2>/dev/null || true
        fi
        if grep -q '^tmpdir="/home/\$user/backup/"$' "$cli_cfg" && grep -q '^mkdir -p "\$tmpdir"$' "$cli_cfg" && grep -q '^echo "\$backup_str" > \$tmpdir/backup\.conf$' "$cli_cfg"; then
            local work_cfg patched_cfg
            work_cfg=$(umask 077 && mktemp -d "$patch_tmp_root/hestia-restic-cfg.XXXXXX") || return 1
            patched_cfg=$(umask 077 && mktemp "${cli_cfg}.patch.XXXXXX") || { rm -rf -- "$work_cfg"; return 1; }
            cat > "$work_cfg/block" << 'CFG_EOF'
# hestia-restic-staging-v1: unlink without trailing slash and create 0700 root:root staging dir
tmpdir="/home/$user/backup"

# We delete the backup dir first to make sure all old database dumps have been cleared
rm -fr "$tmpdir"
umask 077
install -d -m 0700 -o root -g root "$tmpdir"
if declare -F enter_user_dir >/dev/null 2>&1; then
	(enter_user_dir "$user" "backup" root) || exit $?
fi
CFG_EOF
            if awk -v repl="$work_cfg/block" '
                /^tmpdir="\/home\/\$user\/backup\/"$/ {
                    while ((getline line < repl) > 0) print line
                    close(repl)
                    in_skip = 1
                    found_top = 1
                    next
                }
                in_skip && /^mkdir -p "\$tmpdir"$/ { in_skip = 0; next }
                in_skip { next }
                /^echo "\$backup_str" > \$tmpdir\/backup\.conf$/ {
                    print
                    print "chmod 660 \"$BACKUP/$user.log\" 2>/dev/null || true"
                    found_bot = 1
                    next
                }
                { print }
                END { if (!found_top || !found_bot) exit 1 }
            ' "$cli_cfg" > "$patched_cfg" && grep -q "hestia-restic-staging-v1" "$patched_cfg" && bash -n "$patched_cfg"; then
                chmod 0755 "$patched_cfg"
                mv -f -- "$patched_cfg" "$cli_cfg"
                _log "[$(date)] : Patched v-backup-user-config (0700 root:root staging dir + 0660 backup log)"
            else
                rm -f -- "$patched_cfg"
            fi
            rm -rf -- "$work_cfg"
        fi
    fi

    # 2. v-add-backup-host-restic (chmod 660 conf/restic.conf)
    local cli_host="$HESTIA/bin/v-add-backup-host-restic"
    if [ -f "$cli_host" ] && ! grep -q "hestia-restic-conf-perms-v1" "$cli_host" 2>/dev/null; then
        if ! grep -q "hestia-restic-" "$cli_host" 2>/dev/null || [ ! -f "${cli_host}.original" ]; then
            cp -f "$cli_host" "${cli_host}.original" 2>/dev/null || true
        fi
        if grep -q "KEEP_YEARLY='\$yearly'" "$cli_host" && ! grep -q "chmod 660 .*conf/restic\.conf" "$cli_host"; then
            local patched_host
            patched_host=$(umask 077 && mktemp "${cli_host}.patch.XXXXXX") || return 1
            if awk '
                /KEEP_YEARLY=/ {
                    print
                    print "# hestia-restic-conf-perms-v1: keep restic credentials private"
                    print "chmod 660 \"${HESTIA:-/usr/local/hestia}/conf/restic.conf\""
                    found = 1
                    next
                }
                { print }
                END { if (!found) exit 1 }
            ' "$cli_host" > "$patched_host" && grep -q "hestia-restic-conf-perms-v1" "$patched_host" && bash -n "$patched_host"; then
                chmod 0755 "$patched_host"
                mv -f -- "$patched_host" "$cli_host"
                _log "[$(date)] : Patched v-add-backup-host-restic (chmod 660 restic.conf)"
            else
                rm -f -- "$patched_host"
            fi
        fi
    fi

    # 3. Tighten existing /backup/*.log files (0644 -> 0660)
    local bkp_dir=""
    if [ -f "$HESTIA/conf/hestia.conf" ]; then
        bkp_dir="$(sed -n "s/^BACKUP=['\"]\?\([^'\"]*\)['\"]\?/\1/p" "$HESTIA/conf/hestia.conf" 2>/dev/null | head -n1)"
    fi
    bkp_dir="${bkp_dir:-/backup}"
    if [ -d "$bkp_dir" ] && [ ! -L "$bkp_dir" ]; then
        local log_f="" log_mode="" fixed_logs=0
        for log_f in "$bkp_dir"/*.log; do
            [ -f "$log_f" ] && [ ! -L "$log_f" ] || continue
            log_mode="$(stat -c '%a' "$log_f" 2>/dev/null || true)"
            if [ -n "$log_mode" ] && [ "$log_mode" != "660" ] && [ "$log_mode" != "600" ] && [ "$log_mode" != "640" ]; then
                chmod 0660 "$log_f" 2>/dev/null && fixed_logs=$((fixed_logs + 1)) || true
            fi
        done
        if [ "$fixed_logs" -gt 0 ]; then
            _log "[$(date)] : Restricted $fixed_logs existing backup log file(s) in $bkp_dir to 0660"
        fi
    fi
    return 0
}

# Fix bulk Cron restore route to pass the required 'yes' argument (PR #5968).
patch_restic_bulk_cron_restore() {
    local bulk_ctrl="$HESTIA/web/bulk/restore/incremental/index.php"
    [ -f "$bulk_ctrl" ] || return 0
    if grep -q "hestia-restic-bulk-restore-v1" "$bulk_ctrl" 2>/dev/null || \
       grep -q '"v-schedule-user-restore-restic " \. \$user \. " " \. \$snapshot \. " " \. "cron" \. " " \. "\x27yes\x27"' "$bulk_ctrl" 2>/dev/null; then
        return 0
    fi
    if ! grep -q '"v-schedule-user-restore-restic " \. \$user \. " " \. \$snapshot \. " " \. "cron",' "$bulk_ctrl" 2>/dev/null; then
        return 0
    fi

    if [ ! -f "${bulk_ctrl}.original" ]; then
        cp -f "$bulk_ctrl" "${bulk_ctrl}.original" 2>/dev/null || true
    fi

    local patched_bulk
    patched_bulk=$(umask 077 && mktemp "${bulk_ctrl}.patch.XXXXXX") || return 1
    if awk -v sq="'" '
        /"v-schedule-user-restore-restic " \. \$user \. " " \. \$snapshot \. " " \. "cron",/ {
            print "\t\t\t// hestia-restic-bulk-restore-v1: pass required yes argument matching standard bulk restore"
            sub(/"cron",/, "\"cron\" . \" \" . \"" sq "yes" sq "\",")
            print
            found = 1
            next
        }
        { print }
        END { if (!found) exit 1 }
    ' "$bulk_ctrl" > "$patched_bulk" && grep -q "hestia-restic-bulk-restore-v1" "$patched_bulk"; then
        if command -v php >/dev/null 2>&1 && ! php -l "$patched_bulk" >/dev/null 2>&1; then
            rm -f -- "$patched_bulk"
            return 1
        fi
        chmod 0644 "$patched_bulk"
        mv -f -- "$patched_bulk" "$bulk_ctrl"
        _log "[$(date)] : Patched web/bulk/restore/incremental/index.php (fixed bulk cron restore yes arg)"
    else
        rm -f -- "$patched_bulk"
    fi
    return 0
}

# Apply user backup exclusions from backup-excludes.conf in v-backup-user-restic (PR #5924).
patch_restic_backup_exclusions() {
    local cli_bkp="$HESTIA/bin/v-backup-user-restic"
    [ -f "$cli_bkp" ] || return 0
    grep -q "hestia-restic-excludes-v1" "$cli_bkp" 2>/dev/null && return 0

    if ! grep -q "hestia-restic-" "$cli_bkp" 2>/dev/null || [ ! -f "${cli_bkp}.original" ]; then
        cp -f "$cli_bkp" "${cli_bkp}.original" 2>/dev/null || true
    fi

    if ! grep -q '\$BIN/v-backup-user-config \$user' "$cli_bkp" 2>/dev/null || \
       ! grep -q 'restic --repo .*backup /home/\$user$' "$cli_bkp" 2>/dev/null; then
        return 0
    fi

    local patch_tmp_root="/run"
    [ -d "$patch_tmp_root" ] && [ -w "$patch_tmp_root" ] || patch_tmp_root="${TMPDIR:-/tmp}"

    local work_exc patched_exc
    work_exc=$(umask 077 && mktemp -d "$patch_tmp_root/hestia-restic-exc.XXXXXX") || return 1
    patched_exc=$(umask 077 && mktemp "${cli_bkp}.patch.XXXXXX") || { rm -rf -- "$work_exc"; return 1; }

    cat > "$work_exc/block" << 'EXC_EOF'
# hestia-restic-excludes-v1: honor user backup-excludes.conf rules during Restic snapshots
restic_excludes=()
if [ -e "$USER_DATA/backup-excludes.conf" ]; then
	WEB=""
	MAIL=""
	USER=""
	source_conf "$USER_DATA/backup-excludes.conf"

	if [ "$WEB" = '*' ]; then
		restic_excludes+=(--exclude "/home/$user/web/*")
	elif [ -n "$WEB" ]; then
		IFS=',' read -ra web_entries <<< "$WEB"
		for entry in "${web_entries[@]}"; do
			[ -z "$entry" ] && continue
			IFS=':' read -ra parts <<< "$entry"
			domain_part="${parts[0]}"
			[ -z "$domain_part" ] && continue
			if [ "${#parts[@]}" -eq 1 ]; then
				restic_excludes+=(--exclude "/home/$user/web/$domain_part")
			else
				for ((i = 1; i < ${#parts[@]}; i++)); do
					seg="${parts[$i]#/}"
					seg="${seg%/}"
					[ -n "$seg" ] && restic_excludes+=(--exclude "/home/$user/web/$domain_part/$seg")
				done
			fi
		done
	fi

	if [ "$MAIL" = '*' ]; then
		restic_excludes+=(--exclude "/home/$user/mail/*")
	elif [ -n "$MAIL" ]; then
		IFS=',' read -ra mail_entries <<< "$MAIL"
		for entry in "${mail_entries[@]}"; do
			[ -z "$entry" ] && continue
			IFS=':' read -ra parts <<< "$entry"
			domain_part="${parts[0]}"
			[ -z "$domain_part" ] && continue
			if [ "$domain_part" != '*' ] && declare -F format_domain_idn >/dev/null 2>&1; then
				domain_idn="$domain_part"
				format_domain_idn
				domain_part="$domain_idn"
			fi
			if [ "${#parts[@]}" -eq 1 ]; then
				restic_excludes+=(--exclude "/home/$user/mail/$domain_part")
			else
				for ((i = 1; i < ${#parts[@]}; i++)); do
					seg="${parts[$i]#/}"
					seg="${seg%/}"
					[ -n "$seg" ] && restic_excludes+=(--exclude "/home/$user/mail/$domain_part/$seg")
				done
			fi
		done
	fi

	if [ "$USER" = '*' ]; then
		while IFS= read -r udir; do
			[ -z "$udir" ] && continue
			restic_excludes+=(--exclude "/home/$user/$udir")
		done < <(ls -A "/home/$user" | grep -Ev '^(backup|conf|web|dns|tmp|mail)$')
	elif [ -n "$USER" ]; then
		IFS=',' read -ra user_entries <<< "$USER"
		for xpath in "${user_entries[@]}"; do
			xpath="${xpath#/}"
			xpath="${xpath%/}"
			[ -n "$xpath" ] && restic_excludes+=(--exclude "/home/$user/$xpath")
		done
	fi
fi
EXC_EOF

    if awk -v repl="$work_exc/block" '
        /\$BIN\/v-backup-user-config \$user/ {
            print
            while ((getline line < repl) > 0) print line
            close(repl)
            found_cfg = 1
            next
        }
        /restic --repo .*backup \/home\/\$user$/ {
            sub(/backup \/home\/\$user$/, "backup \"${restic_excludes[@]}\" /home/$user")
            print
            found_cmd = 1
            next
        }
        { print }
        END { if (!found_cfg || !found_cmd) exit 1 }
    ' "$cli_bkp" > "$patched_exc" && grep -q "hestia-restic-excludes-v1" "$patched_exc" && bash -n "$patched_exc"; then
        chmod 0755 "$patched_exc"
        mv -f -- "$patched_exc" "$cli_bkp"
        _log "[$(date)] : Patched v-backup-user-restic (honor backup-excludes.conf)"
    else
        rm -f -- "$patched_exc"
    fi
    rm -rf -- "$work_exc"
    return 0
}
