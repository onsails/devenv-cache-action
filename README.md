# devenv-cache-action

Cache devenv's Nix evaluation so ephemeral CI runners skip a full re-evaluation.

A Nix binary cache (Cachix, attic, `cache.nixos.org`) serves **built store paths**. It cannot serve:
**evaluation** — the work of resolving your flake inputs and computing the attribute set. Evaluation
results live only in local files, so every fresh container-based, ephemeral, or self-hosted runner
re-evaluates from scratch.

This action can persist two independently enabled cache classes, in one cache entry:

1. A **validated SQLite snapshot** of devenv's `nix-eval-cache.db` (enabled by default) — taken via
   SQLite's online backup API and integrity-checked at write and read time.
2. An experimental bounded set of **validated SQLite online-backup snapshots** from
   `~/.cache/nix/eval-cache-v6` (opt-in). It selects at most the newest eight `.sqlite` files and
   stages no more than 128 MiB total.

`~/.cache/nix` itself is opt-in: it is not a cache path unless `cache-nix: true` is supplied.

## Usage

One call per job, near the top (after checkout and Nix/binary-cache setup), before the first
`devenv` invocation. The call restores the cache at action main and registers a success-gated
post callback that snapshots the live eval DB after job completion — before the cache post-save
archives it.

```yaml
- uses: actions/checkout@v7
- uses: cachix/install-nix-action@v31.11.0
- uses: cachix/cachix-action@v17
  with:
    name: devenv
- run: nix profile add nixpkgs#devenv

- name: Restore devenv evaluation cache
  id: devenv-cache
  uses: onsails/devenv-cache-action@v3
  with:
    key-suffix: ${{ github.run_id }}
    cache-nix-eval: true

# ... all devenv work ...
```

Pin to a 40-character commit SHA for production workflows.

### How the post-snapshot sequence works

The action restores the cache immediately, then registers two post callbacks in order:

1. The `actions/cache` step (combined restore + save) registers a success-gated post-save.
2. A private nested JavaScript child (`onsails/devenv-cache-action/post-snapshot@<sha>`)
   registers a success-gated post-snapshot finalizer.

   The child is referenced by an explicit `{org}/{repo}/{path}@{sha}` pin, so it appears in job
   logs as a separate action. The shorter `$/post-snapshot` self-repository form is not used: it
   needs a runner feature flag that is not on everywhere, and without it the post step fails
   template validation. `./post-snapshot` is not usable either — a dot-slash reference would
   resolve against your checkout, not this repository.

GitHub Actions runs post steps of referenced actions in **reverse registration order**, so the
finalizer's post runs first — it creates the validated SQLite snapshot in the staging directory —
then the cache post-save archives that directory. The snapshot therefore always exists before the
archive is built. `key-suffix: ${{ github.run_id }}` rotates entries per run so a poisoned cache
from a crashed job never sticks.

The self-test workflow (`seed` → `warm-1` → `warm-2`) proves this ordering twice: the seed's only
snapshot is produced by the finalizer post callback, and each warm job asserts
`eval-cache-restored=true` from it. If the finalizer did not run before the cache save, the first
warm job would see a cache hit with no snapshot.

## Tool prerequisite

The `sqlite3-path` executable must be available **outside** `devenv shell`. The snapshot post
callback runs after the workload and must not rely on `devenv` to evaluate itself just to
snapshot. The resolution order:

1. **PATH lookup** — `command -v sqlite3` (or the `sqlite3-path` input if set).
2. **Nix fallback** — if `sqlite3` is not on PATH but `nix` is, the action creates a wrapper that
   runs `nix run nixpkgs#sqlite-interactive`. This makes it work on GitHub-hosted runners that have
   Nix (via `install-nix-action`) but no system `sqlite3`.
3. **Hard error** — if neither succeeds, the action fails. A silent downgrade hides the
   performance/reliability state.

