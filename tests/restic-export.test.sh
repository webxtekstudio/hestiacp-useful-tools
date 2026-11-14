#!/usr/bin/env bash
# Run the real CLI against disposable Restic fixtures and real tar/flock commands.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
command -v flock >/dev/null || { echo 'SKIP: flock is required for export concurrency tests' >&2; exit 77; }
sand=$(mktemp -d "${TMPDIR:-/tmp}/hestia-export-test.XXXXXX")
trap 'rm -rf -- "$sand"' EXIT
export REAL_TAR
REAL_TAR=$(command -v tar)
export HESTIA="$sand/hestia" HESTIA_HOME_ROOT="$sand/home"
export RESTIC_MANAGER_ALLOW_NONROOT=1 RESTIC_EXPORT_LOCK_DIR="$sand/locks"
export RESTIC_MASTER_KEY_FILE="$sand/master.key" FIXTURE_DATA="$sand/fixture"
export EXPORT_TEST_STATE="$sand/state"
mkdir -p "$HESTIA/conf" "$HESTIA/data/users/bob" "$sand/bin" "$sand/backup" "$EXPORT_TEST_STATE"
mkdir -p "$FIXTURE_DATA/backup/hestia" "$FIXTURE_DATA/backup/web/example.com/hestia" "$FIXTURE_DATA/web/example.com/public_html"
printf "VERSION='1.10.7'\nBACKUP='%s/backup'\nBACKUP_MODE='gzip'\nBACKUP_GZIP='1'\n" "$sand" > "$HESTIA/conf/hestia.conf"
printf "REPO='local:fixture'\n" > "$HESTIA/conf/restic.conf"
printf "U_BACKUPS='0'\nU_DISK='1'\n" > "$HESTIA/data/users/bob/user.conf"
printf 'fixture-password\n' > "$HESTIA/data/users/bob/restic.conf"
printf "DATE='2026-11-11' TIME='16:30:26' BACKUP_MODE='gzip' WEB='example.com'\n" > "$FIXTURE_DATA/backup/backup.conf"
printf "USER='bob'\n" > "$FIXTURE_DATA/backup/hestia/user.conf"
printf "DOMAIN='example.com'\n" > "$FIXTURE_DATA/backup/web/example.com/hestia/web.conf"
printf 'restored website fixture\n' > "$FIXTURE_DATA/web/example.com/public_html/index.html"
cat > "$sand/bin/restic" <<'MOCK'
#!/usr/bin/env bash
set -eu
[ "${MOCK_RESTIC_FAIL:-no}" != yes ] || exit 7
while [ "$#" -gt 0 ]; do
    case "$1" in
        restore)
            printf 'restore\n' >> "$EXPORT_TEST_STATE/restores"
            while [ "$1" != --target ]; do shift; done
            target=$2
            mkdir -p "$target$HESTIA_HOME_ROOT/bob"
            cp -a "$FIXTURE_DATA/." "$target$HESTIA_HOME_ROOT/bob/"
            exit 0 ;;
        dump)
            if [[ "${!#}" == */backup/backup.conf ]]; then
                cat "$FIXTURE_DATA/backup/backup.conf"
            else
                "$REAL_TAR" -cf - -C "$FIXTURE_DATA" .
            fi
            exit 0 ;;
    esac
    shift
done
exit 2
MOCK
cat > "$sand/bin/tar" <<'MOCK'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = -cf ] && [[ "${2:-}" == *.part.* ]]; then
    if [ "${MOCK_FINAL_TAR_FAIL:-no}" = yes ]; then printf 'broken' > "$2"; exit 23; fi
    "$REAL_TAR" "$@"
    if [ "${MOCK_FINAL_TAR_BLOCK:-no}" = yes ]; then
        touch "$EXPORT_TEST_STATE/writing"
        for attempt in {1..200}; do
            [ -f "$EXPORT_TEST_STATE/release" ] && exit 0
            sleep 0.05
        done
        exit 24
    fi
    exit 0
fi
exec "$REAL_TAR" "$@"
MOCK
chmod +x "$sand/bin/restic" "$sand/bin/tar"
export PATH="$sand/bin:$PATH"
cli="$repo/scripts/backup-core-patches/bin/v-restic-manager"
target="$sand/backup/bob.2026-11-11_16-30-26.tar"

