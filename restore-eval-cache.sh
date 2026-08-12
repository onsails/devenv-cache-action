#!/usr/bin/env bash
# Restore validated action-owned SQLite snapshots. This script never copies live WAL/SHM files.
# Inputs: STAGING_DIR MANIFEST LIVE_DB SQLITE3_PATH EXPECTED_KEY DEVENV_VERSION CACHE_EVAL
#         CACHE_NIX_EVAL. Outputs eval-cache-restored, eval-db-path, nix-eval-cache-restored,
#         nix-eval-files-restored.
set -euo pipefail

readonly MAX_NIX_EVAL_FILES=8
readonly MAX_NIX_EVAL_BYTES=$((128 * 1024 * 1024))
out_file="${GITHUB_OUTPUT:-/dev/stdout}"
emit() { printf '%s\n' "$1" >> "$out_file"; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

emit 'eval-cache-restored=false'
emit 'nix-eval-cache-restored=false'
emit 'nix-eval-files-restored=0'

if [ "${CACHE_EVAL}" != 'true' ] && [ "${CACHE_NIX_EVAL}" != 'true' ]; then exit 0; fi
if [ ! -d "${STAGING_DIR}" ] || [ ! -f "${MANIFEST}" ]; then exit 0; fi

# Parse the flat, action-written v2 manifest without an external JSON runtime on the runner PATH.
# Output remains the tab-separated E/N protocol consumed below. Snapshot key/version strings are
# compared in their JSON-escaped form; this accepts the escaping produced by the snapshot writer
# while rejecting malformed JSON string content.
parsed="$(mktemp)"
trap 'rm -f "${parsed}"' EXIT
if ! (
  manifest_json="$(<"${MANIFEST}")"
  [ "$(wc -l < "${MANIFEST}" | tr -d ' ')" = 0 ] || exit 1
  case "${manifest_json}" in *$'\r'*|*$'\n'*) exit 1 ;; esac

  json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
  }
  safe_integer() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    [ "${#1}" -lt 16 ] || {
      [ "${#1}" -eq 16 ] && [ "$1" -le 9007199254740991 ]
    }
  }

  # First validate the outer shape, then extract its scalar fields with grep/sed. The manifest
  # deliberately has no whitespace and strings are limited to JSON's simple escaped form.
  json_string='([^"\\]|\\.)*'
  number='(0|[1-9][0-9]*)'
  outer="^\\{\\\"schema\\\":${number},\\\"manifestFormat\\\":${number},\\\"key\\\":\\\"${json_string}\\\",\\\"devenvVersion\\\":\\\"${json_string}\\\",\\\"evalDb\\\":(null|\\{[^}]*\\}),\\\"nixEvalFiles\\\":\\[.*\\]\\}$"
  [[ "${manifest_json}" =~ ${outer} ]] || exit 1

  m_schema="$(printf '%s' "${manifest_json}" | grep -oE '^\{"schema":(0|[1-9][0-9]*)' | sed 's/.*://')"
  m_format="$(printf '%s' "${manifest_json}" | grep -oE '"manifestFormat":(0|[1-9][0-9]*)' | sed 's/.*://')"
  m_key="${manifest_json#*\"key\":\"}"
  [ "${m_key}" != "${manifest_json}" ] || exit 1
  m_key="${m_key%%\",\"devenvVersion\":*}"
  m_version="${manifest_json#*\"devenvVersion\":\"}"
  [ "${m_version}" != "${manifest_json}" ] || exit 1
  m_version="${m_version%%\",\"evalDb\":*}"
  after_eval="${manifest_json#*\"evalDb\":}"
  [ "${after_eval}" != "${manifest_json}" ] || exit 1
  eval_db="${after_eval%%,\"nixEvalFiles\":*}"
  after_nix="${manifest_json#*\"nixEvalFiles\":[}"
  [ "${after_nix}" != "${manifest_json}" ] || exit 1
  [[ "${after_nix}" == *']}' ]] || exit 1
  nix_entries="${after_nix%%]*}"

  [ "${m_schema}" = 1 ] && [ "${m_format}" = 2 ] || exit 1
  [ "${m_key}" = "$(json_escape "${EXPECTED_KEY}")" ] || exit 1
  [ "${m_version}" = "$(json_escape "${DEVENV_VERSION}")" ] || exit 1
  [ -n "${eval_db}" ] || exit 1

  if [ "${eval_db}" = null ]; then
    printf 'E\t\t\t\n'
  else
    eval_entry="^\\{\\\"name\\\":\\\"(nix-eval-cache\\.db)\\\",\\\"sha256\\\":\\\"([0-9a-f]{64})\\\",\\\"bytes\\\":(${number})\\}$"
    [[ "${eval_db}" =~ ${eval_entry} ]] || exit 1
    eval_name="${BASH_REMATCH[1]}"
    eval_sha="${BASH_REMATCH[2]}"
    eval_bytes="${BASH_REMATCH[3]}"
    safe_integer "${eval_bytes}" || exit 1
    printf 'E\t%s\t%s\t%s\n' "${eval_name}" "${eval_sha}" "${eval_bytes}"
  fi

  nix_entry="^\\{\\\"name\\\":\\\"([A-Za-z0-9._-]+\\.sqlite)\\\",\\\"sha256\\\":\\\"([0-9a-f]{64})\\\",\\\"bytes\\\":(${number})\\}(,?)(.*)$"
  nix_count=0
  nix_total=0
  while [ -n "${nix_entries}" ]; do
    if [[ "${nix_entries}" =~ ${nix_entry} ]]; then
      name="${BASH_REMATCH[1]}"
      sha="${BASH_REMATCH[2]}"
      bytes="${BASH_REMATCH[3]}"
      comma="${BASH_REMATCH[5]}"
      nix_entries="${BASH_REMATCH[6]}"
    else
      exit 1
    fi
    safe_integer "${bytes}" || exit 1
    nix_count=$((nix_count + 1))
    [ "${nix_count}" -le "${MAX_NIX_EVAL_FILES}" ] || exit 1
    [ "${bytes}" -le "${MAX_NIX_EVAL_BYTES}" ] || exit 1
    [ "${nix_total}" -le $((MAX_NIX_EVAL_BYTES - bytes)) ] || exit 1
    nix_total=$((nix_total + bytes))
    printf 'N\t%s\t%s\t%s\n' "${name}" "${sha}" "${bytes}"
    [ -n "${comma}" ] && [ -n "${nix_entries}" ] || [ -z "${comma}" ] && [ -z "${nix_entries}" ] || exit 1
  done
) >"${parsed}"; then
  echo 'devenv-cache-action: invalid snapshot manifest v2; treating cache as a miss' >&2
  exit 0
