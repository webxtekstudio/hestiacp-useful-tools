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
printf "BACKUP='%s/backup'\nBACKUP_MODE='gzip'\nBACKUP_GZIP='1'\n" "$sand" > "$HESTIA/conf/hestia.conf"
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
mkdir -p "$HESTIA/bin"
cat > "$HESTIA/bin/v-list-user-backups-restic" <<'CLI'
#!/bin/bash
# Keep this upstream header.
function json_list() {
    restic snapshots
}
# Keep this upstream trailer.
CLI
source "$repo/scripts/backup-core-patches/lib/hestia.sh"
_log() { :; }
patch_restic_snapshot_counter
grep -q 'hestia-restic-counter-v2' "$HESTIA/bin/v-list-user-backups-restic"
grep -q 'Keep this upstream header' "$HESTIA/bin/v-list-user-backups-restic"
grep -q 'Keep this upstream trailer' "$HESTIA/bin/v-list-user-backups-restic"
patched_hash=$(sha256sum "$HESTIA/bin/v-list-user-backups-restic" | cut -d' ' -f1)
patch_restic_snapshot_counter
[ "$(sha256sum "$HESTIA/bin/v-list-user-backups-restic" | cut -d' ' -f1)" = "$patched_hash" ]
[ -z "$(find "$HESTIA/bin" -name '*.patch.*')" ]
echo 'PASS: counter installer preserves surrounding upstream code and is idempotent'
