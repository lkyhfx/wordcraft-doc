#!/usr/bin/env bash
# Check a built .node addon for the ABI the published package promises:
# a Linux ELF64 shared object for the right architecture, linked only against
# glibc, with no versioned symbol newer than GLIBC_2.28.
#
#   ./scripts/check-native-compatibility.sh                     # both npm/*.node
#   ./scripts/check-native-compatibility.sh path/to/addon.node  # one file
#
# This is a static check. It proves the tags and dependencies in the ELF, not
# that every target machine has the listed shared libraries; the glibc 2.28
# load test (scripts/test-glibc.sh) covers the runtime half.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLIBC_BASELINE="${GLIBC_BASELINE:-2.28}"
ALLOWED_NEEDED=(
  libc.so.6
  libm.so.6
  libpthread.so.0
  libdl.so.2
  ld-linux-x86-64.so.2
  ld-linux-aarch64.so.1
)

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

command -v readelf >/dev/null || die "readelf not found (install binutils)"

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  files=(
    "$ROOT/npm/wordcraft-doc.linux-x64-gnu.node"
    "$ROOT/npm/wordcraft-doc.linux-arm64-gnu.node"
  )
fi

# Highest version in a list of GLIBC_X.Y[.Z] tags, compared numerically.
highest_version() {
  sort -Vu | tail -1
}

check_one() {
  local file="$1"
  [[ -f "$file" ]] || die "missing $file; run scripts/build-native.sh first"
  [[ -s "$file" ]] || die "$file is empty"

  local name expected_machine
  name="$(basename "$file")"
  case "$name" in
    *.linux-x64-gnu.node) expected_machine="Advanced Micro Devices X86-64" ;;
    *.linux-arm64-gnu.node) expected_machine="AArch64" ;;
    *) die "$name: not a supported target name (want .linux-x64-gnu.node or .linux-arm64-gnu.node)" ;;
  esac

  say "checking $name"

  # --- ELF identity -------------------------------------------------------
  local header
  header="$(readelf -h "$file")" || die "$name: not an ELF file"
  grep -q 'Class:.*ELF64' <<<"$header" || die "$name: not ELF64"
  grep -q "Machine:.*$expected_machine" <<<"$header" || \
    die "$name: wrong machine (want $expected_machine)"
  grep -q 'Type:.*DYN' <<<"$header" || die "$name: not a shared object"
  note "ELF64 $expected_machine shared object, $(stat -c %s "$file") bytes"

  readelf -W --dyn-syms "$file" | grep -q 'napi_register_module_v1' || \
    die "$name: no napi_register_module_v1 export; this is not a Node-API addon"
  note "NAPI entry point: napi_register_module_v1"

  # --- dynamic dependencies ----------------------------------------------
  local dyn
  dyn="$(readelf -d "$file")" || die "$name: no .dynamic section"
  if grep -qE '\((RPATH|RUNPATH)\)' <<<"$dyn"; then
    die "$name: carries an RPATH/RUNPATH; the loader must resolve system libraries normally"
  fi

  local needed
  needed="$(sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' <<<"$dyn")"
  [[ -n "$needed" ]] || die "$name: has no NEEDED libraries"
  grep -qx 'libc.so.6' <<<"$needed" || die "$name: does not link libc.so.6"
  local library allowed
  while IFS= read -r library; do
    allowed=0
    for candidate in "${ALLOWED_NEEDED[@]}"; do
      [[ "$library" == "$candidate" ]] && allowed=1
    done
    [[ $allowed -eq 1 ]] || \
      die "$name: unexpected shared-library dependency '$library'; it may not exist on the target system"
  done <<<"$needed"
  note "NEEDED: $(tr '\n' ' ' <<<"$needed" | sed 's/ $//')"

  # --- versioned symbols --------------------------------------------------
  local versions
  versions="$(readelf --version-info "$file" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -Vu)"
  [[ -n "$versions" ]] || die "$name: no GLIBC version requirements found"

  local highest
  highest="$(highest_version <<<"$versions")"
  note "highest GLIBC requirement: $highest"

  if [[ "$(printf '%s\n%s\n' "$GLIBC_BASELINE" "${highest#GLIBC_}" | sort -V | tail -1)" != "$GLIBC_BASELINE" ]]; then
    local too_new
    too_new="$(awk -v baseline="$GLIBC_BASELINE" '
      { v = $0; sub(/^GLIBC_/, "", v); print v }
    ' <<<"$versions" | while IFS= read -r v; do
      [[ "$(printf '%s\n%s\n' "$baseline" "$v" | sort -V | tail -1)" == "$baseline" ]] || echo "$v"
    done | sort -Vu | tr '\n' ' ')"
    die "$name: requires ${highest#GLIBC_} (above GLIBC_$GLIBC_BASELINE): ${too_new%( }"
  fi

  local cxx
  cxx="$(readelf --version-info "$file" | grep -oE '(GLIBCXX|CXXABI)_[0-9]+(\.[0-9]+)+' | sort -Vu || true)"
  [[ -z "$cxx" ]] || \
    die "$name: needs the C++ runtime ($(tr '\n' ' ' <<<"$cxx")); the addon must not require libstdc++"

  note "compatible: glibc <= $GLIBC_BASELINE, no C++ runtime, no rpath"
}

for file in "${files[@]}"; do
  check_one "$file"
done

say "all native compatibility checks passed"
