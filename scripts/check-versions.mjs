#!/usr/bin/env node
// The published version has one source: the root package.json. Every other
// manifest and the generated NAPI loader must agree with it before a build,
// a pack or a publish. `npm/package.json` is the version npm publishes, the
// Cargo crate version ends up in the binary, and the generated loader refuses
// a platform package whose version differs.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (file) => readFileSync(join(ROOT, file), 'utf8');

function cargoPackageVersion(text, file) {
  let inPackage = false;
  for (const line of text.split(/\r?\n/)) {
    if (/^\[/.test(line)) {
      inPackage = line === '[package]';
      continue;
    }
    const version = inPackage && line.match(/^version\s*=\s*"([^"]+)"/);
    if (version) return version[1];
  }
  return fail(`${file}: [package] has no version`);
}

function lockPackageVersion(text, name, file) {
  const entry = text.match(
    new RegExp(`^\\[\\[package\\]\\]\\nname = "${name}"\\nversion = "([^"]+)"`, 'm'),
  );
  if (!entry) fail(`${file}: no package entry for ${name}`);
  return entry[1];
}

const problems = [];
function fail(message) {
  problems.push(message);
}

const rootPkg = JSON.parse(read('package.json'));
const npmPkg = JSON.parse(read('npm/package.json'));
const expected = rootPkg.version;

function expect(label, actual) {
  if (actual !== expected) fail(`${label}: expected ${expected}, got ${actual}`);
}

expect('npm/package.json version', npmPkg.version);
expect(
  'native/Cargo.toml package version',
  cargoPackageVersion(read('native/Cargo.toml'), 'native/Cargo.toml'),
);
expect(
  'native/Cargo.lock wordcraft-doc-node version',
  lockPackageVersion(read('native/Cargo.lock'), 'wordcraft-doc-node', 'native/Cargo.lock'),
);

const platformPackages = [
  '@lkyhfx/wordcraft-doc-linux-x64-gnu',
  '@lkyhfx/wordcraft-doc-linux-arm64-gnu',
];
const declared = Object.keys(npmPkg.optionalDependencies ?? {}).sort();
if (JSON.stringify(declared) !== JSON.stringify([...platformPackages].sort())) {
  fail(
    `npm/package.json optionalDependencies: expected ${platformPackages.join(', ')}, got ${declared.join(', ') || 'none'}`,
  );
} else {
  for (const name of platformPackages) {
    expect(`optionalDependency ${name}`, npmPkg.optionalDependencies[name]);
  }
}

// The NAPI CLI writes the expected platform-package version into the loader it
// generates, so a mismatch here means index.js came from an older build.
const loader = read('npm/index.js');
const loaderVersions = [...loader.matchAll(/expected ([0-9]+\.[0-9]+\.[0-9]+) but got/g)].map(
  (match) => match[1],
);
if (loaderVersions.length === 0) {
  fail('npm/index.js has no platform-package version check; regenerate it with scripts/build-native.sh');
}
for (const version of new Set(loaderVersions)) {
  expect('npm/index.js platform-package version', version);
}

if (problems.length > 0) {
  console.error('version check failed:');
  for (const problem of problems) console.error(`  ${problem}`);
  console.error(`  bump the root package.json and every copy together (${expected} is the source of truth)`);
  process.exit(1);
}

console.log(`versions consistent: ${expected}`);
