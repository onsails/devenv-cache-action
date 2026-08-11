#!/usr/bin/env bash
# Restore the devenv eval-cache DB snapshot from the staged cache entry.
#
# Inputs (env):
#   STAGING_DIR   staging dir restored by actions/cache/restore
#   MANIFEST      path to manifest.json
#   LIVE_DB       path where devenv expects the live DB (created/overwritten)
#   SQLITE3_PATH  resolved sqlite3 executable
#   EXPECTED_KEY  primary cache key (for manifest validation)
#   DEVENV_VERSION expected devenv version (for manifest validation)
#   CACHE_EVAL    "true" if eval caching is enabled
#
# Outputs (GITHUB_OUTPUT):
#   eval-cache-restored   "true" if a validated DB was installed, else "false"
#   eval-db-path          path to the installed live DB when restored
set -euo pipefail

out_file="${GITHUB_OUTPUT:-/dev/stdout}"
emit() { printf '%s\n' "$1" >> "$out_file"; }

emit "eval-cache-restored=false"

# If eval caching is disabled, nothing to do.
if [ "${CACHE_EVAL}" != "true" ]; then
  exit 0
fi

# If the staging dir was not restored (cache miss), this is a normal miss.
snapshot="${STAGING_DIR}/nix-eval-cache.db"
if [ ! -d "${STAGING_DIR}" ] || [ ! -f "${snapshot}" ] || [ ! -f "${MANIFEST}" ]; then
  echo "devenv-cache-action: eval cache miss (no snapshot/manifest restored)" >&2
  exit 0
fi

# Validate manifest against expected key/version, extract declared digest + size.
parsed="$(node "${GITHUB_ACTION_PATH}/parse-manifest.js" "${MANIFEST}" "${EXPECTED_KEY}" "${DEVENV_VERSION}")" || {
  echo "devenv-cache-action: manifest rejected, treating as miss" >&2
  exit 0
}
declared_sha="${parsed%% *}"

# quick_check on the restored snapshot BEFORE it touches the live path.
check="$( "${SQLITE3_PATH}" "${snapshot}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n' )"
if [ "$check" != "ok" ]; then
  echo "devenv-cache-action: restored snapshot failed quick_check, treating as miss" >&2
  exit 0
fi

# Verify the snapshot digest matches the manifest.
actual_sha="$(sha256sum "${snapshot}" | cut -d' ' -f1)"
if [ "$actual_sha" != "$declared_sha" ]; then
  echo "devenv-cache-action: restored snapshot digest mismatch (manifest ${declared_sha:0:12}, actual ${actual_sha:0:12}), treating as miss" >&2
  exit 0
fi

# Install the verified snapshot to the live path.
mkdir -p "$(dirname "${LIVE_DB}")"
# Remove only the target DB and its WAL/SHM sidecars — never the whole .devenv/.
rm -f "${LIVE_DB}" "${LIVE_DB}-wal" "${LIVE_DB}-shm"
cp "${snapshot}" "${LIVE_DB}"

# quick_check on the installed copy. If it fails, remove only that copy and fail hard.
installed_check="$( "${SQLITE3_PATH}" "${LIVE_DB}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n' )"
if [ "$installed_check" != "ok" ]; then
  rm -f "${LIVE_DB}"
  echo "devenv-cache-action: installed DB failed quick_check; removed. Failing." >&2
  exit 1
fi

emit "eval-cache-restored=true"
emit "eval-db-path=${LIVE_DB}"
echo "devenv-cache-action: eval DB restored and verified (sha256 ${actual_sha:0:12})" >&2
