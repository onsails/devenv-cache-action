#!/usr/bin/env bash
# Snapshot the live devenv eval-cache DB into the staging directory for archiving.
#
# Uses SQLite's online backup API (`.backup`): produces a consistent, closed
# snapshot of a DB that may be open and running in WAL mode. Never copies the
# live DB or its -wal/-shm sidecars directly.
#
# Inputs (env):
#   STAGING_DIR   staging dir under $RUNNER_TEMP
#   LIVE_DB       path to the live DB
#   MANIFEST      path to write manifest.json
#   SQLITE3_PATH  resolved sqlite3 executable
#   EXPECTED_KEY  primary cache key
#   DEVENV_VERSION devenv version
#   CACHE_EVAL    "true" if eval caching is enabled
#
# On success: the staging dir contains nix-eval-cache.db + manifest.json.
# A no-eval-db manifest is recorded if the live DB is absent (save still proceeds
# for ~/.cache/nix).
set -euo pipefail

# sha256 helper that works on a file.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Escape a path into a SQL single-quoted literal: each ' becomes ''.
sql_escape() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\'}"
}

# Fail hard if eval caching is on but sqlite3 is unavailable or non-executable.
if [ "${CACHE_EVAL}" = "true" ]; then
  if [ -z "${SQLITE3_PATH}" ] || [ ! -x "${SQLITE3_PATH}" ]; then
    echo "devenv-cache-action: sqlite3 not executable at '${SQLITE3_PATH}' (cache-eval requires it)" >&2
    exit 1
  fi
fi

# If eval caching is disabled, nothing to stage for the DB.
if [ "${CACHE_EVAL}" != "true" ]; then
  exit 0
fi

# Fresh staging directory, mode 0700.
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
chmod 700 "${STAGING_DIR}"

staged_db="${STAGING_DIR}/nix-eval-cache.db"

# If no live DB exists, record an explicit no-eval-db manifest. The save still
# proceeds for ~/.cache/nix.
if [ ! -f "${LIVE_DB}" ]; then
  tmp_manifest="$(mktemp)"
  cat > "$tmp_manifest" <<EOF
{"schema":1,"manifestFormat":1,"key":"${EXPECTED_KEY}","devenvVersion":"${DEVENV_VERSION}","dbBytes":0,"dbSha256":"","note":"no-eval-db"}
EOF
  mv "$tmp_manifest" "${MANIFEST}"
  echo "devenv-cache-action: no live eval DB; recorded no-eval-db manifest" >&2
  exit 0
fi

# Remove any prior staged DB before snapshotting.
rm -f "${staged_db}"

# Snapshot via SQLite's online backup API. This reads through SQLite's own
# backup machinery and produces a consistent file; it does not copy the live
# file or its sidecars.
escaped_target="$(sql_escape "${staged_db}")"
"${SQLITE3_PATH}" "${LIVE_DB}" ".backup ${escaped_target}" || {
  echo "devenv-cache-action: sqlite3 .backup failed" >&2
  exit 1
}

# Require quick_check == ok on the snapshot.
check="$( "${SQLITE3_PATH}" "${staged_db}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n' )"
if [ "$check" != "ok" ]; then
  echo "devenv-cache-action: snapshot failed quick_check ($check); aborting save" >&2
  rm -f "${staged_db}"
  exit 1
fi

# Compute digest + size.
db_sha="$(sha256_file "${staged_db}")"
db_bytes="$(wc -c < "${staged_db}" | tr -d ' ')"
[ -n "$db_bytes" ] || { echo "devenv-cache-action: could not stat snapshot size" >&2; exit 1; }

# Atomically write the manifest (mktemp then mv).
tmp_manifest="$(mktemp)"
cat > "$tmp_manifest" <<EOF
{"schema":1,"manifestFormat":1,"key":"${EXPECTED_KEY}","devenvVersion":"${DEVENV_VERSION}","dbBytes":${db_bytes},"dbSha256":"${db_sha}"}
EOF
mv "$tmp_manifest" "${MANIFEST}"

echo "devenv-cache-action: snapshot OK (${db_bytes} bytes, sha256 ${db_sha:0:12})" >&2