bash "$cli" --export-tar bob abcd1234 > "$sand/export.log"
tar -tf "$target" | grep -q './web/example.com/domain_data.tar.gz'
before=$(sha256sum "$target" | cut -d' ' -f1)
if MOCK_FINAL_TAR_FAIL=yes bash "$cli" --export-tar bob abcd1234 > "$sand/failure.log" 2>&1; then
    echo 'FAIL: an interrupted TAR writer succeeded' >&2; exit 1
fi
[ "$(sha256sum "$target" | cut -d' ' -f1)" = "$before" ]
[ -z "$(find "$sand/backup" -name '*.part.*' -o -name 'restic-export-*')" ]
echo 'PASS: failed export preserves the completed archive and removes partial output'

printf 'incomplete tar' > "$target"
bash "$cli" --web-download bob abcd1234 | grep -q '^READY|'
tar -tf "$target" >/dev/null
echo 'PASS: invalid cached TAR is rebuilt before READY'

rm -f -- "$target" "$EXPORT_TEST_STATE/restores"
MOCK_FINAL_TAR_BLOCK=yes bash "$cli" --export-tar bob abcd1234 > "$sand/concurrent.log" 2>&1 &
writer=$!
for attempt in {1..200}; do [ -f "$EXPORT_TEST_STATE/writing" ] && break; sleep 0.05; done
[ -f "$EXPORT_TEST_STATE/writing" ]
[ ! -e "$target" ]
bash "$cli" --web-download bob abcd1234 | grep -q '^QUEUED|'
[ "$(wc -l < "$EXPORT_TEST_STATE/restores")" -eq 1 ]
[ ! -e "$target" ]
touch "$EXPORT_TEST_STATE/release"
wait "$writer"
tar -tf "$target" >/dev/null
bash "$cli" --web-download bob abcd1234 | grep -q '^READY|'
echo 'PASS: concurrent download is queued until one complete export is atomically published'

bash "$cli" --export-tar bob abcd1234 "$sand/archive with spaces.tar" --no-register >/dev/null
tar -tf "$sand/archive with spaces.tar" >/dev/null
echo 'PASS: custom output paths with spaces work'

mkdir -p "$sand/outside-snapshot"
printf 'must never be exported\n' > "$sand/outside-snapshot/private.txt"
mv "$FIXTURE_DATA/web/example.com" "$FIXTURE_DATA/web/original-domain"
ln -s "$sand/outside-snapshot" "$FIXTURE_DATA/web/example.com"
if bash "$cli" --export-tar bob abcd1234 "$sand/unsafe.tar" --no-register > "$sand/unsafe.log" 2>&1; then
    echo 'FAIL: exporter followed a restored symlink outside its staging tree' >&2; exit 1
fi
[ ! -e "$sand/unsafe.tar" ]
echo 'PASS: restored directory symlinks cannot make root export files outside the snapshot'

bash "$cli" --dump-tar bob abcd1234 "$sand/raw.tar" >/dev/null
raw_before=$(sha256sum "$sand/raw.tar" | cut -d' ' -f1)
if MOCK_RESTIC_FAIL=yes bash "$cli" --dump-tar bob abcd1234 "$sand/raw.tar" >/dev/null 2>&1; then exit 1; fi
[ "$(sha256sum "$sand/raw.tar" | cut -d' ' -f1)" = "$raw_before" ]
echo 'PASS: failed raw dump preserves the previous complete archive'

printf "DATE='../outside' TIME='16:30:26'\n" > "$FIXTURE_DATA/backup/backup.conf"
if bash "$cli" --web-download bob abcd1234 >/dev/null 2>&1; then exit 1; fi
echo 'PASS: invalid snapshot timestamps are rejected before output path construction'

HESTIA="$sand/patch-fixture"
mkdir -p "$HESTIA/bin" "$HESTIA/conf" "$HESTIA/data/users/bob" "$HESTIA/data/queue" "$HESTIA/backup"
mkdir -p "$HESTIA/web/templates/pages" "$HESTIA/web/list/backup/incremental" "$HESTIA/web/bulk/restore/incremental" "$HESTIA/web/templates/includes"
touch "$HESTIA/data/queue/backup.pipe"
printf "VERSION='1.10.7'\nBACKUP='%s/backup'\n" "$HESTIA" > "$HESTIA/conf/hestia.conf"
printf "REPO='local:fixture'\n" > "$HESTIA/conf/restic.conf"
printf "U_BACKUPS_INCREMENTAL='3'\nU_BACKUPS='0'\n" > "$HESTIA/data/users/bob/user.conf"
printf "fixture-password\n" > "$HESTIA/data/users/bob/restic.conf"
: > "$HESTIA/backup/bob.log"
chmod 0644 "$HESTIA/backup/bob.log"

