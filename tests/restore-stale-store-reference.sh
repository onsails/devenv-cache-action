#!/usr/bin/env bash
# Proves invalid or merely substitutable references cannot replace live evaluation databases.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(dirname "$here")"
sqlite3_path="$(command -v sqlite3)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

key_base='devenv-eval-Linux-x86_64-layoutv3-nix0-eval1-nixeval1-devenvtest-version-deadbeef'
staging="${work}/staging"
mkdir -p "${staging}/nix-eval-cache-v6" "${work}/bin"

invalid_drv='/nix/store/11111111111111111111111111111111-closure-invalid.drv'
recoverable_path='/nix/store/22222222222222222222222222222222-recoverable'
valid_path='/nix/store/44444444444444444444444444444444-valid'

cat >"${work}/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = --query ] && [ "$2" = --requisites ]; then
  shift 2
  for path in "$@"; do
    printf '%s\n' "$path"
    [ "$path" != '/nix/store/11111111111111111111111111111111-closure-invalid.drv' ] \
      || printf '%s\n' '/nix/store/33333333333333333333333333333333-missing-requisite.patch'
  done
  exit 0
fi
if [ "$1" = --check-validity ]; then
  shift
  for path in "$@"; do
    case "$path" in
      '/nix/store/22222222222222222222222222222222-recoverable'|\
      '/nix/store/33333333333333333333333333333333-missing-requisite.patch') exit 1 ;;
    esac
  done
  exit 0
fi
exit 1
EOF
chmod +x "${work}/bin/nix-store"

eval_snapshot="${staging}/nix-eval-cache.db"
"${sqlite3_path}" "${eval_snapshot}" <<SQL
CREATE TABLE cached_eval(json_output TEXT NOT NULL);
CREATE TABLE eval_resource_spec(spec TEXT NOT NULL);
INSERT INTO cached_eval VALUES ('${invalid_drv}');
INSERT INTO eval_resource_spec VALUES ('{}');
SQL

stale_nix="${staging}/nix-eval-cache-v6/stale.sqlite"
"${sqlite3_path}" "${stale_nix}" \
  "CREATE TABLE Attributes(value TEXT, context TEXT); INSERT INTO Attributes VALUES ('${recoverable_path}', NULL);"
valid_nix="${staging}/nix-eval-cache-v6/valid.sqlite"
"${sqlite3_path}" "${valid_nix}" \
  "CREATE TABLE Attributes(value TEXT, context TEXT); INSERT INTO Attributes VALUES ('${valid_path}', NULL);"

sha() { sha256sum "$1" | cut -d' ' -f1; }
bytes() { wc -c <"$1" | tr -d ' '; }
printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"test-version","evalDb":{"name":"nix-eval-cache.db","sha256":"%s","bytes":%s},"nixEvalFiles":[{"name":"stale.sqlite","sha256":"%s","bytes":%s},{"name":"valid.sqlite","sha256":"%s","bytes":%s}]}' \
  "${key_base}" "$(sha "${eval_snapshot}")" "$(bytes "${eval_snapshot}")" \
  "$(sha "${stale_nix}")" "$(bytes "${stale_nix}")" \
  "$(sha "${valid_nix}")" "$(bytes "${valid_nix}")" >"${staging}/manifest.json"

home="${work}/home"
live_db="${work}/checkout/.devenv/nix-eval-cache.db"
stale_destination="${home}/.cache/nix/eval-cache-v6/stale.sqlite"
mkdir -p "$(dirname "${live_db}")" "$(dirname "${stale_destination}")"
printf 'live-devenv-sentinel' >"${live_db}"
printf 'live-nix-sentinel' >"${stale_destination}"
output="${work}/github-output"
: >"${output}"

PATH="${work}/bin:${PATH}" HOME="${home}" STAGING_DIR="${staging}" \
MANIFEST="${staging}/manifest.json" LIVE_DB="${live_db}" SQLITE3_PATH="${sqlite3_path}" \
EXPECTED_KEY="${key_base}" DEVENV_VERSION='test-version' CACHE_EVAL='true' \
CACHE_NIX_EVAL='true' GITHUB_OUTPUT="${output}" bash "${root}/restore-eval-cache.sh"

fail() { echo "restore-stale-store-reference: $1" >&2; exit 1; }
grep -qx 'eval-cache-restored=false' "${output}" || fail 'expected stale devenv DB rejection'
! grep -qx 'eval-cache-restored=true' "${output}" || fail 'stale devenv DB was restored'
[ "$(cat "${live_db}")" = 'live-devenv-sentinel' ] || fail 'live devenv DB was changed'
grep -qx 'nix-eval-cache-restored=true' "${output}" || fail 'expected valid sibling restore'
grep -qx 'nix-eval-files-restored=1' "${output}" || fail 'expected exactly one valid Nix DB'
[ "$(cat "${stale_destination}")" = 'live-nix-sentinel' ] || fail 'rejected Nix DB changed live destination'
[ -e "${home}/.cache/nix/eval-cache-v6/valid.sqlite" ] || fail 'valid sibling was not installed'

echo 'restore-stale-store-reference: OK'
