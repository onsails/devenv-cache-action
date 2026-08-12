#!/usr/bin/env bash
# Proves the Nix eval-cache-v6 restore path replaces a live destination database together with its
# stale -wal/-shm sidecars. Nix (or any earlier setup step in the same job) can leave sidecars next
# to a fingerprint DB; if restore only overwrote the DB file, SQLite would pair the freshly copied
# snapshot with unrelated WAL pages.
#
# Usage: tests/restore-stale-wal.sh   (needs sqlite3 and node on PATH)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(dirname "$here")"
sqlite3_path="$(command -v sqlite3)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

key_base='devenv-eval-Linux-x86_64-layoutv3-nix0-eval1-nixeval1-devenvtest-version-deadbeef'
name='stale-test.sqlite'

staging="${work}/staging"
mkdir -p "${staging}/nix-eval-cache-v6"
snapshot="${staging}/nix-eval-cache-v6/${name}"
"${sqlite3_path}" "${snapshot}" \
  "CREATE TABLE snapshot_marker(value TEXT); INSERT INTO snapshot_marker VALUES ('from-snapshot');"
sha="$(sha256sum "${snapshot}" | cut -d' ' -f1)"
bytes="$(wc -c < "${snapshot}" | tr -d ' ')"
printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"test-version","evalDb":null,"nixEvalFiles":[{"name":"%s","sha256":"%s","bytes":%s}]}' \
  "${key_base}" "${name}" "${sha}" "${bytes}" > "${staging}/manifest.json"

home="${work}/home"
destination="${home}/.cache/nix/eval-cache-v6/${name}"
mkdir -p "$(dirname "${destination}")"
# A live WAL-mode database plus sidecars that do not belong to the snapshot.
"${sqlite3_path}" "${destination}" \
  "PRAGMA journal_mode=wal; CREATE TABLE live_marker(value TEXT); INSERT INTO live_marker VALUES ('stale');" >/dev/null
printf 'stale-wal-bytes' > "${destination}-wal"
printf 'stale-shm-bytes' > "${destination}-shm"

output="${work}/github-output"
: > "${output}"
HOME="${home}" \
STAGING_DIR="${staging}" \
MANIFEST="${staging}/manifest.json" \
LIVE_DB="${work}/checkout/.devenv/nix-eval-cache.db" \
SQLITE3_PATH="${sqlite3_path}" \
EXPECTED_KEY="${key_base}" \
DEVENV_VERSION='test-version' \
CACHE_EVAL='false' \
CACHE_NIX_EVAL='true' \
GITHUB_OUTPUT="${output}" \
  bash "${root}/restore-eval-cache.sh"

fail() { echo "restore-stale-wal: $1" >&2; exit 1; }

grep -qx 'nix-eval-cache-restored=true' "${output}" || fail 'expected nix-eval-cache-restored=true'
grep -qx 'nix-eval-files-restored=1' "${output}" || fail 'expected nix-eval-files-restored=1'

[ ! -e "${destination}-wal" ] || fail 'stale -wal sidecar survived the restore'
[ ! -e "${destination}-shm" ] || fail 'stale -shm sidecar survived the restore'

[ "$("${sqlite3_path}" "${destination}" 'PRAGMA quick_check;' | tr -d '\n')" = ok ] \
  || fail 'restored DB failed quick_check'
[ "$("${sqlite3_path}" "${destination}" 'SELECT value FROM snapshot_marker;')" = 'from-snapshot' ] \
  || fail 'restored DB is not the staged snapshot'
"${sqlite3_path}" "${destination}" 'SELECT name FROM sqlite_master;' | grep -qx live_marker \
  && fail 'restored DB still exposes the replaced live database'

echo 'restore-stale-wal: OK'
