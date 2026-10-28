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
# The `.doc` reader.
require_fn "crates/docbin/src/lib.rs" 'pub fn read\('               'wordcraft_docbin::read'
require_fn "crates/docbin/src/lib.rs" 'pub fn read_with_password\(' 'wordcraft_docbin::read_with_password'
require_fn "crates/docbin/src/lib.rs" 'pub enum DocbinError'       'wordcraft_docbin::DocbinError'
require_fn "crates/docbin/Cargo.toml" '^name = "wordcraft-docbin"' 'wordcraft-docbin crate name'
# The document model and the DOCX reader/writer.
require_fn "crates/doc/src/lib.rs"    'pub struct Document'        'wordcraft_doc::Document'
require_fn "crates/doc/Cargo.toml"    '^name = "wordcraft-doc"'    'wordcraft-doc crate name'
require_fn "crates/docx/src/lib.rs"   'pub use write::\{write'     'wordcraft_docx::write'
require_fn "crates/docx/src/lib.rs"   'pub fn read_with_password\(' 'wordcraft_docx::read_with_password'
require_fn "crates/docx/src/lib.rs"   'pub enum DocxError'         'wordcraft_docx::DocxError'
require_fn "crates/docx/Cargo.toml"   '^name = "wordcraft-docx"'   'wordcraft-docx crate name'
# The PDF exporter, and the font database the binding asks about missing fonts.
require_fn "crates/pdf/src/lib.rs"    'pub fn export\('            'wordcraft_pdf::export'
require_fn "crates/pdf/src/lib.rs"    'pub struct PdfOptions'      'wordcraft_pdf::PdfOptions'
require_fn "crates/pdf/src/lib.rs"    'pub enum PdfError'          'wordcraft_pdf::PdfError'
require_fn "crates/pdf/Cargo.toml"    '^name = "wordcraft-pdf"'    'wordcraft-pdf crate name'
require_fn "crates/fonts/src/fontdb.rs" 'pub fn fallback_for\('   'wordcraft_fonts::FontDb::fallback_for'
require_fn "crates/fonts/src/fontdb.rs" 'pub fn global\('          'wordcraft_fonts::FontDb::global'
require_fn "crates/fonts/Cargo.toml"  '^name = "wordcraft-fonts"'  'wordcraft-fonts crate name'

if [[ $missing -ne 0 ]]; then
  die "an upstream item the binding needs is gone; update native/src/lib.rs before continuing"
fi

# ---------------------------------------------------------------------------
# 4b. Mirror upstream's `[patch.crates-io]` into native/Cargo.toml.
#
# native/ is its own Cargo workspace root, so upstream's `[patch.crates-io]` is
# not seen when this project builds: the PDF backend (krilla, a fork of the
# registry crate in storytold/craft-libs) would resolve from crates.io and fail
# to compile against craft-pdf. The binding therefore carries its own copy of the
# patch, and this step keeps the pin in step with upstream.
# ---------------------------------------------------------------------------
say "==> checking the PDF backend patches"
require_fn "Cargo.toml" '^\[patch\.crates-io\]'                     'upstream [patch.crates-io]'
require_fn "Cargo.toml" '^krilla = \{ git = '                        'upstream krilla patch'
require_fn "Cargo.toml" '^craft-pdf = \{ git = '                      'upstream craft-pdf dependency'

UP_KR_REV="$(grep -E '^krilla = \{ git = ' "$SUB_DIR/Cargo.toml" | grep -oE 'rev = "[0-9a-f]+"' | head -1 | cut -d'"' -f2)"
UP_CP_REV="$(grep -E '^craft-pdf = \{ git = ' "$SUB_DIR/Cargo.toml" | grep -oE 'rev = "[0-9a-f]+"' | head -1 | cut -d'"' -f2)"
[[ -n "$UP_KR_REV" ]] || die "upstream no longer patches krilla; review native/Cargo.toml and UPSTREAM.md"
[[ -n "$UP_CP_REV" ]] || die "upstream's craft-pdf dependency has no rev pin"
note "upstream: craft-pdf $UP_CP_REV, krilla patch $UP_KR_REV"

NATIVE_TOML="$ROOT/native/Cargo.toml"
if ! grep -q '^\[patch\.crates-io\]' "$NATIVE_TOML"; then
  die "native/Cargo.toml has no [patch.crates-io] section for krilla"
