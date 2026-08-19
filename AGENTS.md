# AGENTS.md

## post-snapshot pin — MUST stay fresh

`action.yml` references the nested finalizer as
`onsails/devenv-cache-action/post-snapshot@<40-char-sha>`. GitHub resolves that pin against the
**remote** repository at that SHA, never against the caller's checkout. A stale pin therefore
ships old finalizer code to every consumer while local CI still exercises the new code.

- Never use `uses: $/post-snapshot`. The `$/` self-repository syntax is real
  (actions/runner#4457) but is gated behind the `actions_dollar_self_reference` feature flag.
  Runners without the flag — self-hosted ones in particular — fail template validation with
  `Expected format {org}/{repo}[/path]@ref`, which killed the post step in v3.0.0.
  Switch to `$/post-snapshot` only after the flag is on by default everywhere.
- Never use `uses: ./post-snapshot`. A dot-slash reference resolves against the caller's
  workspace, not this repository.
- `tests/check-post-snapshot-pin.sh` enforces this. CI runs it in the `post-snapshot-pin` job
  with `fetch-depth: 0`. Run it locally after any change under `post-snapshot/`.

### Two-step release when `post-snapshot/` changes

The pin cannot name a commit that does not exist yet, so the update takes two commits:

1. Commit and push the `post-snapshot/` change. The `post-snapshot-pin` job fails on this
   commit — expected.
2. Set the pin in `action.yml` to the SHA from step 1, commit, push. The job must go green
   before any tag is cut.

Never tag a release while the pin check is red.

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
  2. Verify `./tests/check-post-snapshot-pin.sh` passes; if it fails, do the two-step
     release above first.
  3. After tagging the new release (`vX.Y.Z`), move the major tag to it:
     `git tag -f vX vX.Y.Z^{} && git push -f origin vX`.
