#!/usr/bin/env bash
#
# Guards the nested finalizer pin in action.yml.
#
# action.yml must reference post-snapshot/ as onsails/devenv-cache-action/post-snapshot@<sha>.
# GitHub resolves that pin against the remote repository at <sha>, NOT against the working
# checkout, so a stale pin silently ships old finalizer code to every consumer while local
# tests exercise the new code.
#
# This check fails when the pinned commit's post-snapshot/ tree differs from HEAD's.
#
# Requires full history: actions/checkout with fetch-depth: 0.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

action_yml="action.yml"
expected_repo="onsails/devenv-cache-action"
expected_path="post-snapshot"

# 1. The forbidden self-repository form must not come back before the runner flag is default.
if grep -nE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*\$/' "$action_yml"; then
  echo "FAIL: action.yml uses the '\$/' self-repository form." >&2
  echo "      It is gated behind the actions_dollar_self_reference feature flag and breaks" >&2
  echo "      template validation on runners without it. Use the explicit pin instead." >&2
  exit 1
fi

# 2. Extract the pin.
pin_line="$(grep -nE "uses:[[:space:]]*${expected_repo}/${expected_path}@" "$action_yml" || true)"
if [ -z "$pin_line" ]; then
  echo "FAIL: no '${expected_repo}/${expected_path}@<sha>' reference found in ${action_yml}." >&2
  exit 1
fi
if [ "$(printf '%s\n' "$pin_line" | wc -l)" -ne 1 ]; then
  echo "FAIL: expected exactly one ${expected_path} reference in ${action_yml}, found:" >&2
  printf '%s\n' "$pin_line" >&2
  exit 1
fi

pinned_sha="$(printf '%s\n' "$pin_line" | sed -E "s#.*${expected_repo}/${expected_path}@([0-9a-fA-F]+).*#\1#")"
if ! printf '%s' "$pinned_sha" | grep -qE '^[0-9a-f]{40}$'; then
  echo "FAIL: ${expected_path} must be pinned to a full 40-character lowercase commit SHA." >&2
  echo "      Found: '${pinned_sha}' on ${pin_line%%:*}." >&2
  exit 1
fi

# 3. The pinned commit must exist locally.
if ! git rev-parse --verify --quiet "${pinned_sha}^{commit}" >/dev/null; then
  echo "FAIL: pinned commit ${pinned_sha} is not in this repository's history." >&2
  echo "      Either it was never pushed, or the checkout is shallow (need fetch-depth: 0)." >&2
  exit 1
fi

# 4. Tree equality is the real assertion: pinned code == working code.
head_tree="$(git rev-parse "HEAD:${expected_path}")"
pinned_tree="$(git rev-parse "${pinned_sha}:${expected_path}" 2>/dev/null || true)"

if [ -z "$pinned_tree" ]; then
  echo "FAIL: commit ${pinned_sha} has no ${expected_path}/ directory." >&2
  exit 1
fi

if [ "$head_tree" != "$pinned_tree" ]; then
  echo "FAIL: ${expected_path}/ pin is stale." >&2
  echo "      HEAD   ${expected_path}/ tree: ${head_tree}" >&2
  echo "      pinned ${expected_path}/ tree: ${pinned_tree} (commit ${pinned_sha})" >&2
  echo >&2
  echo "      Consumers would run the OLD finalizer. Fix with the two-step release in AGENTS.md:" >&2
  echo "        1. push the ${expected_path}/ change (this check fails on that commit — expected)," >&2
  echo "        2. update the pin in ${action_yml} to that commit SHA and push again." >&2
  git --no-pager diff --stat "${pinned_sha}" HEAD -- "${expected_path}" >&2 || true
  exit 1
fi

echo "OK: ${expected_repo}/${expected_path}@${pinned_sha} matches HEAD tree ${head_tree}."
