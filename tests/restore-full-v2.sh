#!/usr/bin/env bash
set -euo pipefail
# End-to-end restore test with a realistic v2 manifest containing evalDb + 2 nixEvalFiles

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
sqlite3_path="$(command -v sqlite3)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

key_base='devenv-eval-Linux-x86_64-layoutv3-nix0-eval1-nixeval1-devenvtest-version-deadbeef'

staging="${work}/staging"
mkdir -p "${staging}/nix-eval-cache-v6"

eval_snapshot="${staging}/nix-eval-cache.db"
"${sqlite3_path}" "${eval_snapshot}" "CREATE TABLE eval(value TEXT); INSERT INTO eval VALUES ('devenv');"
eval_sha="$(sha256sum "${eval_snapshot}" | cut -d' ' -f1)"
eval_bytes="$(wc -c < "${eval_snapshot}" | tr -d ' ')"

# Create two Nix eval DBs
nix1="${staging}/nix-eval-cache-v6/abc123.sqlite"
"${sqlite3_path}" "${nix1}" "CREATE TABLE n1(value TEXT); INSERT INTO n1 VALUES ('one');"
nix1_sha="$(sha256sum "${nix1}" | cut -d' ' -f1)"
nix1_bytes="$(wc -c < "${nix1}" | tr -d ' ')"

nix2="${staging}/nix-eval-cache-v6/self-test.sqlite"
"${sqlite3_path}" "${nix2}" "CREATE TABLE seeded(value TEXT); INSERT INTO seeded VALUES ('seed');"
nix2_sha="$(sha256sum "${nix2}" | cut -d' ' -f1)"
nix2_bytes="$(wc -c < "${nix2}" | tr -d ' ')"

# Write manifest
printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"test-version","evalDb":{"name":"nix-eval-cache.db","sha256":"%s","bytes":%s},"nixEvalFiles":[{"name":"abc123.sqlite","sha256":"%s","bytes":%s},{"name":"self-test.sqlite","sha256":"%s","bytes":%s}]}' \
  "${key_base}" "${eval_sha}" "${eval_bytes}" "${nix1_sha}" "${nix1_bytes}" "${nix2_sha}" "${nix2_bytes}" \
  > "${staging}/manifest.json"

echo "=== MANIFEST ==="
cat "${staging}/manifest.json"
echo

# Create live DB destinations
home="${work}/home"
mkdir -p "${home}/.cache/nix/eval-cache-v6" "${work}/checkout/.devenv"

output="${work}/github-output"
: > "${output}"

set +e
HOME="${home}" \
STAGING_DIR="${staging}" \
MANIFEST="${staging}/manifest.json" \
LIVE_DB="${work}/checkout/.devenv/nix-eval-cache.db" \
SQLITE3_PATH="${sqlite3_path}" \
EXPECTED_KEY="${key_base}" \
DEVENV_VERSION='test-version' \
CACHE_EVAL='true' \
CACHE_NIX_EVAL='true' \
GITHUB_OUTPUT="${output}" \
  bash "${root}/restore-eval-cache.sh" 2>&1
rc=$?
set -e

echo "=== RESTORE EXIT: $rc ==="
echo "=== OUTPUT ==="
cat "${output}"
echo "=== EXPECTED ==="
echo "eval-cache-restored=true"
echo "nix-eval-cache-restored=true"
echo "nix-eval-files-restored=2"
