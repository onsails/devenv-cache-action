#!/usr/bin/env bash
# Computes the devenv evaluation cache key and the path list.
# Writes results to $GITHUB_OUTPUT (composite step) or $GITHUB_ENV (standalone test).
#
# Outputs:
#   primary         primary cache key
#   restore         restore-keys prefix list (same version, any digest)
#   devenv-version  resolved devenv version
#   staging-dir     action-owned staging dir under $RUNNER_TEMP for snapshot/manifest
#   live-db         path to the live eval DB inside the working directory
#   staged-db       path the snapshot is written to (staging-dir/nix-eval-cache.db)
#   manifest        path to the manifest JSON (staging-dir/manifest.json)
#   restore-paths   newline list for actions/cache/restore (snapshot dir + ~/.cache/nix)
#   save-paths      newline list for actions/cache/save
set -euo pipefail

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

out_file="${GITHUB_OUTPUT:-/dev/stdout}"

emit() {
  printf '%s\n' "$1" >> "$out_file"
}

emit_multiline() {
  local name="$1" body="$2"
  printf '%s<<EOF\n%s\nEOF\n' "$name" "$body" >> "$out_file"
}

# Resolve the devenv version to embed in the key.
version="${DEVENV_VERSION_INPUT:-}"
if [ -z "$version" ]; then
  # `devenv version` prints e.g. "devenv 2.2.1+8f297ea (x86_64-linux)".
  version="$(devenv version 2>/dev/null | awk 'NR==1 {print $2}')"
fi
[ -n "$version" ] || version=unknown

# Hash the contents of every hash-files entry that exists, plus the working-directory
# realpath: devenv's FileInputDesc records absolute paths, so a DB restored under a
# different checkout path validates nothing and is dead weight.
matched=0
digest_input="$(mktemp)"
trap 'rm -f "$digest_input"' EXIT

wd_real="$(pwd -P)"
printf '%s\n' "$wd_real" >> "$digest_input"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ -f "$f" ]; then
    printf '%s\n' "$f" >> "$digest_input"
    cat "$f" >> "$digest_input"
    matched=$((matched + 1))
  fi
done <<< "${HASH_FILES:-}"

if [ "$matched" -eq 0 ]; then
  echo "devenv-cache-action: none of the hash-files exist in $(pwd)" >&2
  exit 1
fi

digest="$(sha256_stdin < "$digest_input")"
arch="$(uname -m)"
base="${KEY_PREFIX}-${RUNNER_OS}-${arch}-devenv${version}"
primary="${base}-${digest}"
[ -z "${KEY_SUFFIX:-}" ] || primary="${primary}-${KEY_SUFFIX}"

# Staging directory for the snapshot/manifest under $RUNNER_TEMP.
# Mode 0700; created at snapshot time. We only emit the path here.
staging="${RUNNER_TEMP:-/tmp}/devenv-cache-action/${base}-${digest}"

# Live DB lives in the working directory's .devenv/.
live_db="$(pwd -P)/.devenv/nix-eval-cache.db"

# Paths published for actions/cache.
home_cache="$HOME/.cache/nix"
[ -d "$home_cache" ] || mkdir -p "$home_cache"

# cache-nix path list (for restore/save) always includes ~/.cache/nix; the snapshot
# directory is the second path when cache-eval is on. save-paths is built at save
# time after the snapshot exists, but restore must look in the same place.
if [ "${CACHE_EVAL}" = "true" ]; then
  paths="${staging}"$'\n'"${home_cache}"
else
  paths="${home_cache}"
fi

emit "devenv-version=${version}"
emit "primary=${primary}"
emit "key-base=${base}-${digest}"
emit_multiline "restore" "${base}-${digest}-
${base}-"
emit_multiline "paths" "${paths}"
emit "staging-dir=${staging}"
emit "live-db=${live_db}"
emit "staged-db=${staging}/nix-eval-cache.db"
emit "manifest=${staging}/manifest.json"
