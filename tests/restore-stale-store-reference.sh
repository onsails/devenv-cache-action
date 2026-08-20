#!/usr/bin/env bash
# Proves restored evaluation databases cannot reintroduce references to invalid Nix store closures.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(dirname "$here")"
sqlite3_path="$(command -v sqlite3)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

key_base='devenv-eval-Linux-x86_64-layoutv3-nix0-eval1-nixeval1-devenvtest-version-deadbeef'
staging="${work}/staging"
mkdir -p "${staging}/nix-eval-cache-v6" "${work}/bin"

invalid_direct='/nix/store/00000000000000000000000000000000-direct-invalid'
invalid_closure='/nix/store/11111111111111111111111111111111-closure-invalid.drv'
valid_path='/nix/store/22222222222222222222222222222222-valid'

# The fake command distinguishes an invalid direct path from a valid root whose closure contains an
# invalid requisite. Real `nix-store --query --requisites` can list an invalid path and still exit 0.
cat > "${work}/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = --query ] && [ "$2" = --requisites ]; then
  shift 2
  for path in "$@"; do
    printf '%s\n' "$path"
    if [ "$path" = '/nix/store/11111111111111111111111111111111-closure-invalid.drv' ]; then
      printf '%s\n' '/nix/store/33333333333333333333333333333333-missing-requisite.patch'
    fi
  done
  exit 0
fi
if [ "$1" = --check-validity ]; then
  shift
  for path in "$@"; do
    case "$path" in
      '/nix/store/00000000000000000000000000000000-direct-invalid'|\
      '/nix/store/33333333333333333333333333333333-missing-requisite.patch') exit 1 ;;
    esac
  done
  exit 0
fi
exit 1
EOF
chmod +x "${work}/bin/nix-store"

# Devenv snapshot: SQLite is valid, but cached JSON names a directly invalid store path.
eval_snapshot="${staging}/nix-eval-cache.db"
"${sqlite3_path}" "${eval_snapshot}" <<SQL
CREATE TABLE cached_eval(json_output TEXT NOT NULL);
CREATE TABLE eval_resource_spec(spec TEXT NOT NULL);
INSERT INTO cached_eval VALUES ('{"out_path":"${invalid_direct}"}');
INSERT INTO eval_resource_spec VALUES ('{}');
SQL

# First Nix DB: its derivation exists, but querying its closure fails. Second DB is valid.
stale_nix="${staging}/nix-eval-cache-v6/stale.sqlite"
"${sqlite3_path}" "${stale_nix}" <<SQL
CREATE TABLE Attributes(value TEXT, context TEXT);
INSERT INTO Attributes VALUES ('${invalid_closure}', NULL);
SQL
valid_nix="${staging}/nix-eval-cache-v6/valid.sqlite"
"${sqlite3_path}" "${valid_nix}" <<SQL
CREATE TABLE Attributes(value TEXT, context TEXT);
INSERT INTO Attributes VALUES ('${valid_path}', NULL);
SQL

sha() { sha256sum "$1" | cut -d' ' -f1; }
bytes() { wc -c < "$1" | tr -d ' '; }
printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"test-version","evalDb":{"name":"nix-eval-cache.db","sha256":"%s","bytes":%s},"nixEvalFiles":[{"name":"stale.sqlite","sha256":"%s","bytes":%s},{"name":"valid.sqlite","sha256":"%s","bytes":%s}]}' \
  "${key_base}" "$(sha "${eval_snapshot}")" "$(bytes "${eval_snapshot}")" \
  "$(sha "${stale_nix}")" "$(bytes "${stale_nix}")" \
  "$(sha "${valid_nix}")" "$(bytes "${valid_nix}")" > "${staging}/manifest.json"

home="${work}/home"
live_db="${work}/checkout/.devenv/nix-eval-cache.db"
output="${work}/github-output"
mkdir -p "${home}"
: > "${output}"

PATH="${work}/bin:${PATH}" \
HOME="${home}" \
STAGING_DIR="${staging}" \
MANIFEST="${staging}/manifest.json" \
LIVE_DB="${live_db}" \
SQLITE3_PATH="${sqlite3_path}" \
EXPECTED_KEY="${key_base}" \
DEVENV_VERSION='test-version' \
CACHE_EVAL='true' \
CACHE_NIX_EVAL='true' \
GITHUB_OUTPUT="${output}" \
  bash "${root}/restore-eval-cache.sh"

fail() { echo "restore-stale-store-reference: $1" >&2; exit 1; }
grep -qx 'eval-cache-restored=false' "${output}" || fail 'expected stale devenv DB rejection'
! grep -qx 'eval-cache-restored=true' "${output}" || fail 'stale devenv DB was restored'
[ ! -e "${live_db}" ] || fail 'stale devenv DB was installed'
grep -qx 'nix-eval-cache-restored=true' "${output}" || fail 'expected valid Nix DB restore'
grep -qx 'nix-eval-files-restored=1' "${output}" || fail 'expected exactly one valid Nix DB'
[ ! -e "${home}/.cache/nix/eval-cache-v6/stale.sqlite" ] || fail 'stale Nix DB was installed'
[ -e "${home}/.cache/nix/eval-cache-v6/valid.sqlite" ] || fail 'valid Nix DB was not installed'

echo 'restore-stale-store-reference: OK'
