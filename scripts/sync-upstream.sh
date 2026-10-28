#!/usr/bin/env bash
# Move the WordCraft upstream submodule to a new tag or commit, then check that
# the binding still builds and still converts a document correctly.
#
#   ./scripts/sync-upstream.sh v0.12.0
#   ./scripts/sync-upstream.sh 0123456789abcdef
#
# The script never commits, never tags and never publishes. It leaves the new
# submodule pointer staged for the developer to review and commit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="upstream/wordcraft"
SUB_DIR="$ROOT/$SUB"
UPSTREAM_URL="https://github.com/storytold/wordcraft.git"
UPSTREAM_MD="$ROOT/UPSTREAM.md"
SAMPLES="$ROOT/tests/fixtures"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

REF="${1:-}"
[[ "$REF" == "--help" || "$REF" == "-h" ]] && usage 0
[[ -n "$REF" ]] || die "usage: $0 <tag-or-commit>   (see --help)"

cd "$ROOT"

# ---------------------------------------------------------------------------
# 1. Refuse to work on a dirty tree: a failed sync must never mix with edits.
# ---------------------------------------------------------------------------
say "==> checking the working tree"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  git status --short --untracked-files=no
  die "the working tree has uncommitted changes; commit or stash them first"
fi
git submodule status "$SUB" >/dev/null 2>&1 || die "$SUB is not a submodule of this repository"
note "clean"

# ---------------------------------------------------------------------------
# 2. Fetch upstream tags and commits.
# ---------------------------------------------------------------------------
say "==> fetching $UPSTREAM_URL"
git -C "$SUB_DIR" fetch --tags --prune origin || die "fetch failed (is the network up?)"
note "fetched"

# ---------------------------------------------------------------------------
# 3. Resolve the requested ref and move the submodule to it.
# ---------------------------------------------------------------------------
say "==> resolving '$REF'"
OLD_SHA="$(git -C "$SUB_DIR" rev-parse HEAD)"
if git -C "$SUB_DIR" rev-parse --verify --quiet "refs/tags/$REF^{commit}" >/dev/null; then
  NEW_SHA="$(git -C "$SUB_DIR" rev-parse "refs/tags/$REF^{commit}")"
  KIND="tag"
elif git -C "$SUB_DIR" rev-parse --verify --quiet "$REF^{commit}" >/dev/null; then
  NEW_SHA="$(git -C "$SUB_DIR" rev-parse "$REF^{commit}")"
  KIND="commit"
else
  die "'$REF' is neither a known tag nor a known commit upstream"
fi

if [[ "$OLD_SHA" == "$NEW_SHA" ]]; then
  say "already at $REF ($NEW_SHA); nothing to do"
  exit 0
fi
note "$KIND $REF -> $NEW_SHA (was $OLD_SHA)"

say "==> checking out $NEW_SHA"
git -C "$SUB_DIR" checkout --detach "$NEW_SHA" >/dev/null

# ---------------------------------------------------------------------------
# 4. The binding may only use these upstream items: make sure they still exist.
# ---------------------------------------------------------------------------
say "==> checking the upstream API the binding relies on"
missing=0
require_fn() { # file, pattern, description
  if ! grep -qE "$2" "$ROOT/$SUB/$1" 2>/dev/null; then
    note "MISSING $3 ($1)"
    missing=1
  else
    note "ok  $3"
  fi
}
require_fn "crates/docbin/src/lib.rs" 'pub fn read\('               'wordcraft_docbin::read'
require_fn "crates/docbin/src/lib.rs" 'pub fn read_with_password\(' 'wordcraft_docbin::read_with_password'
require_fn "crates/docbin/src/lib.rs" 'pub enum DocbinError'       'wordcraft_docbin::DocbinError'
require_fn "crates/docx/src/lib.rs"   'pub use write::\{write'     'wordcraft_docx::write'
require_fn "crates/docx/src/lib.rs"   'pub enum DocxError'         'wordcraft_docx::DocxError'
require_fn "crates/docbin/Cargo.toml" '^name = "wordcraft-docbin"' 'wordcraft-docbin crate name'
require_fn "crates/docx/Cargo.toml"   '^name = "wordcraft-docx"'   'wordcraft-docx crate name'
require_fn "crates/doc/Cargo.toml"    '^name = "wordcraft-doc"'    'wordcraft-doc crate name'

