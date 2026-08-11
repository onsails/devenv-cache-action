// post-snapshot/post.js
//
// Decodes STATE_finalizer-config (written by main.js) and runs snapshot-eval-cache.sh without a
// shell. Inherited runner env is augmented with the exact bindings the script needs.
// post-if: success() on the action metadata means this only runs after a successful job.
// Let malformed state, a nonzero exit, or a signal terminate the post action — no catch,
// downgrade, or continue after snapshot failure.
'use strict'

const { execFileSync } = require('child_process')

const raw = process.env.STATE_FINALIZER_CONFIG
if (!raw) {
  throw new Error('post-snapshot: STATE_FINALIZER_CONFIG is not set; main.js did not register the post callback')
}

let config
try {
  config = JSON.parse(Buffer.from(raw, 'base64').toString('utf8'))
} catch (e) {
  throw new Error(`post-snapshot: malformed finalizer-config state: ${e.message}`)
}

for (const key of [
  'workingDirectory',
  'snapshotScript',
  'stagingDir',
  'liveDb',
  'manifest',
  'sqlite3Path',
  'primaryKey',
  'keyBase',
  'devenvVersion',
  'cacheEval'
]) {
  if (typeof config[key] !== 'string' || config[key] === '') {
    throw new Error(`post-snapshot: finalizer-config field '${key}' is missing or not a string`)
  }
}

const env = {
  ...process.env,
  STAGING_DIR: config.stagingDir,
  LIVE_DB: config.liveDb,
  MANIFEST: config.manifest,
  SQLITE3_PATH: config.sqlite3Path,
  EXPECTED_KEY: config.primaryKey,
  EXPECTED_KEY_BASE: config.keyBase,
  DEVENV_VERSION: config.devenvVersion,
  CACHE_EVAL: config.cacheEval
}

// No shell: snapshot-eval-cache.sh is the single argv element, so there is no command surface
// for injection. execFileSync throws on nonzero exit or signal, which propagates as post failure.
execFileSync('bash', [config.snapshotScript], {
  cwd: config.workingDirectory,
  env,
  stdio: 'inherit'
})
