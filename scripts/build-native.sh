#!/usr/bin/env bash
# Build the native addon for one or both Linux targets with Zig, then refresh
# the generated JavaScript loader and TypeScript declarations in npm/.
#
#   ./scripts/build-native.sh                      # host target only
#   ./scripts/build-native.sh --target all         # both supported targets
#   ./scripts/build-native.sh --target aarch64-unknown-linux-gnu
#
# Every target is linked by cargo-zigbuild against glibc 2.28, so the host
# compiler and its glibc are not used. Both the Zig and cargo-zigbuild versions
# are pinned; override them only when testing a toolchain bump.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/native"
NPM_DIR="$ROOT/npm"
CARGO_HOME="${CARGO_HOME:-$ROOT/.dev/cargo-home}"
export CARGO_HOME

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
CARGO_ZIGBUILD_VERSION="${CARGO_ZIGBUILD_VERSION:-0.24.1}"
GLIBC_BASELINE="${GLIBC_BASELINE:-2.28}"
MIN_NAPI_VERSION="3.10.9"

HOST_TARGET="$(rustc -vV | awk '/^host:/ {print $2}')"
TARGETS=()

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target|-t)
      [[ $# -ge 2 ]] || die "--target needs a value"
      if [[ "$2" == "all" ]]; then
        TARGETS=(x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu)
      else
        TARGETS+=("$2")
      fi
      shift 2
      ;;
    --help|-h) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("$HOST_TARGET")
fi

# ---------------------------------------------------------------------------
# Toolchain checks. Fail before compiling, naming the missing tool and the
# version this project is pinned to.
# ---------------------------------------------------------------------------
command -v cargo >/dev/null || die "cargo not found"
command -v rustc >/dev/null || die "rustc not found"
command -v node >/dev/null || die "node not found (npm >=24)"
[[ -d "$ROOT/upstream/wordcraft/crates/docbin" ]] || \
  die "upstream submodule is not checked out; run: git submodule update --init --recursive"

RUST_VERSION="$(rustc --version | awk '{print $2}')"
MIN_RUST_VERSION="$(awk -F'"' '/^rust-version = / {print $2; exit}' "$NATIVE/Cargo.toml")"
[[ -n "$MIN_RUST_VERSION" ]] || die "native/Cargo.toml has no rust-version"
if [[ "$(printf '%s\n%s\n' "$MIN_RUST_VERSION" "$RUST_VERSION" | sort -V | head -1)" != "$MIN_RUST_VERSION" ]]; then
  die "Rust $RUST_VERSION is older than native/Cargo.toml's rust-version $MIN_RUST_VERSION"
fi

# Zig: an installed `zig`, else the pinned toolchain under .dev/zig.
find_zig() {
  local candidate
  for candidate in "${ZIG_BIN:-}" "$(command -v zig || true)" "$ROOT/.dev/zig/zig"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
ZIG="$(find_zig || true)"
[[ -n "$ZIG" ]] || die "zig not found; install Zig $ZIG_VERSION:
  curl -L https://ziglang.org/download/$ZIG_VERSION/zig-\$(uname -m)-linux-$ZIG_VERSION.tar.xz | tar -xJ
  and put the extracted zig binary on PATH, or at .dev/zig/zig"
ZIG_ACTUAL="$("$ZIG" version)"
[[ "$ZIG_ACTUAL" == "$ZIG_VERSION" ]] || \
  die "zig $ZIG_ACTUAL found at $ZIG, expected $ZIG_VERSION (set ZIG_VERSION only when testing a toolchain bump)"
export PATH="$(dirname "$ZIG"):$PATH"

# cargo-zigbuild: PATH, else the copy installed under .dev/tools.
find_zigbuild() {
  local candidate
  for candidate in "$(command -v cargo-zigbuild || true)" "$ROOT/.dev/tools/bin/cargo-zigbuild"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
ZIGBUILD="$(find_zigbuild || true)"
[[ -n "$ZIGBUILD" ]] || die "cargo-zigbuild not found; install it with:
  cargo install cargo-zigbuild --version $CARGO_ZIGBUILD_VERSION --locked"
ZIGBUILD_ACTUAL="$("$ZIGBUILD" --version | awk '{print $2}')"
[[ "$ZIGBUILD_ACTUAL" == "$CARGO_ZIGBUILD_VERSION" ]] || \
  die "cargo-zigbuild $ZIGBUILD_ACTUAL found at $ZIGBUILD, expected $CARGO_ZIGBUILD_VERSION"
export PATH="$(dirname "$ZIGBUILD"):$PATH"

# The napi CLI generates the loader and the types. `--cross-compile` with a
# versioned target is what routes the build through cargo-zigbuild without
# losing the glibc suffix.
if ! command -v napi >/dev/null; then
  if [[ -x "$ROOT/node_modules/.bin/napi" ]]; then
    export PATH="$ROOT/node_modules/.bin:$PATH"
  else
    die "napi CLI not found; run: npm install"
  fi
fi
NAPI_ACTUAL="$(napi --version)"
if [[ "$(printf '%s\n%s\n' "$MIN_NAPI_VERSION" "$NAPI_ACTUAL" | sort -V | head -1)" != "$MIN_NAPI_VERSION" ]]; then
  die "napi CLI $NAPI_ACTUAL is older than $MIN_NAPI_VERSION; run: npm install"
fi

for target in "${TARGETS[@]}"; do
  case "$target" in
    x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu) ;;
    *) die "unsupported target $target; supported: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu" ;;
  esac
  if command -v rustup >/dev/null; then
    rustup target list --installed | grep -qx "$target" || \
      die "Rust target $target is not installed; run: rustup target add $target"
  fi
done

say "zig $ZIG_ACTUAL, cargo-zigbuild $ZIGBUILD_ACTUAL, rustc $RUST_VERSION, glibc $GLIBC_BASELINE"

# One place decides the published version: fail before a loader is generated
# against a stale Cargo or npm version.
"$ROOT/scripts/check-versions.mjs"

first=1
for target in "${TARGETS[@]}"; do
  say "building $target (glibc $GLIBC_BASELINE)"

  # Only the first target regenerates index.js/index.d.ts: they are
  # target-independent. The extra targets write the declarations to a
  # throwaway name, removed below.
  if [[ $first -eq 1 ]]; then
    extra=(--js index.js --dts index.d.ts)
    first=0
  else
    extra=(--no-js --dts discard.d.ts)
  fi

  if ! (
    cd "$NATIVE"
    napi build --platform --release --cross-compile \
      --target "$target.$GLIBC_BASELINE" \
      --package-json-path "$NPM_DIR/package.json" \
      --cwd . \
      --manifest-path Cargo.toml \
      --output-dir "$NPM_DIR" \
      "${extra[@]}"
  ); then
    die "build failed for $target (stage: cargo zigbuild + NAPI binding generation)"
  fi

  suffix="$(node -p "process.argv[1] === 'aarch64-unknown-linux-gnu' ? 'linux-arm64-gnu' : 'linux-x64-gnu'" "$target")"
  "$ROOT/scripts/check-native-compatibility.sh" "$NPM_DIR/wordcraft-doc.$suffix.node"
done

rm -f "$NPM_DIR/discard.d.ts"

say "built artifacts"
ls -1 "$NPM_DIR"/*.node
