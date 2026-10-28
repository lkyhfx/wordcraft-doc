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
[[ -f "$NPM_DIR/index.js" && -f "$NPM_DIR/index.d.ts" ]] || {
  echo "npm/index.js or index.d.ts is missing; run scripts/build-native.sh first" >&2
  exit 1
}

rm -rf "$DIST"
mkdir -p "$DIST"

for entry in "${TARGETS[@]}"; do
  IFS=: read -r triple suffix <<<"$entry"
  nodefile="$NPM_DIR/$BASE.$suffix.node"
  if [[ ! -f "$nodefile" ]]; then
    echo "missing $nodefile; run scripts/build-native.sh --target $triple" >&2
    exit 1
  fi

  pkg="$DIST/npm/$BASE-$suffix"
  mkdir -p "$pkg"
  cp "$nodefile" "$pkg/"
  cp "$ROOT/LICENSE-MIT" "$ROOT/LICENSE-APACHE" "$pkg/"

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
  "files": ["$BASE.$suffix.node", "LICENSE-MIT", "LICENSE-APACHE"]
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
( cd "$main" && npm pack --pack-destination "$DIST" >/dev/null )
say "packed $SCOPE/$BASE"

say "artifacts in $DIST"
ls -1 "$DIST"/*.tgz
