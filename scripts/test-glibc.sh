#!/usr/bin/env bash
# Load the built addons on a real glibc 2.28 system, without installing Node
# there: a Debian 10 userland is exported from the registry and the official
# Node 24 binary for the same architecture runs against it.
#
#   ./scripts/test-glibc.sh                 # both architectures
#   ./scripts/test-glibc.sh x64             # one architecture
#
# Docker/skopeo is used only to obtain the Debian 10 userland; the build itself
# never needs it. arm64 runs under qemu-aarch64-static. Everything is cached in
# .dev/glibc-test/ (git-ignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/.dev/glibc-test"
NODE_VERSION="${NODE_VERSION:-24.10.0}"
GLIBC_BASELINE="2.28"
QEMU="${QEMU_AARCH64:-$ROOT/.dev/qemu-aarch64-static}"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

arches=("$@")
[[ ${#arches[@]} -gt 0 ]] || arches=(x64 arm64)

command -v docker >/dev/null || command -v skopeo >/dev/null || \
  die "neither skopeo nor docker found; one is needed to export Debian 10"
mkdir -p "$CACHE"

node_tree() {
  local arch="$1"
  printf '%s/node-v%s-linux-%s' "$CACHE" "$NODE_VERSION" "$arch"
}

ensure_node() {
  local arch="$1" tree
  tree="$(node_tree "$arch")"
  [[ -x "$tree/bin/node" ]] && return
  # A previously downloaded arm64 Node in .dev/ is the same official build.
  local local_tree="$ROOT/.dev/node-v$NODE_VERSION-linux-$arch"
  if [[ -x "$local_tree/bin/node" ]]; then
    say "using $local_tree"
    cp -a "$local_tree" "$tree"
    return
  fi
  say "downloading Node $NODE_VERSION for linux-$arch"
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$arch.tar.xz" |
    tar -xJ -C "$CACHE"
  [[ -x "$tree/bin/node" ]] || die "Node extraction failed for $arch"
}

ensure_rootfs() {
  local arch="$1" image rootfs layers layer
  rootfs="$CACHE/rootfs-$arch"
  if [[ -f "$rootfs/lib/x86_64-linux-gnu/libc.so.6" || -f "$rootfs/lib/aarch64-linux-gnu/libc.so.6" ]]; then
    return
  fi
  image="debian:10-slim"
  say "exporting $image ($arch) to $rootfs"
  mkdir -p "$rootfs"

  if command -v skopeo >/dev/null; then
    # skopeo does not need the Docker daemon, which may be unreachable.
    layers="$CACHE/image-$arch"
    rm -rf "$layers"
    mkdir -p "$layers"
    skopeo copy --override-arch "$arch" --override-os linux "docker://$image" "dir:$layers" >/dev/null
    for layer in $(node -p "require('$layers/manifest.json').layers.map((l) => l.digest.slice(7)).join(' ')"); do
      tar -xf "$layers/$layer" -C "$rootfs" --no-same-owner 2>/dev/null
    done
  else
    local id
    docker pull --platform "linux/$arch" "$image" >/dev/null
    id="$(docker create --platform "linux/$arch" "$image")"
    docker export "$id" | tar -x --no-same-owner -C "$rootfs" 2>/dev/null
    docker rm "$id" >/dev/null
  fi
}

# Run a command under the exported userland. x64 uses its ld.so directly (the
# host kernel runs it); arm64 needs qemu.
in_rootfs() {
  local arch="$1" rootfs="$2"
  shift 2
  if [[ "$arch" == arm64 ]]; then
    [[ -x "$QEMU" ]] || die "$QEMU not found; set QEMU_AARCH64 to a qemu-aarch64-static binary"
    "$QEMU" -L "$rootfs" "$@"
  else
    # `lib64/ld-linux-x86-64.so.2` is an absolute symlink, so use the real
    # ld-2.28.so file and point it at the exported libraries.
    local loader
    loader="$(find "$rootfs/lib" -maxdepth 2 -type f -name 'ld-*.so' | head -1)"
    [[ -n "$loader" ]] || die "no x64 loader in $rootfs"
    "$loader" --library-path "$rootfs/lib/x86_64-linux-gnu:$rootfs/usr/lib/x86_64-linux-gnu" "$@"
  fi
}

for arch in "${arches[@]}"; do
  case "$arch" in
    x64|arm64) ;;
    *) die "unknown architecture $arch; use x64 or arm64" ;;
  esac

  ensure_node "$arch"
  ensure_rootfs "$arch"
  tree="$(node_tree "$arch")"
  rootfs="$CACHE/rootfs-$arch"
  suffix="$([[ "$arch" == arm64 ]] && echo linux-arm64-gnu || echo linux-x64-gnu)"

  say "loading the $arch addon on glibc $GLIBC_BASELINE"

  cat >"$CACHE/load-test.cjs" <<'JS'
const { readFileSync } = require('node:fs');
const [root, suffix, fixture] = process.argv.slice(2);

(async () => {
  const addon = require(`${root}/npm/index.js`);
  if (addon.__napiBindingTarget !== 'native') {
    throw new Error(`loaded a ${addon.__napiBindingTarget} binding`);
  }
  const glibc = process.report?.getReport?.().header?.glibcVersionRuntime;
  if (!glibc || !/^2\.(2[0-8]|1[0-9]|[0-9])$/.test(glibc)) {
    throw new Error(`expected to run on glibc <= 2.28, found ${glibc}`);
  }
  const doc = readFileSync(fixture);
  const docx = await addon.convertDocToDocx(doc);
  if (docx.readUInt32LE(0) !== 0x04034b50) throw new Error('DOCX output is not a zip');
  const pdf = await addon.convertDocToPdf(doc);
  if (pdf.subarray(0, 5).toString('latin1') !== '%PDF-') throw new Error('PDF output is not a PDF');
  console.log(`    glibc ${glibc}: native ${suffix} loaded, DOCX ${docx.length} bytes, PDF ${pdf.length} bytes`);
})().catch((error) => {
  for (let current = error, depth = 0; current && depth < 10; current = current.cause, depth += 1) {
    console.error('   ', '  '.repeat(depth), current.code ?? '', current.message);
  }
  process.exit(1);
});
JS

  in_rootfs "$arch" "$rootfs" "$tree/bin/node" "$CACHE/load-test.cjs" \
    "$ROOT" "$suffix" "$ROOT/tests/fixtures/test.doc" || \
    die "the $arch addon did not load on glibc $GLIBC_BASELINE"
done

say "glibc $GLIBC_BASELINE load tests passed"
