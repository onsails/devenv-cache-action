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
# A snapshot can outlive the runner's Nix store while every referenced path remains available
# from a configured binary cache. Hydrate exact store objects only — never realise derivations
# and never build — then re-check validity; any failure falls back to the fail-closed skip.
hydrate_store_paths() {
  local paths="$1"
  local missing path substituters substituter

  if xargs -n 128 nix-store --check-validity <"${paths}" >/dev/null 2>&1; then return 0; fi
  command -v nix >/dev/null 2>&1 || return 1
  substituters="$(nix config show substituters 2>/dev/null)" || return 1
  substituters="${substituters#substituters = }"
  [ -n "${substituters}" ] || return 1

  missing="$(mktemp)"
  while IFS= read -r path; do
    nix-store --check-validity "${path}" >/dev/null 2>&1 || printf '%s\n' "${path}" >>"${missing}"
  done <"${paths}"
  if [ ! -s "${missing}" ]; then rm -f "${missing}"; return 0; fi

  for substituter in ${substituters}; do
    if xargs -n 16 nix copy --from "${substituter}" -- <"${missing}" >/dev/null 2>&1 \
      && xargs -n 128 nix-store --check-validity <"${missing}" >/dev/null 2>&1; then
      rm -f "${missing}"
      echo "devenv-cache-action: hydrated ${substituter} store paths referenced by the snapshot" >&2
      return 0
    fi
  done
  rm -f "${missing}"
  return 1
}
# Evaluation outputs can embed absolute store paths and typed Nix string contexts. Validate every
# staged candidate against the local store before replacing any live database.
store_references_valid() {
  local snapshot="$1" kind="$2"
  local work text contexts refs drvs closure closure_sorted context token suffix status
  local saw_output_prefix
  local store_hash='[0123456789abcdfghijklmnpqrsvwxyz]{32}'
  local store_name='[A-Za-z0-9+._?=-]+'
  local store_path_re="/nix/store/${store_hash}-${store_name}"
  local store_basename_re="${store_hash}-${store_name}"

  command -v nix-store >/dev/null 2>&1 || return 1
  work="$(mktemp -d)" || return 1
  text="${work}/text"; contexts="${work}/contexts"; refs="${work}/refs"
  drvs="${work}/drvs"; closure="${work}/closure"; closure_sorted="${work}/closure-sorted"

  if [ "${kind}" = E ]; then
    if ! "${SQLITE3_PATH}" "${snapshot}" \
      'SELECT json_output FROM cached_eval UNION ALL SELECT spec FROM eval_resource_spec;' \
      >"${text}" 2>/dev/null; then
      rm -rf "${work}"; return 1
    fi
    : >"${contexts}"
  elif [ "${kind}" = N ]; then
    if ! "${SQLITE3_PATH}" "${snapshot}" \
      'SELECT value FROM Attributes WHERE value IS NOT NULL;' >"${text}" 2>/dev/null \
      || ! "${SQLITE3_PATH}" "${snapshot}" \
        'SELECT context FROM Attributes WHERE context IS NOT NULL;' >"${contexts}" 2>/dev/null; then
      rm -rf "${work}"; return 1
    fi
  else
    rm -rf "${work}"; return 1
  fi

  status=0
  grep -oE "${store_path_re}" "${text}" >"${refs}" || status=$?
  [ "${status}" -le 1 ] || { rm -rf "${work}"; return 1; }
  while IFS= read -r context || [ -n "${context}" ]; do
    read -r -a context_tokens <<<"${context}"
    for token in "${context_tokens[@]}"; do
      suffix="${token}"
      saw_output_prefix=false
      while [[ "${suffix}" =~ ^!([A-Za-z0-9+._?=-]+)!(.*)$ ]]; do
        saw_output_prefix=true
        suffix="${BASH_REMATCH[2]}"
      done
      if [ "${saw_output_prefix}" = true ]; then
        [[ "${suffix}" =~ ^${store_basename_re}\.drv$ ]] \
          || { rm -rf "${work}"; return 1; }
        printf '/nix/store/%s\n' "${suffix}" >>"${refs}"
      elif [[ "${suffix}" =~ ^${store_path_re}$ ]]; then
        printf '%s\n' "${suffix}" >>"${refs}"
      elif [[ "${suffix}" =~ ^=(${store_basename_re}\.drv)$ ]]; then
        printf '/nix/store/%s\n' "${BASH_REMATCH[1]}" >>"${refs}"
      elif [[ "${suffix}" =~ ^@(${store_basename_re})$ ]]; then
        printf '/nix/store/%s\n' "${BASH_REMATCH[1]}" >>"${refs}"
      else
        rm -rf "${work}"; return 1
      fi
    done
  done <"${contexts}"

  sort -u -o "${refs}" "${refs}" || { rm -rf "${work}"; return 1; }
  if [ -s "${refs}" ] \
    && ! hydrate_store_paths "${refs}"; then
    rm -rf "${work}"; return 1
  fi
  status=0
  grep -E '\.drv$' "${refs}" >"${drvs}" || status=$?
  if [ "${status}" -gt 1 ]; then rm -rf "${work}"; return 1; fi
  if [ -s "${drvs}" ]; then
    if ! xargs -n 128 nix-store --query --requisites <"${drvs}" >"${closure}" 2>/dev/null \
      || [ ! -s "${closure}" ] \
      || grep -Eqv "^${store_path_re}$" "${closure}" \
      || ! sort -u "${closure}" >"${closure_sorted}" \
      || [ -n "$(comm -23 "${drvs}" "${closure_sorted}")" ]; then
      rm -rf "${work}"; return 1
    fi
    if ! hydrate_store_paths "${closure_sorted}"; then
      rm -rf "${work}"; return 1
    fi
  fi
  rm -rf "${work}"
}

