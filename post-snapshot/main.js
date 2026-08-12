// post-snapshot/main.js
//
// Registers the post callback. Serializes the validated child inputs as Base64 JSON into
// GITHUB_STATE (key: finalizer-config). This prevents input newlines from causing file-command
// injection in GITHUB_STATE. The post.js callback decodes STATE_finalizer-config and runs
// snapshot-eval-cache.sh without a shell.
//
// No cache or snapshot side effect here — main exists only to register and parameterize the post.
'use strict'

const fs = require('fs')

function input(name) {
  const val = process.env[`INPUT_${name.replace(/ /g, '_').toUpperCase()}`]
  if (val === undefined || val === '') {
    throw new Error(`post-snapshot: missing required input '${name}'`)
  }
  return val
}

const config = {
  workingDirectory: input('working-directory'),
  snapshotScript: input('snapshot-script'),
  stagingDir: input('staging-dir'),
  liveDb: input('live-db'),
  manifest: input('manifest'),
  sqlite3Path: input('sqlite3-path'),
  primaryKey: input('primary-key'),
  keyBase: input('key-base'),
  devenvVersion: input('devenv-version'),
  cacheEval: input('cache-eval')
}

const encoded = Buffer.from(JSON.stringify(config), 'utf8').toString('base64')
const stateFile = process.env.GITHUB_STATE
if (!stateFile) {
  throw new Error('post-snapshot: GITHUB_STATE is not set')
}
fs.appendFileSync(stateFile, `finalizer-config=${encoded}\n`)
