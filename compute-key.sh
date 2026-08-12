#!/usr/bin/env bash
# Computes the devenv evaluation cache key and the path list.
# Writes results to $GITHUB_OUTPUT (composite step) or $GITHUB_ENV (standalone test).
#
# Outputs:
#   primary         primary cache key
#   key-base        layout/configuration/digest key without optional suffix
#   restore         restore-keys prefix list (same digest, earlier suffixes only)
#   devenv-version  resolved devenv version
#   staging-dir     action-owned staging dir under $RUNNER_TEMP for snapshots/manifests
#   live-db         path to the live devenv eval DB inside the working directory
#   manifest        path to the manifest JSON (staging-dir/manifest.json)
#   paths           newline list for actions/cache; excludes disabled cache classes
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

# Cache archives are immutable and actions/cache restores their contents directly. Keep every
# archive layout and enabled cache class in this namespace so a legacy whole ~/.cache/nix archive
# — or a cache created with a different class combination — cannot be restored here.
cache_bool() {
  case "$2" in
    true) printf '1' ;;
    false) printf '0' ;;
    *) echo "devenv-cache-action: $1 must be 'true' or 'false', got '$2'" >&2; exit 1 ;;
  esac
}
cache_nix="$(cache_bool cache-nix "${CACHE_NIX:-false}")"
cache_eval="$(cache_bool cache-eval "${CACHE_EVAL:-true}")"
cache_nix_eval="$(cache_bool cache-nix-eval "${CACHE_NIX_EVAL:-false}")"
base="${KEY_PREFIX}-${RUNNER_OS}-${arch}-layoutv3-nix${cache_nix}-eval${cache_eval}-nixeval${cache_nix_eval}-devenv${version}"
key_base="${base}-${digest}"
primary="${key_base}"
[ -z "${KEY_SUFFIX:-}" ] || primary="${primary}-${KEY_SUFFIX}"

# Staging directory for the snapshot/manifest under $RUNNER_TEMP.
# Mode 0700; created at snapshot time. We only emit the path here.
staging="${RUNNER_TEMP:-/tmp}/devenv-cache-action/${key_base}"

# Live DB lives in the working directory's .devenv/.
live_db="$(pwd -P)/.devenv/nix-eval-cache.db"

# Paths published for actions/cache. The action-owned staging directory is needed for either
# validated SQLite snapshot feature; ~/.cache/nix is included only when explicitly requested.
paths=''
if [ "${cache_eval}" = "1" ] || [ "${cache_nix_eval}" = "1" ]; then
  paths="${staging}"
fi
if [ "${cache_nix}" = "1" ]; then
  home_cache="$HOME/.cache/nix"
  [ -d "$home_cache" ] || mkdir -p "$home_cache"
  if [ -n "$paths" ]; then
    paths+=$'\n'
  fi
  paths+="${home_cache}"
fi
[ -n "$paths" ] || { echo "devenv-cache-action: all cache classes are disabled" >&2; exit 1; }

emit "devenv-version=${version}"
emit "primary=${primary}"
emit "key-base=${key_base}"
emit_multiline "restore" "${key_base}-"
emit_multiline "paths" "${paths}"
emit "staging-dir=${staging}"
emit "live-db=${live_db}"
emit "staged-db=${staging}/nix-eval-cache.db"
emit "manifest=${staging}/manifest.json"
