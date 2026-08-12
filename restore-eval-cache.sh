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

# Parse and validate JSON structurally using the runner-provided Node runtime. Its output is a
# tab-separated, fixed-field protocol; file names are rejected unless safe before shell consumes it.
parsed="$(mktemp)"
trap 'rm -f "${parsed}"' EXIT
if ! MANIFEST="${MANIFEST}" EXPECTED_KEY="${EXPECTED_KEY}" DEVENV_VERSION="${DEVENV_VERSION}" \
  MAX_NIX_EVAL_FILES_VALUE="${MAX_NIX_EVAL_FILES}" MAX_NIX_EVAL_BYTES_VALUE="${MAX_NIX_EVAL_BYTES}" node <<'NODE' >"${parsed}"
'use strict'
const fs = require('fs')
try {
  const m = JSON.parse(fs.readFileSync(process.env.MANIFEST, 'utf8'))
  const fail = () => process.exit(1)
  if (m.schema !== 1 || m.manifestFormat !== 2 || m.key !== process.env.EXPECTED_KEY ||
      m.devenvVersion !== process.env.DEVENV_VERSION || !Array.isArray(m.nixEvalFiles)) fail()
  const safeNixName = /^[A-Za-z0-9._-]+\.sqlite$/
  const valid = (x, nameTest) => x && typeof x.name === 'string' && nameTest.test(x.name) &&
    typeof x.sha256 === 'string' && /^[0-9a-f]{64}$/.test(x.sha256) &&
    Number.isSafeInteger(x.bytes) && x.bytes >= 0
  if (m.evalDb !== null && !valid(m.evalDb, /^nix-eval-cache\.db$/)) fail()
  if (m.nixEvalFiles.length > Number(process.env.MAX_NIX_EVAL_FILES_VALUE) ||
      !m.nixEvalFiles.every(x => valid(x, safeNixName))) fail()
  const total = m.nixEvalFiles.reduce((sum, x) => sum + x.bytes, 0)
  if (!Number.isSafeInteger(total) || total > Number(process.env.MAX_NIX_EVAL_BYTES_VALUE)) fail()
  process.stdout.write(`E\t${m.evalDb ? m.evalDb.name : ''}\t${m.evalDb ? m.evalDb.sha256 : ''}\t${m.evalDb ? m.evalDb.bytes : ''}\n`)
  for (const x of m.nixEvalFiles) process.stdout.write(`N\t${x.name}\t${x.sha256}\t${x.bytes}\n`)
} catch { process.exit(1) }
NODE
then
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
    # A staged online backup is the only source. Never restore archived WAL/SHM sidecars.
    cp "${snapshot}" "${destination}"
    installed_check="$("${SQLITE3_PATH}" "${destination}" 'PRAGMA quick_check;' 2>/dev/null | tr -d '\n')"
    if [ "${installed_check}" != ok ]; then rm -f "${destination}"; continue; fi
    restored=$((restored + 1))
  fi
done < "${parsed}"

if [ "${restored:-0}" -gt 0 ]; then
  emit 'nix-eval-cache-restored=true'
  emit "nix-eval-files-restored=${restored}"
  echo "devenv-cache-action: restored ${restored} validated Nix eval-cache-v6 DB(s)" >&2
fi
