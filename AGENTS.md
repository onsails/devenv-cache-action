# AGENTS.md

## README example maintenance

- Always check the latest released tags of every action referenced in the README usage
  example before editing or releasing:
  - `actions/checkout`
  - `cachix/install-nix-action`
  - `cachix/cachix-action`
  - `onsails/devenv-cache-action`
- Query tags via the GitHub API, e.g.
  `curl -s https://api.github.com/repos/<owner>/<repo>/tags?per_page=1 | jq -r .[0].name`.
- Before bumping this action's version (cutting a new release), first update the README
  example to the latest published tag of `onsails/devenv-cache-action` and of every other
  action in the example.