sqlite_valid() {
  local check
  check="$("${SQLITE3_PATH}" "$1" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n')" || return 1
  [ "${check}" = ok ]
}

install_snapshot() {
  local snapshot="$1" destination="$2" install_tmp
  mkdir -p "$(dirname "${destination}")" || return 1
  install_tmp="$(mktemp "${destination}.restore.XXXXXX")" || return 1
  if ! cp "${snapshot}" "${install_tmp}" || ! sqlite_valid "${install_tmp}"; then
    rm -f "${install_tmp}"; return 1
  fi
  if ! rm -f "${destination}-wal" "${destination}-shm"; then
    rm -f "${install_tmp}"; return 1
  fi
  mv -f "${install_tmp}" "${destination}"
}

emit 'eval-cache-restored=false'
emit 'nix-eval-cache-restored=false'
emit 'nix-eval-files-restored=0'

if [ "${CACHE_EVAL}" != 'true' ] && [ "${CACHE_NIX_EVAL}" != 'true' ]; then exit 0; fi
eval_restored=false
nix_restored=0
nix_restored_bytes=0
emit_stats() {
  printf 'devenv-cache-action: stat: devenv-eval-db-restored = %s\n' "${eval_restored}" >&2
  printf 'devenv-cache-action: stat: nix-eval-restored = %s files, %s bytes\n' "${nix_restored}" "${nix_restored_bytes}" >&2
}
if [ ! -d "${STAGING_DIR}" ] || [ ! -f "${MANIFEST}" ]; then
  emit_stats
  exit 0
fi

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
    # After a comma, more entries must follow; after the last entry, no comma and no remaining entries.
    if [ -n "${comma}" ]; then [ -n "${nix_entries}" ] || exit 1; else [ -z "${nix_entries}" ] || exit 1; fi
  done
) >"${parsed}"; then
  echo 'devenv-cache-action: invalid snapshot manifest v2; treating cache as a miss' >&2
  emit_stats
  exit 0
fi
restored=0
restored_bytes=0

while IFS=$'\t' read -r kind name declared_sha declared_bytes; do
  [ -n "${kind}" ] || continue
  if [ "${kind}" = E ] && [ "${CACHE_EVAL}" = 'true' ] && [ -n "${name}" ]; then
    snapshot="${STAGING_DIR}/${name}"
    [ -f "${snapshot}" ] || continue
    [ "$(wc -c < "${snapshot}" | tr -d ' ')" = "${declared_bytes}" ] || continue
    [ "$(sha256_file "${snapshot}")" = "${declared_sha}" ] || continue
    sqlite_valid "${snapshot}" || continue
    if ! store_references_valid "${snapshot}" E; then
      echo 'devenv-cache-action: skipping devenv eval DB; cached Nix store closure is invalid' >&2
      continue
    fi
    if ! install_snapshot "${snapshot}" "${LIVE_DB}"; then
      echo 'devenv-cache-action: skipping devenv eval DB; installation failed' >&2
      continue
    fi
    emit 'eval-cache-restored=true'
    emit "eval-db-path=${LIVE_DB}"
    eval_restored=true
  elif [ "${kind}" = N ] && [ "${CACHE_NIX_EVAL}" = 'true' ]; then
    snapshot="${STAGING_DIR}/nix-eval-cache-v6/${name}"
    [ -f "${snapshot}" ] || continue
    [ "$(wc -c < "${snapshot}" | tr -d ' ')" = "${declared_bytes}" ] || continue
    [ "$(sha256_file "${snapshot}")" = "${declared_sha}" ] || continue
    sqlite_valid "${snapshot}" || continue
    if ! store_references_valid "${snapshot}" N; then
      echo "devenv-cache-action: skipping ${name}; cached Nix store closure is invalid" >&2
      continue
    fi
    destination="${HOME}/.cache/nix/eval-cache-v6/${name}"
    if ! install_snapshot "${snapshot}" "${destination}"; then
      echo "devenv-cache-action: skipping ${name}; installation failed" >&2
      continue
    fi
    restored=$((restored + 1))
    restored_bytes=$((restored_bytes + declared_bytes))
  fi
done < "${parsed}"

nix_restored="${restored}"
nix_restored_bytes="${restored_bytes}"
emit_stats
if [ "${restored:-0}" -gt 0 ]; then
  emit 'nix-eval-cache-restored=true'
  emit "nix-eval-files-restored=${restored}"
  echo "devenv-cache-action: restored ${restored} validated Nix eval-cache-v6 DB(s)" >&2
fi