cat > "$HESTIA/bin/v-list-user-backups-restic" <<'CLI'
#!/bin/bash
# Keep this upstream header.
function json_list() {
    restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" --json snapshots
}
function plain_list() {
    restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" snapshots
}
case ${format:-json} in
	json) json_list ;;
	plain) plain_list ;;
esac
# Keep this upstream trailer.
CLI

cat > "$HESTIA/bin/v-list-user-backup-restic" <<'CLI'
#!/bin/bash
tmpdir=$(mktemp -p "${BACKUP_TEMP:-$BACKUP}" -d)
restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" --json dump "$snapshot" "/home/$user/backup/backup.conf" > "$tmpdir/backup.conf"
parse_untrusted_conf_file "$tmpdir/backup.conf" \
	BACKUP TYPE SIZE WEB DNS MAIL DB CRON UDIR RUNTIME TIME DATE || exit $?
rm -fr "$tmpdir"
CLI

cat > "$HESTIA/bin/v-list-user-files-restic" <<'CLI'
#!/bin/bash
restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" --json ls "$snapshot" "$folder"
CLI

cat > "$HESTIA/bin/v-backup-user-restic" <<'CLI'
#!/bin/bash
$BIN/v-backup-user-config $user
restic --repo "${REPO%/}/$user" --password-file $USER_DATA/restic.conf --json snapshots > /dev/null
ionice -c 2 -n 7 nice -n 19 restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" backup /home/$user
log_event "$OK" "$ARGUMENTS"
CLI

cat > "$HESTIA/bin/v-backup-user-config" <<'CLI'
#!/bin/bash
tmpdir="/home/$user/backup/"
rm -fr "$tmpdir"
mkdir -p "$tmpdir"
echo "$backup_str" > $tmpdir/backup.conf
CLI

cat > "$HESTIA/bin/v-add-backup-host-restic" <<'CLI'
#!/bin/bash
KEEP_YEARLY='$yearly'
CLI

cat > "$HESTIA/web/bulk/restore/incremental/index.php" <<'PHP'
<?php
foreach ($snapshot_list as $snapshot) {
	exec(
		HESTIA_CMD . "v-schedule-user-restore-restic " . $user . " " . $snapshot . " " . "cron",
		$output,
		$return_var
	);
}
PHP

cat > "$HESTIA/bin/v-delete-user-backup-restic" <<'CLI'
#!/bin/bash
user=$1
snapshot=$2
REPO='local:fixture'
BACKUP="$HESTIA/backup"
USER_DATA="$HESTIA/data/users/$user"
BIN="$HESTIA/bin"
E_INVALID=2; E_NOTEXIST=3; E_CONNECT=15; OK=0; ARGUMENTS="$*"
check_result() { [ "$1" -eq 0 ] && return 0; echo "ERR:$1:$2" >&2; exit "$1"; }
update_user_value() { sed -i "s|^U_BACKUPS_INCREMENTAL='[^']*'|U_BACKUPS_INCREMENTAL='$3'|" "$USER_DATA/user.conf"; }
log_event() { :; }
tmpdir=$(mktemp -p "${BACKUP_TEMP:-$BACKUP}" -d)
if [ ! -f "$tmpdir/backup.conf" ]; then
	restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" dump "$snapshot" "/home/$user/backup/backup.conf" > "$tmpdir/backup.conf"
	if [ "$?" -ne 0 ]; then
		check_result "$E_NOTEXIST" "Unable to download from snapshot"
	fi
fi
restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" forget "$snapshot"
sed -i "/v-delete-user-backup-restic '$user' '$snapshot' /d" "$HESTIA/data/queue/backup.pipe"
$BIN/v-log-action "system" "Info" "Backup" "Restic snapshot successfully deleted (User: $user, Snapshot: $snapshot)."
log_event "$OK" "$ARGUMENTS"
CLI
cat > "$HESTIA/bin/v-log-action" <<'CLI'
#!/bin/bash
exit 0
CLI
chmod +x "$HESTIA/bin/v-log-action"
echo 'upstream-template' > "$HESTIA/web/templates/pages/list_backup_incremental.php"
echo '<?php // upstream' > "$HESTIA/web/list/backup/incremental/index.php"

