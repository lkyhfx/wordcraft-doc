#!/usr/bin/env bash
# Verify the packed npm packages the way a real user would: install the tarballs
# into an empty project and convert a document.
#
# This is the check that catches problems the source tree hides — a missing
# file in `files`, an optionalDependency npm cannot resolve, a path that leaks
# out of the package, types that stopped compiling.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/npm-dist"
VERSION="$(node -p "require('$ROOT/npm/package.json').version")"
export npm_config_cache="${npm_config_cache:-$ROOT/.dev/npm-cache}"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAILED:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$DIST" ]] || fail "no $DIST; run scripts/package-native.sh first"
shopt -s nullglob
tarballs=("$DIST"/*.tgz)
shopt -u nullglob
[[ ${#tarballs[@]} -ge 3 ]] || fail "expected at least 3 tarballs in $DIST, found ${#tarballs[@]}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

say "==> creating a clean consumer project"
npm init -y >/dev/null

say "==> installing the tarballs by name (so optionalDependencies resolve)"
# Installing the local tarballs for all three packages mirrors `npm install
# @lkyhfx/wordcraft-doc`: the main package plus the platform package for the
# current architecture.
arch_suffix="$(node -p "process.arch === 'arm64' ? 'linux-arm64-gnu' : 'linux-x64-gnu'")"
main_tar="$DIST/lkyhfx-wordcraft-doc-$VERSION.tgz"
plat_tar="$DIST/lkyhfx-wordcraft-doc-$arch_suffix-$VERSION.tgz"
[[ -f "$main_tar" ]] || fail "missing $main_tar"
[[ -f "$plat_tar" ]] || fail "missing $plat_tar"

npm install --no-audit --no-fund "$plat_tar" "$main_tar" >/dev/null

installed="$WORK/node_modules/@lkyhfx/wordcraft-doc"
[[ -d "$installed" ]] || fail "the main package did not install at $installed"
[[ -f "$WORK/node_modules/@lkyhfx/wordcraft-doc-$arch_suffix/package.json" ]] ||
  fail "the platform package did not install"

say "==> checking what the packages actually contain"
node - "$installed" "$arch_suffix" <<'JS'
const { readdirSync, statSync } = require('node:fs');
const { join, relative } = require('node:path');
const [dir, suffix] = process.argv.slice(2);

function walk(root, current = root) {
  const out = [];
  for (const name of readdirSync(current)) {
    const full = join(current, name);
    if (statSync(full).isDirectory()) out.push(...walk(root, full));
    else out.push(relative(root, full));
  }
  return out;
}

const files = walk(dir).sort();
console.log('main package files:');
for (const file of files) console.log('   ', file);

const forbidden = [
  [/^upstream\//, 'the upstream source tree'],
  [/^native\//, 'the Rust binding sources'],
  [/^scripts\//, 'the build scripts'],
  [/^tests\//, 'the test fixtures'],
  [/\.rs$/, 'a Rust source file'],
  [/Cargo\.(toml|lock)$/, 'a Cargo manifest'],
  [/^target\//, 'a Cargo target directory'],
];

let bad = 0;
for (const [pattern, what] of forbidden) {
  for (const file of files) {
    if (pattern.test(file)) {
      console.error(`    UNEXPECTED ${what}: ${file}`);
      bad = 1;
    }
  }
}

for (const required of ['package.json', 'index.js', 'index.d.ts']) {
  if (!files.includes(required)) {
    console.error(`    MISSING ${required}`);
    bad = 1;
  }
}
if (!files.some((file) => file === 'LICENSE-MIT' || file === 'LICENSE')) {
  console.error('    MISSING a license file');
  bad = 1;
}

// The repository URL must point at GitHub, never at a local path or at the
// upstream project.
const pkg = require(join(dir, 'package.json'));
if (!/github\.com\/lkyhfx\/wordcraft-doc/.test(JSON.stringify(pkg.repository))) {
  console.error(`    BAD repository: ${JSON.stringify(pkg.repository)}`);
  bad = 1;
}
if (pkg.dependencies && Object.keys(pkg.dependencies).length > 0) {
  console.error(`    UNEXPECTED runtime dependencies: ${Object.keys(pkg.dependencies).join(', ')}`);
  bad = 1;
}
if (!pkg.optionalDependencies?.[`@lkyhfx/wordcraft-doc-${suffix}`]) {
  console.error(`    MISSING optionalDependency for ${suffix}`);
  bad = 1;
}

process.exit(bad);
JS

say "==> converting a document from the installed package"
node - "$WORK" "$ROOT/tests/fixtures/test.doc" <<'JS'
const { readFileSync, writeFileSync } = require('node:fs');
const [work, fixture] = process.argv.slice(2);

(async () => {
  const { convertDocToDocx, convertDocFileToDocx } = require(`${work}/node_modules/@lkyhfx/wordcraft-doc`);
  const input = readFileSync(fixture);
  const output = await convertDocToDocx(input);
  if (!Buffer.isBuffer(output) || output.length === 0) throw new Error('no Buffer output');
  if (output.readUInt32LE(0) !== 0x04034b50) throw new Error('output is not a zip');
  const parsed = require(`${work}/node_modules/@lkyhfx/wordcraft-doc`).__napiBindingTarget;
  const target = parsed === 'native' ? 'native addon' : parsed;
  console.log('    Buffer API:', output.length, 'bytes via', target);

  const target2 = `${work}/out.docx`;
  await convertDocFileToDocx(fixture, target2);
  const written = readFileSync(target2);
  if (!written.equals(output)) throw new Error('the file API and the Buffer API disagree');
  console.log('    file API:  ', written.length, 'bytes, identical to the Buffer API');
})().catch((error) => {
  console.error('   ', error.code ?? '', error.message);
  process.exit(1);
});
JS

say "==> typechecking the published declarations"
if command -v tsc >/dev/null || [[ -x "$ROOT/.dev/cli/node_modules/.bin/tsc" ]]; then
  TSC="$(command -v tsc || echo "$ROOT/.dev/cli/node_modules/.bin/tsc")"
  cat >"$WORK/consumer.ts" <<'TS'
import { convertDocToDocx, convertDocFileToDocx } from '@lkyhfx/wordcraft-doc';
import type { ConvertOptions } from '@lkyhfx/wordcraft-doc';

async function use(input: Buffer, path: string): Promise<number> {
  const options: ConvertOptions = { password: 'x', maxInputBytes: 1 << 20, maxOutputBytes: 1 << 20 };
  const output: Buffer = await convertDocToDocx(input, options);
  await convertDocFileToDocx(path, '/tmp/out.docx');
  await convertDocFileToDocx(path, '/tmp/out.docx', { password: 'y' });
  return output.length;
}

void use;
TS
  cat >"$WORK/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "strict": true,
    "noEmit": true,
    "target": "ES2022",
    "module": "node16",
    "moduleResolution": "node16",
    "types": ["node"]
  },
  "files": ["consumer.ts"]
}
JSON
  # `@types/node` is needed for `Buffer`; install it locally if absent.
  [[ -d "$WORK/node_modules/@types/node" ]] ||
    npm install --no-audit --no-fund --no-save @types/node >/dev/null 2>&1 || true
  ( cd "$WORK" && "$TSC" --project tsconfig.json ) || fail "the published type declarations do not typecheck"
  echo "    declarations typecheck under strict mode"
else
  echo "    (tsc not available; skipping)"
fi

# ---------------------------------------------------------------------------
# The same checks under every other installed runtime we can reach.
# ---------------------------------------------------------------------------
say "==> checking the platform package is the only binary present"
find "$installed" -name '*.node' -print | while read -r file; do
  fail "the main package ships a binary ($file); it must come from the platform package"
done
echo "    the main package ships no binary"

say "==> all package checks passed"