fi
if grep -qE "^krilla = \{ git = \"[^\"]*\", rev = \"$UP_KR_REV\"" "$NATIVE_TOML"; then
  note "ok  native krilla patch already at $UP_KR_REV"
else
  # Rewrite only the rev, so the git URL and the version requirement stay as
  # reviewed; a changed URL is a human decision.
  python3 - "$NATIVE_TOML" "$UP_KR_REV" <<'PYEOF'
import re, sys
path, rev = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
pattern = re.compile(r'^(krilla = \{ git = "[^"]+", rev = ")[0-9a-f]+(")', re.M)
if not pattern.search(text):
    sys.exit("no krilla patch line to update in native/Cargo.toml")
open(path, "w", encoding="utf-8").write(pattern.sub(lambda m: m.group(1) + rev + m.group(2), text, count=1))
PYEOF
  note "updated native krilla patch to $UP_KR_REV (review native/Cargo.toml)"
fi

# The lock file must follow the new patch; `cargo update` would also move the
# other pins, so only the two forge-backed packages are refreshed.
(
  cd "$ROOT/native"
  CARGO_HOME="${CARGO_HOME:-$ROOT/.dev/cargo-home}" cargo update -p krilla -p craft-pdf 2>/dev/null || true
)
note "native/Cargo.lock refreshed for krilla and craft-pdf"

# The crates the package must not pull in, even transitively.
say "==> checking the dependency graph stays narrow"
for forbidden in wordcraft-engine wordcraft-render wordcraft-ui-egui wordcraft-mcp wordcraft-cli wordcraft-zotero; do
  if grep -qE "^name = \"$forbidden\"" "$ROOT/native/Cargo.lock"; then
    die "$forbidden is in native/Cargo.lock; the binding must not depend on it"
  fi
  note "ok  absent: $forbidden"
done
if grep -qE '^name = "(egui|eframe|rayon)"' "$ROOT/native/Cargo.lock"; then
  die "a GUI or thread-pool dependency (egui/eframe/rayon) is in native/Cargo.lock"
fi
note "ok  no GUI dependencies"

# Error variants are matched exhaustively in the binding, so a new one breaks the
# build; warn early anyway with a readable diff.
say "==> diffing the error enums"
for f in crates/docbin/src/lib.rs crates/docx/src/lib.rs crates/pdf/src/lib.rs; do
  if git -C "$SUB_DIR" diff --unified=0 "$OLD_SHA" "$NEW_SHA" -- "$f" 2>/dev/null | grep -qE '^\+.*(=>|\{$)'; then
    note "changed: $f (review the DocbinError/DocxError/PdfError matching in native/src/lib.rs)"
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
    const input = fs.readFileSync(path.join(dir, file));
    const docx = await addon.convertDocToDocx(input);
    if (!docx || docx.length === 0) throw new Error(file + ": empty DOCX output");
    if (docx.readUInt32LE(0) !== 0x04034b50) throw new Error(file + ": DOCX output is not a zip");
    const pdf = await addon.convertDocToPdf(input);
    if (!pdf || pdf.length === 0) throw new Error(file + ": empty PDF output");
    if (pdf.subarray(0, 5).toString("latin1") !== "%PDF-") throw new Error(file + ": DOC to PDF output is not a PDF");
    const pdf2 = await addon.convertDocxToPdf(docx);
    if (!pdf2 || pdf2.subarray(0, 5).toString("latin1") !== "%PDF-") throw new Error(file + ": DOCX to PDF output is not a PDF");
  }
  console.log(files.length + " fixture(s) converted to DOCX and PDF");
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
git add "$SUB" "$UPSTREAM_MD" native/Cargo.toml native/Cargo.lock
say "==> done"
cat <<EOF

  upstream:  $OLD_SHA -> $NEW_SHA ($KIND $REF)
  build:     ok
  smoke:     $SMOKE_OUTPUT
  staged:    $SUB, UPSTREAM.md, native/Cargo.toml, native/Cargo.lock

  Nothing was committed and nothing was published. Next:

    git diff --cached --submodule=log -- $SUB     # review the staged upstream changes
    git diff --cached -- UPSTREAM.md native/Cargo.toml native/Cargo.lock
    git commit -m "chore(upstream): sync WordCraft to $REF"

  Then rebuild the release artifacts before publishing:

    ./scripts/build-native.sh --target all
    ./scripts/package-native.sh

EOF