source "$repo/scripts/backup-core-patches/lib/hestia.sh"
_log() { :; }
patch_restic_snapshot_counter
grep -q 'hestia-restic-counter-v3' "$HESTIA/bin/v-list-user-backups-restic"
grep -q -- 'restic --no-lock --repo' "$HESTIA/bin/v-list-user-backups-restic"
grep -q 'json_list "\${3-}"' "$HESTIA/bin/v-list-user-backups-restic"
grep -q 'Keep this upstream header' "$HESTIA/bin/v-list-user-backups-restic"
grep -q 'Keep this upstream trailer' "$HESTIA/bin/v-list-user-backups-restic"
patched_hash=$(sha256sum "$HESTIA/bin/v-list-user-backups-restic" | cut -d' ' -f1)
patch_restic_snapshot_counter
[ "$(sha256sum "$HESTIA/bin/v-list-user-backups-restic" | cut -d' ' -f1)" = "$patched_hash" ]
[ -z "$(find "$HESTIA/bin" -name '*.patch.*')" ]
echo 'PASS: counter installer preserves surrounding upstream code, sets --no-lock, and is idempotent'

# Runtime cache verification for json_list()
if ! command -v jq >/dev/null 2>&1; then
    cat > "$sand/bin/jq" <<'MOCKJQ'
#!/usr/bin/env node
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
if (!Array.isArray(data) || !data.every((x) => x && typeof x === 'object' && typeof x.id === 'string')) {
  process.exit(1);
}
console.log(data.length);
MOCKJQ
    chmod +x "$sand/bin/jq"
fi
cat > "$sand/bin/restic" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$EXPORT_TEST_STATE/list_calls"
case " $* " in
    *" --no-lock "*) ;;
    *) echo 'missing --no-lock' >&2; exit 9 ;;
esac
echo '[{"id":"abcd1234abcd1234","short_id":"abcd1234","time":"2026-11-11T16:30:26Z"}]'
MOCK
chmod +x "$sand/bin/restic"
: > "$EXPORT_TEST_STATE/list_calls"
export RESTIC_SNAPSHOT_CACHE_DIR="$sand/snap-cache"
mkdir -p "$RESTIC_SNAPSHOT_CACHE_DIR"
export user=bob USER_DATA="$HESTIA/data/users/bob" REPO='local:fixture' format=json
update_user_value() { sed -i "s|^U_BACKUPS_INCREMENTAL='[^']*'|U_BACKUPS_INCREMENTAL='$3'|" "$USER_DATA/user.conf"; }
source <(sed -n '/^function json_list()/,/^}/p' "$HESTIA/bin/v-list-user-backups-restic")
out1=$(json_list)
[ -f "$RESTIC_SNAPSHOT_CACHE_DIR/bob.json" ]
grep -q "^U_BACKUPS_INCREMENTAL='1'" "$USER_DATA/user.conf"
[ "$(wc -l < "$EXPORT_TEST_STATE/list_calls")" -eq 1 ]
out2=$(json_list)
[ "$out1" = "$out2" ]
[ "$(wc -l < "$EXPORT_TEST_STATE/list_calls")" -eq 1 ]
RESTIC_NO_CACHE=1 json_list >/dev/null
[ "$(wc -l < "$EXPORT_TEST_STATE/list_calls")" -eq 2 ]
json_list no-cache >/dev/null
[ "$(wc -l < "$EXPORT_TEST_STATE/list_calls")" -eq 3 ]
echo 'PASS: json_list uses --no-lock, serves cached results within TTL, and honors no-cache bypasses'

# Read-only & delete hardening patches
patch_restic_read_and_delete
grep -q 'hestia-restic-nolock-v2' "$HESTIA/bin/v-list-user-backup-restic"
grep -q 'hestia-restic-nolock-v1' "$HESTIA/bin/v-list-user-files-restic"
grep -q 'hestia-restic-cache-inv-v1' "$HESTIA/bin/v-backup-user-restic"
grep -q 'hestia-restic-delete-v1' "$HESTIA/bin/v-delete-user-backup-restic"
del_hash=$(sha256sum "$HESTIA/bin/v-delete-user-backup-restic" | cut -d' ' -f1)
patch_restic_read_and_delete
[ "$(sha256sum "$HESTIA/bin/v-delete-user-backup-restic" | cut -d' ' -f1)" = "$del_hash" ]