On self-hosted images, install `sqlite3` directly (`apt-get install -y sqlite3`) for speed; the nix
fallback works but adds a wrapper process.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `working-directory` | `.` | Directory holding `devenv.nix` / `.devenv/`. |
| `hash-files` | `devenv.nix devenv.yaml devenv.lock` | Key inputs; zero matches is a hard error. |
| `key-prefix` | `devenv-eval` | First key segment. |
| `key-suffix` | _(none)_ | e.g. `${{ github.run_id }}`. |
| `devenv-version` | auto | Key isolation across evaluator releases. |
| `cache-nix` | `false` | Include `~/.cache/nix`; excluded from cache paths by default. |
| `cache-eval` | `true` | Include the validated devenv eval-DB snapshot. |
| `cache-nix-eval` | `false` | Experimental: stage at most 8 newest `eval-cache-v6/*.sqlite` online backups, up to 128 MiB. |
| `sqlite3-path` | `sqlite3` | Executable for snapshot and validation; must resolve on PATH. |

## Outputs

| Output | Meaning |
| --- | --- |
| `cache-hit` | `true` when the primary key matched exactly. |
| `primary-key` | The computed primary cache key. |
| `devenv-version` | The devenv version used in the key. |
| `eval-cache-restored` | `true` when a validated devenv DB was installed. |
| `nix-eval-cache-restored` | `true` when one or more validated Nix `eval-cache-v6` DBs were installed. |
| `nix-eval-files-restored` | Number of validated Nix `eval-cache-v6` DBs installed. |
| `eval-db-path` | Path to the installed live devenv eval DB, when restored. |

## How the key works

```
<prefix>-<os>-<arch>-layoutv3-nix<0|1>-eval<0|1>-nixeval<0|1>-devenv<version>-<sha256(hash-files ++ realpath(working-directory))>[-<suffix>]
```

`layoutv3` identifies the archive layout. The three boolean segments name the enabled cache
classes (`cache-nix`, `cache-eval`, and `cache-nix-eval`, respectively). They isolate immutable
entries with incompatible path sets, and prevent prior layouts — including old archives containing
all of `~/.cache/nix` — from matching this action.

The working-directory realpath enters the digest because devenv's `FileInputDesc` records **absolute**
paths; a DB restored under a different checkout path validates nothing and is dead weight. Restore
fallbacks are limited to the **same digest and configuration** (earlier suffixes only), so changed
inputs never restore an incompatible archive.

## What is cached — and what is not

The action caches only action-owned staging snapshots, never live SQLite files. The live devenv
DB (`<working-directory>/.devenv/nix-eval-cache.db`) and Nix's live
`~/.cache/nix/eval-cache-v6/*.sqlite` files are **never** cache paths; live `-wal` and `-shm`
sidecars are never staged or restored. `~/.cache/nix` is included only with `cache-nix: true`.

The experimental Nix eval-cache feature selects the eight newest databases by mtime. Files that
would push the staged total beyond 128 MiB are logged and skipped; they never fail the job.

Removed in v2: `extra-paths` (it was exactly the footgun that caused this bug — it let callers hand
live mutable state to the archiver) and the `save` boolean input.

Removed in v2.1: the `mode` input (`restore`/`save`). The single call now owns both restore and the
success-gated snapshot+save sequence via the nested `post-snapshot` finalizer.
## Integrity gates and recovery


- **Write:** every DB is created with SQLite's online `.backup`, then `PRAGMA quick_check` must
  return `ok`; manifest v2 is atomically published with `key`, `devenvVersion`, and per-file
  `{name, sha256, bytes}` records.
- **Read:** schema/key/version and per-file filename, size, SHA-256, and `quick_check` are validated
  before install. Invalid/missing entries are cache misses and are skipped rather than failing the
  job. Only validated snapshot files are copied; WAL/SHM files are never copied.
- **Recovery:** a cache entry is immutable and first-writer-wins. A corrupted snapshot is ignored
  and the job evaluates normally; rotate the key with `key-suffix` to force a fresh entry.

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
- [`actions/cache`](https://github.com/actions/cache)

## License

MIT