fi
restored=0

while IFS=$'\t' read -r kind name declared_sha declared_bytes; do
  [ -n "${kind}" ] || continue
  if [ "${kind}" = E ] && [ "${CACHE_EVAL}" = 'true' ] && [ -n "${name}" ]; then
    snapshot="${STAGING_DIR}/${name}"
    [ -f "${snapshot}" ] || continue
    [ "$(wc -c < "${snapshot}" | tr -d ' ')" = "${declared_bytes}" ] || continue
    [ "$(sha256_file "${snapshot}")" = "${declared_sha}" ] || continue
    check="$("${SQLITE3_PATH}" "${snapshot}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n')"
    [ "${check}" = ok ] || continue
    mkdir -p "$(dirname "${LIVE_DB}")"
    rm -f "${LIVE_DB}" "${LIVE_DB}-wal" "${LIVE_DB}-shm"
    cp "${snapshot}" "${LIVE_DB}"
    installed_check="$("${SQLITE3_PATH}" "${LIVE_DB}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n')"
    if [ "${installed_check}" != ok ]; then rm -f "${LIVE_DB}" "${LIVE_DB}-wal" "${LIVE_DB}-shm"; continue; fi
    emit 'eval-cache-restored=true'
    emit "eval-db-path=${LIVE_DB}"
  elif [ "${kind}" = N ] && [ "${CACHE_NIX_EVAL}" = 'true' ]; then
    snapshot="${STAGING_DIR}/nix-eval-cache-v6/${name}"
    [ -f "${snapshot}" ] || continue
    [ "$(wc -c < "${snapshot}" | tr -d ' ')" = "${declared_bytes}" ] || continue
    [ "$(sha256_file "${snapshot}")" = "${declared_sha}" ] || continue
    check="$("${SQLITE3_PATH}" "${snapshot}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n')"
    [ "${check}" = ok ] || continue
    destination="${HOME}/.cache/nix/eval-cache-v6/${name}"
    mkdir -p "$(dirname "${destination}")"
    # A staged online backup is the only source. Replace the DB and every stale live sidecar
    # atomically from the restore operation's perspective; an existing WAL/SHM can otherwise
    # make SQLite attach incompatible pages to the newly copied snapshot.
    rm -f "${destination}" "${destination}-wal" "${destination}-shm"
    cp "${snapshot}" "${destination}"
    installed_check="$("${SQLITE3_PATH}" "${destination}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n')"
    if [ "${installed_check}" != ok ]; then
      rm -f "${destination}" "${destination}-wal" "${destination}-shm"
      continue
    fi
    restored=$((restored + 1))
  fi
done < "${parsed}"

if [ "${restored:-0}" -gt 0 ]; then
  emit 'nix-eval-cache-restored=true'
  emit "nix-eval-files-restored=${restored}"
  echo "devenv-cache-action: restored ${restored} validated Nix eval-cache-v6 DB(s)" >&2
fi