cat > "$sand/bin/restic" <<'MOCKDEL'
#!/usr/bin/env bash
for a in "$@"; do last="$a"; done
if [ "$last" = "deadbeef" ]; then
    echo 'Ignoring "deadbeef": no matching ID found for prefix "deadbeef"'
    exit 0
fi
echo '[0:00] 100.00%  1 / 1 files deleted'
MOCKDEL
chmod +x "$sand/bin/restic"
if bash "$HESTIA/bin/v-delete-user-backup-restic" bob --prune >/dev/null 2>&1; then
    echo 'FAIL: accepted option-like snapshot ID' >&2; exit 1
fi
if bash "$HESTIA/bin/v-delete-user-backup-restic" bob '../bad' >/dev/null 2>&1; then
    echo 'FAIL: accepted invalid snapshot ID' >&2; exit 1
fi
if bash "$HESTIA/bin/v-delete-user-backup-restic" bob deadbeef >/dev/null 2>&1; then
    echo 'FAIL: succeeded on unknown snapshot ID' >&2; exit 1
fi
printf "U_BACKUPS_INCREMENTAL='3'\n" > "$USER_DATA/user.conf"
touch "$RESTIC_SNAPSHOT_CACHE_DIR/bob.json"
bash "$HESTIA/bin/v-delete-user-backup-restic" bob abcd1234 >/dev/null
[ ! -e "$RESTIC_SNAPSHOT_CACHE_DIR/bob.json" ]
[ -z "$(find "$HESTIA/backup" -maxdepth 1 -name 'tmp.*')" ]
grep -q "^U_BACKUPS_INCREMENTAL='2'" "$USER_DATA/user.conf"
echo 'PASS: hardened v-delete-user-backup-restic validates IDs, skips tmpdir leak, invalidates cache, and decrements counter'

# Web UI download/delete route, trash action, instant search script & incremental controller
patch_restic_web_download_ui
[ -f "$HESTIA/web/delete/backup/incremental/index.php" ]
grep -q 'v-delete-user-backup-restic' "$HESTIA/web/delete/backup/incremental/index.php"
[ -f "$HESTIA/web/js/custom_scripts/backup-instant-search.js" ]
[ -f "$HESTIA/web/templates/pages/list_backup_incremental.php.original" ]
grep -q '/delete/backup/incremental/' "$HESTIA/web/templates/pages/list_backup_incremental.php"
grep -q 'fa-trash icon-red' "$HESTIA/web/templates/pages/list_backup_incremental.php"
grep -q 'hestia-restic-inc-ctrl-v2' "$HESTIA/web/list/backup/incremental/index.php"
grep -q 'no-cache' "$HESTIA/web/list/backup/incremental/index.php"
echo 'PASS: web UI patch installs delete endpoint, trash action, instant search JS, and refreshed controller'

