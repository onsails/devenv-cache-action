#!/usr/bin/env bash
# Create only SQLite online-backup snapshots for the action-owned cache staging directory.
# Live databases and their WAL/SHM sidecars are never cache paths.
#
# Inputs: STAGING_DIR LIVE_DB MANIFEST SQLITE3_PATH EXPECTED_KEY_BASE DEVENV_VERSION
#         CACHE_EVAL CACHE_NIX_EVAL
set -euo pipefail

readonly MAX_NIX_EVAL_FILES=8
readonly MAX_NIX_EVAL_BYTES=$((128 * 1024 * 1024))

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

json_escape() {
  # Snapshot names are deliberately restricted, but keep this correct for key/version values.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [ "${CACHE_EVAL}" != "true" ] && [ "${CACHE_NIX_EVAL}" != "true" ]; then
  exit 0
fi
if [ -z "${SQLITE3_PATH:-}" ] || [ ! -x "${SQLITE3_PATH}" ]; then
  echo "devenv-cache-action: sqlite3 not executable at '${SQLITE3_PATH:-}'" >&2
  exit 1
fi

rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
chmod 700 "${STAGING_DIR}"

# Build the JSON fragments independently, then publish the manifest atomically.
eval_db_json='null'
if [ "${CACHE_EVAL}" = "true" ] && [ -f "${LIVE_DB}" ]; then
  staged_db="${STAGING_DIR}/nix-eval-cache.db"
  "${SQLITE3_PATH}" "${LIVE_DB}" ".backup '$(sql_escape "${staged_db}")'" || {
    echo "devenv-cache-action: sqlite3 .backup failed for devenv eval DB" >&2
    exit 1
  }
  check="$("${SQLITE3_PATH}" "${staged_db}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n')"
  if [ "${check}" != "ok" ]; then
    echo "devenv-cache-action: staged devenv eval DB failed quick_check (${check})" >&2
    rm -f "${staged_db}"
    exit 1
  fi
  eval_bytes="$(wc -c < "${staged_db}" | tr -d ' ')"
  eval_sha="$(sha256_file "${staged_db}")"
  eval_db_json="{\"name\":\"nix-eval-cache.db\",\"sha256\":\"${eval_sha}\",\"bytes\":${eval_bytes}}"
fi

nix_entries=''
nix_count=0
nix_total=0
nix_skipped=0
if [ "${CACHE_NIX_EVAL}" = "true" ]; then
  source_dir="${HOME}/.cache/nix/eval-cache-v6"
  staged_dir="${STAGING_DIR}/nix-eval-cache-v6"
  mkdir -p "${staged_dir}"
  chmod 700 "${staged_dir}"
  if [ -d "${source_dir}" ]; then
    while IFS= read -r source; do
      name="$(basename "${source}")"
      # Nix fingerprint DB names must be simple SQLite filenames. This also blocks traversal.
      if ! printf '%s' "${name}" | grep -qE '^[A-Za-z0-9._-]+\.sqlite$'; then
        echo "devenv-cache-action: skipping unsafe Nix eval-cache filename '${name}'" >&2
        nix_skipped=$((nix_skipped + 1))
        continue
      fi
      if [ "${nix_count}" -ge "${MAX_NIX_EVAL_FILES}" ]; then
        echo "devenv-cache-action: skipping ${name}; maximum ${MAX_NIX_EVAL_FILES} Nix eval-cache DBs staged" >&2
        nix_skipped=$((nix_skipped + 1))
        continue
      fi
      bytes="$(wc -c < "${source}" | tr -d ' ')"
      if [ $((nix_total + bytes)) -gt "${MAX_NIX_EVAL_BYTES}" ]; then
        echo "devenv-cache-action: skipping ${name}; staged Nix eval-cache cap ${MAX_NIX_EVAL_BYTES} bytes would be exceeded" >&2
        nix_skipped=$((nix_skipped + 1))
        continue
      fi
      target="${staged_dir}/${name}"
      "${SQLITE3_PATH}" "${source}" ".backup '$(sql_escape "${target}")'" || {
        echo "devenv-cache-action: skipping ${name}; SQLite online backup failed" >&2
        rm -f "${target}"
        nix_skipped=$((nix_skipped + 1))
        continue
      }
      check="$("${SQLITE3_PATH}" "${target}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n')"
      if [ "${check}" != "ok" ]; then
        echo "devenv-cache-action: skipping ${name}; staged backup failed quick_check (${check})" >&2
        rm -f "${target}"
        nix_skipped=$((nix_skipped + 1))
        continue
      fi
      staged_bytes="$(wc -c < "${target}" | tr -d ' ')"
      if [ $((nix_total + staged_bytes)) -gt "${MAX_NIX_EVAL_BYTES}" ]; then
        echo "devenv-cache-action: skipping ${name}; backup exceeds staged Nix eval-cache cap" >&2
        rm -f "${target}"
        nix_skipped=$((nix_skipped + 1))
        continue
      fi
      sha="$(sha256_file "${target}")"
      entry="{\"name\":\"${name}\",\"sha256\":\"${sha}\",\"bytes\":${staged_bytes}}"
      if [ -n "${nix_entries}" ]; then nix_entries+=','; fi
      nix_entries+="${entry}"
      nix_count=$((nix_count + 1))
      nix_total=$((nix_total + staged_bytes))
    done < <(
      for source in "${source_dir}"/*.sqlite; do
        [ -f "${source}" ] || continue
        printf '%s\t%s\n' "$(stat -c '%Y' "${source}")" "${source}"
      done | sort -rn | cut -f2-
    )
  fi
fi

tmp_manifest="$(mktemp "${STAGING_DIR}/manifest.XXXXXX")"
printf '{"schema":1,"manifestFormat":2,"key":"%s","devenvVersion":"%s","evalDb":%s,"nixEvalFiles":[%s]}' \
  "$(json_escape "${EXPECTED_KEY_BASE}")" "$(json_escape "${DEVENV_VERSION}")" "${eval_db_json}" "${nix_entries}" > "${tmp_manifest}"
mv "${tmp_manifest}" "${MANIFEST}"
echo "devenv-cache-action: snapshot manifest v2 OK (devenv DB: $([ "${eval_db_json}" = null ] && echo no || echo yes), Nix eval DBs: ${nix_count}/${MAX_NIX_EVAL_FILES}, ${nix_total}/${MAX_NIX_EVAL_BYTES} bytes)" >&2
eval_db_status=absent
eval_db_bytes=0
if [ "${eval_db_json}" != null ]; then
  eval_db_status=present
  eval_db_bytes="${eval_bytes}"
fi
staging_total="$(du -sb "${STAGING_DIR}" | cut -f1)"
printf 'devenv-cache-action: stat: devenv-eval-db = %s, %s bytes\n' "${eval_db_status}" "${eval_db_bytes}" >&2
printf 'devenv-cache-action: stat: nix-eval-selected = %s files, %s bytes\n' "${nix_count}" "${nix_total}" >&2
printf 'devenv-cache-action: stat: nix-eval-skipped = %s files\n' "${nix_skipped}" >&2
printf 'devenv-cache-action: stat: staging-total = %s bytes\n' "${staging_total}" >&2