if [[ $missing -ne 0 ]]; then
  die "an upstream item the binding needs is gone; update native/src/lib.rs before continuing"
fi

# Error variants are matched exhaustively in the binding, so a new one breaks the
# build; warn early anyway with a readable diff.
say "==> diffing the error enums"
for f in crates/docbin/src/lib.rs crates/docx/src/lib.rs; do
  if git -C "$SUB_DIR" diff --unified=0 "$OLD_SHA" "$NEW_SHA" -- "$f" 2>/dev/null | grep -qE '^\+.*(=>|\{$)'; then
    note "changed: $f (review the DocbinError/DocxError matching in native/src/lib.rs)"
  else
    note "unchanged: $f"
  fi
done

# ---------------------------------------------------------------------------
# 5. Build and run a real conversion.
# ---------------------------------------------------------------------------
say "==> building the native addon"
"$ROOT/scripts/build-native.sh" || die "build failed; fix native/src/lib.rs (the submodule is left at $NEW_SHA)"

say "==> running a conversion smoke test"
command -v node >/dev/null || die "node not found"
suffix="$(node -p "process.arch === 'arm64' ? 'linux-arm64-gnu' : 'linux-x64-gnu'")"
nodefile="$ROOT/npm/wordcraft-doc.$suffix.node"
[[ -f "$nodefile" ]] || die "no built addon at $nodefile"

SMOKE_OUTPUT="$(node -e '
const fs = require("node:fs");
const path = require("node:path");
const addon = require(process.argv[1]);
const dir = process.argv[2];
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".doc"));
if (files.length === 0) { console.error("no .doc fixtures in " + dir); process.exit(1); }
(async () => {
  for (const file of files) {
    const bytes = await addon.convertDocToDocx(fs.readFileSync(path.join(dir, file)));
    if (!bytes || bytes.length === 0) throw new Error(file + ": empty output");
    if (bytes.readUInt32LE(0) !== 0x04034b50) throw new Error(file + ": output is not a zip");
  }
  console.log(files.length + " fixture(s) converted");
})().catch((err) => { console.error(err.message); process.exit(1); });
' "$nodefile" "$SAMPLES")" || die "smoke test failed"
note "$SMOKE_OUTPUT"

# ---------------------------------------------------------------------------
# 6. Record the new version.
# ---------------------------------------------------------------------------
say "==> updating UPSTREAM.md"
TAG_LINE="unknown (commit pin)"
if [[ "$KIND" == "tag" ]]; then
  TAG_LINE="$REF"
fi
TODAY="$(date -u +%Y-%m-%d)"
if [[ -f "$UPSTREAM_MD" ]]; then
  python3 - "$UPSTREAM_MD" "$TAG_LINE" "$NEW_SHA" "$TODAY" <<'PY'
import re, sys
path, tag, sha, today = sys.argv[1:5]
text = open(path, encoding="utf-8").read()
def set_field(text, label, value):
    pattern = re.compile(rf"^(- {re.escape(label)}:\s*).*$", re.M)
    if pattern.search(text):
        return pattern.sub(lambda m: m.group(1) + value, text, count=1)
    return text
text = set_field(text, "Tag", tag)
text = set_field(text, "Commit", sha)
text = set_field(text, "Last sync", today)
open(path, "w", encoding="utf-8").write(text)
PY
else
  note "UPSTREAM.md not found; skipping"
fi

# ---------------------------------------------------------------------------
# 7. Stage the new pointer and summarise.
# ---------------------------------------------------------------------------
git add "$SUB"
say "==> done"
cat <<EOF

  upstream:  $OLD_SHA -> $NEW_SHA ($KIND $REF)
  build:     ok
  smoke:     $SMOKE_OUTPUT
  staged:    $SUB (new submodule pointer)

  Nothing was committed and nothing was published. Next:

    git diff --submodule=log -- $SUB     # review the upstream changes
    git diff -- UPSTREAM.md
    git commit -m "chore(upstream): sync WordCraft to $REF"

  Then rebuild the release artifacts before publishing:

    ./scripts/build-native.sh --target all
    ./scripts/package-native.sh

EOF
