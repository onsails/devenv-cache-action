#!/usr/bin/env node
// Parses and validates the eval-cache manifest JSON. Dependency-free (node20).
//
// Usage: parse-manifest.js <manifest-path> <expected-key> <expected-devenv-version>
//
// On success: prints "<sha256> <byte-count>" to stdout, exit 0.
// On any validation failure: prints a message to stderr, exit 1.
//
// Checks:
//   - file exists and parses as JSON
//   - schema === 1
//   - action format version (manifestFormat) === 1
//   - key === expected-key
//   - devenvVersion === expected-devenv-version (or both "unknown")
//   - dbSha256 is a 64-hex string
//   - dbBytes is a non-negative integer

"use strict";

const fs = require("fs");

const HEX64 = /^[0-9a-f]{64}$/;

function die(msg) {
  process.stderr.write("devenv-cache-action: " + msg + "\n");
  process.exit(1);
}

const [, , manifestPath, expectedKey, expectedVersion] = process.argv;

if (!manifestPath || !expectedKey) {
  die("parse-manifest: missing arguments (manifest-path expected-key [expected-version])");
}

let raw, m;
try {
  raw = fs.readFileSync(manifestPath, "utf8");
} catch (e) {
  die("manifest not readable: " + e.message);
}
try {
  m = JSON.parse(raw);
} catch (e) {
  die("manifest is not valid JSON: " + e.message);
}

if (m.schema !== 1) die("manifest schema mismatch: expected 1, got " + JSON.stringify(m.schema));
if (m.manifestFormat !== 1)
  die("manifest format mismatch: expected 1, got " + JSON.stringify(m.manifestFormat));
if (m.key !== expectedKey) die("manifest key mismatch");
if ((m.devenvVersion || "unknown") !== (expectedVersion || "unknown"))
  die(
    "manifest devenv version mismatch: expected " +
      (expectedVersion || "unknown") +
      ", got " +
      m.devenvVersion
  );
if (typeof m.dbSha256 !== "string" || !HEX64.test(m.dbSha256))
  die("manifest dbSha256 is not a 64-hex string: " + JSON.stringify(m.dbSha256));
if (typeof m.dbBytes !== "number" || !Number.isInteger(m.dbBytes) || m.dbBytes < 0)
  die("manifest dbBytes is not a non-negative integer: " + JSON.stringify(m.dbBytes));

process.stdout.write(m.dbSha256 + " " + m.dbBytes + "\n");
