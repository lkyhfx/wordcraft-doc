#!/usr/bin/env bash
# Build the native addon for one or both Linux targets and refresh the generated
# JavaScript loader and TypeScript declarations in npm/.
#
#   ./scripts/build-native.sh                      # host target only
#   ./scripts/build-native.sh --target all         # both supported targets
#   ./scripts/build-native.sh --target aarch64-unknown-linux-gnu
#
# Cross-compiling to aarch64 from x86_64 needs an aarch64 linker. Set
# AARCH64_LINKER to override the probe below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/native"
NPM_DIR="$ROOT/npm"
CARGO_HOME="${CARGO_HOME:-$ROOT/.dev/cargo-home}"
export CARGO_HOME

HOST_TARGET="$(rustc -vV | awk '/^host:/ {print $2}')"
TARGETS=()

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target|-t)
      [[ $# -ge 2 ]] || { echo "--target needs a value" >&2; exit 1; }
      if [[ "$2" == "all" ]]; then
        TARGETS=(x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu)
      else
        TARGETS+=("$2")
      fi
      shift 2
      ;;
    --help|-h) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("$HOST_TARGET")
fi

command -v cargo >/dev/null || { echo "cargo not found" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found" >&2; exit 1; }
[[ -d "$ROOT/upstream/wordcraft/crates/docbin" ]] || {
  echo "upstream submodule is not checked out; run: git submodule update --init --recursive" >&2
  exit 1
}

# The napi CLI generates the loader and the types.
if ! command -v napi >/dev/null; then
  if [[ -x "$ROOT/node_modules/.bin/napi" ]]; then
    export PATH="$ROOT/node_modules/.bin:$PATH"
  elif [[ -x "$ROOT/.dev/cli/node_modules/.bin/napi" ]]; then
    export PATH="$ROOT/.dev/cli/node_modules/.bin:$PATH"
  else
    echo "napi CLI not found. Install the dev dependencies first:" >&2
    echo "  npm install" >&2
    exit 1
  fi
fi

# Find an aarch64 cross linker: the napi-rs toolchain, then common system names.
detect_aarch64_linker() {
  if [[ -n "${AARCH64_LINKER:-}" ]]; then
    printf '%s' "$AARCH64_LINKER"
    return
  fi
  local candidates=(
    "$ROOT/.dev/tcx/bin/aarch64-unknown-linux-gnu-gcc"
    "$(command -v aarch64-linux-gnu-gcc || true)"
    "$(command -v aarch64-unknown-linux-gnu-gcc || true)"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -x "$c" ]]; then
      printf '%s' "$c"
      return
    fi
  done
  printf ''
}

first=1
for target in "${TARGETS[@]}"; do
  printf '\n\033[1m==> building %s\033[0m\n' "$target"

  rustup target list --installed | grep -qx "$target" || {
    echo "target $target is not installed; run: rustup target add $target" >&2
    exit 1
  }

  if [[ "$target" == "aarch64-unknown-linux-gnu" && "$HOST_TARGET" != "$target" ]]; then
    linker="$(detect_aarch64_linker)"
    if [[ -z "$linker" ]]; then
      echo "no aarch64 linker found; set AARCH64_LINKER or install the napi-rs cross toolchain" >&2
      exit 1
    fi
    export "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=$linker"
    export "CC_aarch64_unknown_linux_gnu=$linker"
    echo "    linker: $linker"
  fi

  # Only the first target regenerates index.js/index.d.ts: they are
  # target-independent, and a second run would just rewrite them. The CLI has
  # no flag to skip the declarations, so the extra targets write them to a
  # throwaway name inside the output directory, removed below. (`--dts /dev/null`
  # does not work: the CLI joins it onto the output directory.)
  extra=()
  if [[ $first -eq 1 ]]; then
    extra=(--js index.js --dts index.d.ts)
    first=0
  else
    extra=(--no-js --dts discard.d.ts)
  fi

  (
    cd "$NATIVE"
    napi build --platform --release \
      --target "$target" \
      --package-json-path "$NPM_DIR/package.json" \
      --cwd . \
      --manifest-path Cargo.toml \
      --output-dir "$NPM_DIR" \
      "${extra[@]}"
  )
done

rm -f "$NPM_DIR/discard.d.ts"

printf '\n\033[1m==> built artifacts\033[0m\n'
ls -1 "$NPM_DIR"/*.node