# Version gate tests (1.10.7 pin, manual reject, apt-hook safe hold + alert dedupe, override, auto-clear)
vg_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
(
    set -euo pipefail
    vg_sand="$sand/vg-fixture"
    mkdir -p "$vg_sand/conf" "$vg_sand/state"
    cat > "$vg_sand/alert.sh" <<'ALERT'
#!/bin/bash
printf '%s:%s\n' "$1" "$2" >> "$VG_ALERT_LOG"
ALERT
    chmod 0755 "$vg_sand/alert.sh"

    export HESTIA="$vg_sand"
    export HESTIA_TOOLS_CONF="$vg_sand/none.conf"
    export HESTIA_TOOLS_STATE_DIR="$vg_sand/state"
    export HESTIA_TOOLS_HOLD_FILE="$vg_sand/state/hold.state"
    export HESTIA_TOOLS_VERSION_LOG="$vg_sand/state/version.log"
    export HESTIA_TOOLS_ALERT_HOOK="$vg_sand/alert.sh"
    export VG_ALERT_LOG="$vg_sand/state/alerts.log"
    export ALLOW_UNTESTED_HESTIA=0

    source "$vg_repo_root/scripts/lib/version-gate.sh"

    printf "VERSION='1.10.7'\n" > "$vg_sand/conf/hestia.conf"
    rc=0
    check_hestia_core_patch_compatibility "manual" || rc=$?
    [ "$rc" -eq 0 ]

    printf "VERSION='1.10.8'\n" > "$vg_sand/conf/hestia.conf"
    rc=0
    check_hestia_core_patch_compatibility "manual" 2>/dev/null || rc=$?
    [ "$rc" -eq 1 ]

    rc=0
    check_hestia_core_patch_compatibility "apt-hook" 2>/dev/null || rc=$?
    [ "$rc" -eq 2 ]
    grep -qx 'held_version=1.10.8' "$HESTIA_TOOLS_HOLD_FILE"
    [ "$(wc -l < "$VG_ALERT_LOG" | tr -d '[:space:]')" -eq 1 ]
    grep -qx '1.10.8:1.10.7' "$VG_ALERT_LOG"

    rc=0
    check_hestia_core_patch_compatibility "apt-hook" 2>/dev/null || rc=$?
    [ "$rc" -eq 2 ]
    [ "$(wc -l < "$VG_ALERT_LOG" | tr -d '[:space:]')" -eq 1 ]

    ALLOW_UNTESTED_HESTIA=1
    rc=0
    check_hestia_core_patch_compatibility "manual" 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ]

    ALLOW_UNTESTED_HESTIA=0
    printf "VERSION='1.10.7'\n" > "$vg_sand/conf/hestia.conf"
    rc=0
    check_hestia_core_patch_compatibility "apt-hook" || rc=$?
    [ "$rc" -eq 0 ]
    [ ! -e "$HESTIA_TOOLS_HOLD_FILE" ]
)
echo 'PASS: version-gate enforces 1.10.7 pin, apt-hook hold + deduped alert, and override'

# Restic staging perms, conf perms, and existing backup log hardening
patch_restic_staging_perms
grep -q 'hestia-restic-staging-v1' "$HESTIA/bin/v-backup-user-config"
grep -q 'tmpdir="/home/\$user/backup"$' "$HESTIA/bin/v-backup-user-config"
grep -q 'install -d -m 0700 -o root -g root "\$tmpdir"' "$HESTIA/bin/v-backup-user-config"
grep -q 'chmod 660 "\$BACKUP/\$user.log"' "$HESTIA/bin/v-backup-user-config"
grep -q 'hestia-restic-conf-perms-v1' "$HESTIA/bin/v-add-backup-host-restic"
grep -q 'chmod 660 "\${HESTIA:-/usr/local/hestia}/conf/restic.conf"' "$HESTIA/bin/v-add-backup-host-restic"
[ "$(stat -c '%a' "$HESTIA/backup/bob.log")" = "660" ]
echo 'PASS: staging dir, restic.conf, and backup log permissions hardened'

# Bulk cron restore 'yes' argument fix
patch_restic_bulk_cron_restore
grep -q 'hestia-restic-bulk-restore-v1' "$HESTIA/web/bulk/restore/incremental/index.php"
grep -q "'yes'" "$HESTIA/web/bulk/restore/incremental/index.php"
if command -v php >/dev/null 2>&1; then
    php -l "$HESTIA/web/bulk/restore/incremental/index.php" >/dev/null
fi
echo 'PASS: bulk incremental cron restore passes yes argument'

