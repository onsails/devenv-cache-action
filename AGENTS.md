# AGENTS.md

## README example maintenance

- Prefer moving **major** tags (`@vN`) for every action in the README usage example where
  the upstream publishes one:
  - `actions/checkout` — yes (`v7`).
  - `cachix/cachix-action` — yes (`v17`).
  - `onsails/devenv-cache-action` — yes (`v3`).
  - `cachix/install-nix-action` — **no** major tag; pin the latest full tag
    (e.g. `v31.11.0`) and check for a newer one before each release.
- Query tags via the GitHub API, e.g.
  `curl -s https://api.github.com/repos/<owner>/<repo>/tags?per_page=1 | jq -r .[0].name`.
- Before bumping this action's version (cutting a new release):
  1. Update the README example to the latest tags of every action in the example.
  2. After tagging the new release (`vX.Y.Z`), move the major tag to it:
     `git tag -f vX vX.Y.Z^{} && git push -f origin vX`.
