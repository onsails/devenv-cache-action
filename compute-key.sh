#!/usr/bin/env bash
# Computes the devenv evaluation cache key and the path list, then writes them to $GITHUB_OUTPUT.
set -euo pipefail

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Resolve the devenv version to embed in the key.
version="${DEVENV_VERSION_INPUT:-}"
if [ -z "$version" ]; then
  # `devenv version` prints e.g. "devenv 2.2.1+8f297ea (x86_64-linux)".
  version="$(devenv version 2>/dev/null | awk 'NR==1 {print $2}')"
fi
[ -n "$version" ] || version=unknown

# Hash the contents of every hash-files entry that exists.
matched=0
digest_input="$(mktemp)"
trap 'rm -f "$digest_input"' EXIT
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

# Build the path list actions/cache will archive.
# Defaults: Nix's own caches + devenv's evaluation database (NOT the whole .devenv/,
# which holds gc-root/profile symlinks into a store a fresh runner lacks).
paths=""
add_path() {
  local p="$1"
  if [ -z "$paths" ]; then
    paths="$p"
  else
    paths="${paths}"$'\n'"${p}"
  fi
}

home_cache="$HOME/.cache/nix"
[ -d "$home_cache" ] || mkdir -p "$home_cache"
add_path "$home_cache"

# NOTE: .devenv/nix-eval-cache.db is deliberately NOT cached by default.
# actions/cache tarballs files as-is; a SQLite DB written under WAL mode or
# by a process that died mid-evaluation is restored malformed, and devenv
# crashes hard (error code 11) instead of falling back to full evaluation.
# Consumers who want to risk it can opt in via extra-paths.

# Append caller-provided extra paths, resolving them against the working directory.
while IFS= read -r ep; do
  [ -n "$ep" ] || continue
  case "$ep" in
    /*|~/*)
      add_path "$ep"
      ;;
    *)
      add_path "$(pwd)/${ep}"
      ;;
  esac
done <<< "${EXTRA_PATHS:-}"

{
  printf 'devenv-version=%s\n' "$version"
  printf 'primary=%s\n' "$primary"
  printf 'restore<<EOF\n%s-%s-\n%s-\nEOF\n' "$base" "$digest" "$base"
  printf 'paths<<EOF\n%s\nEOF\n' "$paths"
} >> "$GITHUB_OUTPUT"
