# devenv-cache-action

Cache devenv's Nix evaluation so ephemeral CI runners skip a full re-evaluation.

A Nix binary cache (Cachix, attic, `cache.nixos.org`) serves **built store paths**. It cannot serve
**evaluation** — the work of resolving your flake inputs and computing the attribute set. Evaluation
results live only in local files, so every fresh container-based, ephemeral, or self-hosted runner
re-evaluates from scratch.

This action persists two things, as one cache entry:

1. `~/.cache/nix` — Nix's own flake/eval/fetcher caches.
2. A **validated SQLite snapshot** of devenv's `nix-eval-cache.db` — taken via SQLite's online backup
   API, integrity-checked at write and read time, and restored only when its content digest matches.

## Usage

Two calls per job: **restore** at the top (after checkout and Nix/binary-cache setup), **save** as the
final successful step (after the last `devenv` invocation).

```yaml
- uses: actions/checkout@v5
- uses: cachix/install-nix-action@v31
- uses: cachix/cachix-action@v16
  with:
    name: devenv
- run: nix profile add nixpkgs#devenv

- name: Restore devenv evaluation cache
  id: devenv-cache
  uses: onsails/devenv-cache-action@<commit-sha> # v2.0.0
  with:
    mode: restore

# ... all devenv work ...

- name: Save devenv evaluation cache
  if: ${{ success() }}
  uses: onsails/devenv-cache-action@<commit-sha> # v2.0.0
  with:
    mode: save
    key-suffix: ${{ github.run_id }}
```

Pin to a 40-character commit SHA for production workflows.

### Why two calls?

`actions/cache` registers its save as a **job post action** that runs after every step. A composite
action cannot run a step after that (composite actions have no `post:` hook). So the snapshot — which
must be taken *after* all devenv work — can never be sequenced before the archive while a single
combined call owns the save. Splitting into explicit `mode: restore` + `mode: save` is the supported,
deterministic shape.

## Tool prerequisite

The `sqlite3-path` executable must be on PATH **outside** `devenv shell`. The save step runs after
the workload and must not rely on `devenv` to evaluate itself just to snapshot. Absence is a **hard
error**: a silent downgrade hides the performance/reliability state. On Ubuntu runners, install
`sqlite3` in your image or add `apt-get install -y sqlite3` to setup.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `mode` | _(required)_ | `restore` or `save`. Anything else is a hard error. |
| `working-directory` | `.` | Directory holding `devenv.nix` / `.devenv/`. |
| `hash-files` | `devenv.nix devenv.yaml devenv.lock` | Key inputs; zero matches is a hard error. |
| `key-prefix` | `devenv-eval` | First key segment. |
| `key-suffix` | _(none)_ | e.g. `${{ github.run_id }}`. |
| `devenv-version` | auto | Key isolation across evaluator releases. |
| `cache-nix` | `true` | Include `~/.cache/nix`. |
| `cache-eval` | `true` | Include the eval-DB snapshot. |
| `sqlite3-path` | `sqlite3` | Executable for snapshot and validation; must resolve on PATH. |

## Outputs

| Output | Meaning |
| --- | --- |
| `cache-hit` | `true` when the primary key matched exactly. |
| `primary-key` | The computed primary cache key. |
| `devenv-version` | The devenv version used in the key. |
| `eval-cache-restored` | `true` when a validated DB was installed. |
| `eval-db-path` | Path to the installed live eval DB, when restored. |

## How the key works

```
<prefix>-<os>-<arch>-devenv<version>-<sha256(hash-files ++ realpath(working-directory))>[-<suffix>]
```

The working-directory realpath enters the digest because devenv's `FileInputDesc` records **absolute**
paths; a DB restored under a different checkout path validates nothing and is dead weight. Restore
falls back to any digest for the same devenv version, letting devenv 2.x revalidate by content hash
and re-evaluate only what changed.

## What is cached — and what is not

The action caches a **validated snapshot**, not `.devenv/`. The live DB (`<working-directory>/.devenv/nix-eval-cache.db`) is **never** a cache path. `.devenv/` as a whole is unsafe to archive: it holds gc-root/profile
symlinks into a store a fresh runner lacks. Only the single DB file crosses the cache boundary, and
only as a SQLite online-backup snapshot.

Removed in v2: `extra-paths` (it was exactly the footgun that caused this bug — it let callers hand
live mutable state to the archiver) and the `save` boolean input (subsumed by `mode`).

## Integrity gates and recovery

- **Write:** snapshot via `sqlite3 <live> ".backup '<staged>'"` → `PRAGMA quick_check` must return
  `ok` → SHA-256 + byte count written to a manifest atomically (`mktemp` + `mv`).
- **Read:** manifest parsed and validated (schema, key, version, digest shape) → `quick_check` on the
  restored snapshot → digest must match the manifest → `quick_check` on the installed copy. Any
  failure fails hard before devenv opens the DB.
- **Recovery:** a cache entry is immutable and first-writer-wins. An invalid snapshot causes a hard
  action failure *before* devenv; rotate the key with `key-suffix` to escape a bad entry.

### Why not just tarball the live DB?

`actions/cache` tarballs files as-is. The eval DB runs in **WAL mode** (`pragma journal_mode` →
`wal`, with live `-wal` / `-shm` sidecars). A tarball taken while a writer is live — or from a job
that died mid-evaluation — restores a torn database, and devenv aborts (exit 11) instead of falling
back to a full evaluation. The online-backup snapshot is the fix: a consistent, closed file produced
while the source is unchanged.

## Primary sources

- [SQLite online backup API](https://sqlite.org/backup.html)
- [SQLite WAL semantics](https://sqlite.org/wal.html)
- [SQLite `VACUUM INTO`](https://sqlite.org/lang_vacuum.html) (diagnostic fallback)
- [`actions/cache/save`](https://github.com/actions/cache/tree/main/save)

## License

MIT
