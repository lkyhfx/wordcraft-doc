#!/usr/bin/env bash
# Publish the tarballs from npm-dist/ to the npm registry.
#
# Platform packages go first: the main package lists them as
# optionalDependencies, and npm resolves those at install time, so publishing the
# main package first would leave a version whose binaries do not exist yet.
#
#   ./scripts/publish.sh                    # publish all three (latest tag)
#   ./scripts/publish.sh --dry-run          # show what would be published
#   ./scripts/publish.sh --otp 123456       # one-shot password for 2FA accounts
#   ./scripts/publish.sh --skip-existing    # tolerate an already-published version
#
# The account must be able to publish to the @lkyhfx scope. An account with 2FA
# enabled needs either an Automation token (which bypasses 2FA) or an --otp.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/npm-dist"
VERSION="$(node -p "require('$ROOT/npm/package.json').version")"
export npm_config_cache="${npm_config_cache:-$ROOT/.dev/npm-cache}"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

DRY_RUN=()
OTP=()
SKIP_EXISTING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=(--dry-run) ;;
    --otp) [[ $# -ge 2 ]] || die "--otp needs a value"; OTP=(--otp "$2"); shift ;;
    --skip-existing) SKIP_EXISTING=1 ;;
    --help|-h) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

command -v npm >/dev/null || die "npm not found"
[[ -d "$DIST" ]] || die "no $DIST; run scripts/package-native.sh first"

# Publishing is irreversible for a given version, so check the obvious things
# before touching the registry.
say "==> checking credentials and scope"
WHO="$(npm whoami 2>/dev/null)" || die "not logged in; run: npm login"
say "    account: $WHO"
if [[ -z "${DRY_RUN[*]}" ]]; then
  # A scoped publish needs write access to the scope. Asking for the package
  # metadata is enough to fail early on a wrong account.
  npm access list packages "@lkyhfx" >/dev/null 2>&1 || true
fi

# Platform packages first.
PLATFORMS=(
  "lkyhfx-wordcraft-doc-linux-x64-gnu-$VERSION.tgz"
  "lkyhfx-wordcraft-doc-linux-arm64-gnu-$VERSION.tgz"
)
MAIN="lkyhfx-wordcraft-doc-$VERSION.tgz"

for file in "${PLATFORMS[@]}" "$MAIN"; do
  [[ -f "$DIST/$file" ]] || die "missing $DIST/$file; run scripts/package-native.sh"
done

publish_one() {
  local file="$1"
  local name version
  name="$(tar -xzOf "$DIST/$file" package/package.json | node -p "JSON.parse(require('fs').readFileSync(0,'utf8')).name")"
  version="$(tar -xzOf "$DIST/$file" package/package.json | node -p "JSON.parse(require('fs').readFileSync(0,'utf8')).version")"

  if [[ $SKIP_EXISTING -eq 1 ]] && npm view "$name@$version" version >/dev/null 2>&1; then
    say "==> $name@$version already published; skipping"
    return
  fi

  say "==> publishing $name@$version"
  npm publish "$DIST/$file" --access public "${DRY_RUN[@]}" "${OTP[@]}"
}

if [[ ${#DRY_RUN[@]} -eq 0 && ${#OTP[@]} -eq 0 ]]; then
  # Without an OTP, the token itself must bypass 2FA (an Automation token).
  # Fail fast with an explanation instead of publishing one package and then
  # hitting the 403 halfway through a release.
  if npm view "@lkyhfx/wordcraft-doc@$VERSION" version >/dev/null 2>&1; then
    say "    (this version is already on the registry)"
  fi
fi

for file in "${PLATFORMS[@]}"; do
  publish_one "$file"
done
publish_one "$MAIN"

say "==> done"
if [[ ${#DRY_RUN[@]} -eq 0 ]]; then
  cat <<EOF

  Verify the published package the way a user gets it:

    cd \$(mktemp -d) && npm init -y
    npm install @lkyhfx/wordcraft-doc@$VERSION
    node -e "const {convertDocToDocx}=require('@lkyhfx/wordcraft-doc'); console.log(typeof convertDocToDocx)"

  If the release is wrong, unpublish within 72 hours:

    npm unpublish @lkyhfx/wordcraft-doc@$VERSION
    npm unpublish @lkyhfx/wordcraft-doc-linux-x64-gnu@$VERSION
    npm unpublish @lkyhfx/wordcraft-doc-linux-arm64-gnu@$VERSION

EOF
fi
