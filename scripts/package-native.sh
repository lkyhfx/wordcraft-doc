#!/usr/bin/env bash
# Package the main npm package plus one package per platform target.
#
# The `.node` files must already be built (see build-native.sh). Output goes to
# npm-dist/: two platform tarballs and the main tarball. Publish the platform
# packages first, otherwise the main package's optionalDependencies cannot be
# resolved.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NPM_DIR="$ROOT/npm"
DIST="$ROOT/npm-dist"
VERSION="$(node -p "require('$NPM_DIR/package.json').version")"
SCOPE="@lkyhfx"
BASE="wordcraft-doc"

# target triple : npm platform suffix : node file
TARGETS=(
  "x86_64-unknown-linux-gnu:linux-x64-gnu"
  "aarch64-unknown-linux-gnu:linux-arm64-gnu"
)

say() { printf '\033[1m%s\033[0m\n' "$*"; }

command -v npm >/dev/null || { echo "npm not found" >&2; exit 1; }
command -v cargo-about >/dev/null || {
  echo "cargo-about not found; install it with: cargo install cargo-about --locked" >&2
  exit 1
}
[[ -f "$NPM_DIR/index.js" && -f "$NPM_DIR/index.d.ts" ]] || {
  echo "npm/index.js or index.d.ts is missing; run scripts/build-native.sh first" >&2
  exit 1
}

LICENSE_REPORT="$ROOT/.tmp/wordcraft-doc-third-party-licenses.md"
mkdir -p "$(dirname "$LICENSE_REPORT")"
(
  cd "$ROOT/native"
  cargo about generate "$ROOT/scripts/third-party-licenses.hbs"
) > "$LICENSE_REPORT"
[[ -s "$LICENSE_REPORT" ]] || {
  echo "third-party license report is empty; refusing to package binaries" >&2
  exit 1
}

# A cap on the addon's size: the format crates and the PDF exporter together come
# to roughly 15 MiB stripped, while pulling in the whole Engine (GUI, image
# stack, UI fonts) would add tens of MiB. Failing here catches that mistake
# before a multi-megabyte binary reaches npm.
MAX_BINARY_BYTES=$((64 * 1024 * 1024))

rm -rf "$DIST"
mkdir -p "$DIST"

for entry in "${TARGETS[@]}"; do
  IFS=: read -r triple suffix <<<"$entry"
  nodefile="$NPM_DIR/$BASE.$suffix.node"
  if [[ ! -f "$nodefile" ]]; then
    echo "missing $nodefile; run scripts/build-native.sh --target $triple" >&2
    exit 1
  fi

  binary_size="$(stat -c %s "$nodefile")"
  if (( binary_size > MAX_BINARY_BYTES )); then
    echo "$(basename "$nodefile") is $binary_size bytes, above the $MAX_BINARY_BYTES-byte cap;" >&2
    echo "an upstream component that does not belong here is probably linked in (egui, render, engine, craft-fonts)" >&2
    exit 1
  fi
  printf '    %s: %s bytes\n' "$suffix" "$binary_size"

  pkg="$DIST/npm/$BASE-$suffix"
  mkdir -p "$pkg"
  cp "$nodefile" "$pkg/"
  cp "$ROOT/LICENSE-MIT" "$ROOT/LICENSE-APACHE" "$ROOT/NOTICE" "$pkg/"
  # The report is packed under the name `files` declares, not its scratch name.
  cp "$LICENSE_REPORT" "$pkg/THIRD-PARTY-LICENSES.md"

  # A platform package carries nothing but the binary: no scripts, no deps.
  cat >"$pkg/package.json" <<JSON
{
  "name": "$SCOPE/$BASE-$suffix",
  "version": "$VERSION",
  "description": "Prebuilt $triple binding for $SCOPE/$BASE",
  "license": "MIT OR Apache-2.0",
  "repository": {
    "type": "git",
    "url": "git+https://github.com/lkyhfx/wordcraft-doc.git"
  },
  "os": ["linux"],
  "cpu": ["$( [[ "$suffix" == *x64* ]] && echo x64 || echo arm64 )"],
  "libc": ["glibc"],
  "main": "$BASE.$suffix.node",
  "files": ["$BASE.$suffix.node", "LICENSE-MIT", "LICENSE-APACHE", "NOTICE", "THIRD-PARTY-LICENSES.md"]
}
JSON

  ( cd "$pkg" && npm pack --pack-destination "$DIST" >/dev/null )
  say "packed $SCOPE/$BASE-$suffix"
done

# Main package: the loader, the types, the licenses and the docs.
main="$DIST/npm/$BASE"
mkdir -p "$main"
cp "$NPM_DIR/index.js" "$NPM_DIR/index.d.ts" "$NPM_DIR/package.json" "$main/"
cp "$ROOT/LICENSE-MIT" "$ROOT/LICENSE-APACHE" "$ROOT/NOTICE" "$ROOT/README.md" "$main/"
cp "$LICENSE_REPORT" "$main/THIRD-PARTY-LICENSES.md"

# Keep the optional platform package versions aligned with the main package.
node - "$main/package.json" "$VERSION" <<'JS'
const fs = require('node:fs');
const [manifestPath, version] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const expected = [
  '@lkyhfx/wordcraft-doc-linux-arm64-gnu',
  '@lkyhfx/wordcraft-doc-linux-x64-gnu',
].sort();
const actual = Object.keys(pkg.optionalDependencies ?? {}).sort();
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  console.error('optionalDependencies must exactly match the supported platform packages');
  process.exit(1);
}
for (const name of expected) pkg.optionalDependencies[name] = version;
fs.writeFileSync(manifestPath, JSON.stringify(pkg, null, 2) + '\n');
JS

( cd "$main" && npm pack --pack-destination "$DIST" >/dev/null )
say "packed $SCOPE/$BASE"

say "artifacts in $DIST"
ls -1 "$DIST"/*.tgz