# Backup exclusions patch & runtime argument expansion check
patch_restic_backup_exclusions
grep -q 'hestia-restic-excludes-v1' "$HESTIA/bin/v-backup-user-restic"
grep -q 'backup "\${restic_excludes\[@\]}" /home/\$user' "$HESTIA/bin/v-backup-user-restic"
(
    set -euo pipefail
    exc_sand="$sand/exc-run"
    mkdir -p "$exc_sand/bin" "$exc_sand/conf" "$exc_sand/data/users/bob" "$exc_sand/func" "$exc_sand/backup"
    cat > "$exc_sand/bin/v-backup-user-restic" <<'CLI'
#!/bin/bash
source "${HESTIA}/func/main.sh"
$BIN/v-backup-user-config $user
restic --repo "${REPO%/}/$user" --password-file $USER_DATA/restic.conf --json snapshots > /dev/null
ionice -c 2 -n 7 nice -n 19 restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" backup /home/$user
log_event "$OK" "$ARGUMENTS"
CLI
    cat > "$exc_sand/bin/v-backup-user-config" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod 0755 "$exc_sand/bin/v-backup-user-restic" "$exc_sand/bin/v-backup-user-config"
    HESTIA="$exc_sand" patch_restic_backup_exclusions

    cat > "$exc_sand/func/main.sh" <<'MAIN'
BIN="$HESTIA/bin"
user="bob"
USER_DATA="$HESTIA/data/users/bob"
REPO="local:fixture"
OK="0"
ARGUMENTS="bob"
source_conf() { source "$1"; }
format_domain_idn() { :; }
log_event() { :; }
ionice() { shift 4; "$@"; }
nice() { shift 2; "$@"; }
restic() {
    if [[ " $* " == *" backup "* ]]; then
        printf '%s\n' "$@" > "$HESTIA/restic.args"
    fi
}
MAIN

    cat > "$exc_sand/data/users/bob/backup-excludes.conf" <<'CONF'
WEB='example.com:public_html/cache,blog.example.com'
MAIL='example.com:info'
USER='tmp_downloads,cache/'
CONF
    HESTIA="$exc_sand" bash "$exc_sand/bin/v-backup-user-restic"
    grep -Fxq -- '--exclude' "$exc_sand/restic.args"
    grep -Fxq '/home/bob/web/example.com/public_html/cache' "$exc_sand/restic.args"
    grep -Fxq '/home/bob/web/blog.example.com' "$exc_sand/restic.args"
    grep -Fxq '/home/bob/mail/example.com/info' "$exc_sand/restic.args"
    grep -Fxq '/home/bob/tmp_downloads' "$exc_sand/restic.args"
    grep -Fxq '/home/bob/cache' "$exc_sand/restic.args"

    rm -f "$exc_sand/data/users/bob/backup-excludes.conf" "$exc_sand/restic.args"
    HESTIA="$exc_sand" bash "$exc_sand/bin/v-backup-user-restic"
    ! grep -Fxq -- '--exclude' "$exc_sand/restic.args"
    ! grep -Fxq '' "$exc_sand/restic.args"
    grep -Fxq '/home/bob' "$exc_sand/restic.args"
)
echo 'PASS: Restic backup honors backup-excludes.conf without empty-arg expansion'

# hestia-restic-nolock-v2 preserves parse failure exit code & removes tmpdir
(
    set -euo pipefail
    det_sand="$sand/nolock-v2-fixture"
    mkdir -p "$det_sand/bin" "$det_sand/func" "$det_sand/backup" "$det_sand/data/users/bob"
    cat > "$det_sand/bin/v-list-user-backup-restic" <<'CLI'
#!/bin/bash
source "${HESTIA}/func/main.sh"
tmpdir=$(mktemp -p "${BACKUP_TEMP:-$BACKUP}" -d)
restic --repo "${REPO%/}/$user" --password-file "$USER_DATA/restic.conf" --json dump "$snapshot" "/home/$user/backup/backup.conf" > "$tmpdir/backup.conf"
parse_untrusted_conf_file "$tmpdir/backup.conf" BACKUP TYPE SIZE WEB DNS MAIL DB CRON UDIR RUNTIME TIME DATE
rm -fr "$tmpdir"
CLI
    chmod 0755 "$det_sand/bin/v-list-user-backup-restic"
    HESTIA="$det_sand" patch_restic_read_and_delete
    grep -q 'hestia-restic-nolock-v2' "$det_sand/bin/v-list-user-backup-restic"

    cat > "$det_sand/func/main.sh" <<'MAIN'
BACKUP="$HESTIA/backup"
USER_DATA="$HESTIA/data/users/bob"
REPO="local:fixture"
user="bob"
snapshot="abc12345"
E_NOTEXIST="3"
check_result() { exit "$1"; }
restic() { printf "BACKUP='x'\n"; }
parse_untrusted_conf_file() { return 42; }
MAIN

    rc=0
    HESTIA="$det_sand" bash "$det_sand/bin/v-list-user-backup-restic" || rc=$?
    [ "$rc" -eq 42 ]
    [ -z "$(ls -A "$det_sand/backup")" ]
)
echo 'PASS: v-list-user-backup-restic preserves parse failure exit code and cleans tmpdir'
