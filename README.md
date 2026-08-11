# devenv-cache-action

Cache devenv's Nix evaluation so ephemeral CI runners skip a full re-evaluation.

A Nix binary cache (Cachix, attic, `cache.nixos.org`) serves **built store paths**. It cannot serve
**evaluation** — the work of resolving your flake inputs and computing the attribute set. Evaluation
results live only in local files, so every fresh container-based, ephemeral, or self-hosted runner
re-evaluates from scratch. This action persists those local files across runs.

## Usage

```yaml
- uses: actions/checkout@v5
- uses: cachix/install-nix-action@v31
- uses: cachix/cachix-action@v16
  with:
    name: devenv
- run: nix profile add nixpkgs#devenv
- uses: onsails/devenv-cache-action@v1
- run: devenv shell -- your-command
```

Pin to a 40-character commit SHA for production workflows:

```yaml
- uses: onsails/devenv-cache-action@<commit-sha> # v1.0.0
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Directory containing `devenv.nix`. |
| `hash-files` | `devenv.nix` `devenv.yaml` `devenv.lock` | Newline-separated files whose contents key the cache. Missing files are skipped; at least one must exist. |
| `extra-paths` | _(none)_ | Newline-separated extra paths to cache, appended to the defaults. Relative paths resolve against `working-directory`; `/`- or `~`-prefixed paths are taken as-is. |
| `key-prefix` | `devenv-eval` | First segment of the cache key. |
| `key-suffix` | _(none)_ | Optional final key segment. Set to `${{ github.run_id }}` to rotate the entry every run when a previously saved cache may be incomplete. |
| `devenv-version` | _(auto-detected)_ | Override the devenv version embedded in the key. |
| `save` | `true` | Set to `false` to restore only and never save (`lookup-only`). |

## Outputs

| Output | Description |
| --- | --- |
| `cache-hit` | `true` when the primary key matched exactly. |
| `primary-key` | The computed primary cache key. |
| `devenv-version` | The devenv version used in the key. |

## What this does not cache

This caches **evaluation only**. Built store paths still come from your substituters (Cachix, attic,
a private binary cache, or `cache.nixos.org`) — a binary cache cannot serve evaluation, which is why
this action exists.

## How the key works

The key is:

```
<prefix>-<os>-<arch>-devenv<version>-<sha256 of hash-files>
```

- `<version>` is detected from `devenv version`, or set with the `devenv-version` input. Embedding
  it avoids restoring a database written by a different release of the evaluator.
- Restore falls back first to any digest for the same devenv version, letting devenv 2.x revalidate
  by content hash and re-evaluate only what changed.

**Partial-cache caveat.** A GitHub Actions cache entry is immutable and first-writer-wins. Because
the key is stable, a cache saved by a job that died mid-evaluation stays partial. Set
`key-suffix: ${{ github.run_id }}` to rotate entries per run.

## License

MIT
