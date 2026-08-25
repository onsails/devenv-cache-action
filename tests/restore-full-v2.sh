#!/usr/bin/env bash
set -euo pipefail
# End-to-end restore test with a realistic v2 manifest containing evalDb + 2 nixEvalFiles.

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
sqlite3_path="$(command -v sqlite3)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

key_base='devenv-eval-Linux-x86_64-layoutv3-nix0-eval1-nixeval1-devenvtest-version-deadbeef'
staging="${work}/staging"
mkdir -p "${staging}/nix-eval-cache-v6" "${work}/bin"

cat >"${work}/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --check-validity ] || exit 1
exit 0
EOF
chmod +x "${work}/bin/nix-store"

eval_snapshot="${staging}/nix-eval-cache.db"
"${sqlite3_path}" "${eval_snapshot}" \
  "CREATE TABLE cached_eval(json_output TEXT NOT NULL); CREATE TABLE eval_resource_spec(spec TEXT NOT NULL); INSERT INTO cached_eval VALUES ('devenv'); INSERT INTO eval_resource_spec VALUES ('fixture');"

nix1="${staging}/nix-eval-cache-v6/abc123.sqlite"
"${sqlite3_path}" "${nix1}" \
  "CREATE TABLE Attributes(value TEXT, context TEXT); INSERT INTO Attributes VALUES ('one', NULL);"
nix2="${staging}/nix-eval-cache-v6/self-test.sqlite"
"${sqlite3_path}" "${nix2}" \
  "CREATE TABLE Attributes(value TEXT, context TEXT); INSERT INTO Attributes VALUES ('seed', NULL);"

sha() { sha256sum "$1" | cut -d' ' -f1; }
bytes() { wc -c <"$1" | tr -d ' '; }
printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"test-version","evalDb":{"name":"nix-eval-cache.db","sha256":"%s","bytes":%s},"nixEvalFiles":[{"name":"abc123.sqlite","sha256":"%s","bytes":%s},{"name":"self-test.sqlite","sha256":"%s","bytes":%s}]}' \
  "${key_base}" "$(sha "${eval_snapshot}")" "$(bytes "${eval_snapshot}")" \
  "$(sha "${nix1}")" "$(bytes "${nix1}")" \
  "$(sha "${nix2}")" "$(bytes "${nix2}")" >"${staging}/manifest.json"

home="${work}/home"
live_db="${work}/checkout/.devenv/nix-eval-cache.db"
mkdir -p "${home}/.cache/nix/eval-cache-v6" "$(dirname "${live_db}")"
output="${work}/github-output"
: >"${output}"

PATH="${work}/bin:${PATH}" HOME="${home}" STAGING_DIR="${staging}" \
MANIFEST="${staging}/manifest.json" LIVE_DB="${live_db}" SQLITE3_PATH="${sqlite3_path}" \
EXPECTED_KEY="${key_base}" DEVENV_VERSION='test-version' CACHE_EVAL='true' \
CACHE_NIX_EVAL='true' GITHUB_OUTPUT="${output}" bash "${root}/restore-eval-cache.sh"

fail() { echo "restore-full-v2: $1" >&2; exit 1; }
grep -qx 'eval-cache-restored=true' "${output}" || fail 'eval restore status was not true'
grep -qxF "eval-db-path=${live_db}" "${output}" || fail 'eval DB path output missing'
grep -qx 'nix-eval-cache-restored=true' "${output}" || fail 'Nix restore status was not true'
grep -qx 'nix-eval-files-restored=2' "${output}" || fail 'expected exactly two Nix DB restores'
[ "$("${sqlite3_path}" "${live_db}" 'SELECT json_output FROM cached_eval;')" = devenv ] \
  || fail 'installed devenv DB contents differ from snapshot'
[ "$("${sqlite3_path}" "${home}/.cache/nix/eval-cache-v6/abc123.sqlite" 'SELECT value FROM Attributes;')" = one ] \
  || fail 'installed first Nix DB contents differ from snapshot'
[ "$("${sqlite3_path}" "${home}/.cache/nix/eval-cache-v6/self-test.sqlite" 'SELECT value FROM Attributes;')" = seed ] \
  || fail 'installed second Nix DB contents differ from snapshot'

echo 'restore-full-v2: OK'
