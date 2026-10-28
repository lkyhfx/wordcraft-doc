# UPSTREAM

The WordCraft source this package is built on.

## Record

- Repository: `https://github.com/storytold/wordcraft`
- Tag: v0.11.0
- Commit: e31f2f06a5f8004ceaa88f68c00b47908e321aa4
- Last sync: 2026-10-28
- Submodule: `upstream/wordcraft`

## How it is consumed

WordCraft is a git submodule at `upstream/wordcraft`, pinned to the commit
above. `native/Cargo.toml` depends on five of its crates by path:

| Crate | Path | Role |
|---|---|---|
| `wordcraft-docbin` | `upstream/wordcraft/crates/docbin` | reads the `.doc` binary format ([MS-DOC]) |
| `wordcraft-doc` | `upstream/wordcraft/crates/doc` | the in-memory document model |
| `wordcraft-docx` | `upstream/wordcraft/crates/docx` | reads and writes the `.docx` (OOXML) package |
| `wordcraft-pdf` | `upstream/wordcraft/crates/pdf` | lays the document out and writes the PDF |
| `wordcraft-fonts` | `upstream/wordcraft/crates/fonts` | the font database (bundled OFL faces + system fonts), for the missing-font check |

`wordcraft-pdf` brings its own path dependencies (`wordcraft-layout`,
`wordcraft-geom`, `wordcraft-metafile`, `wordcraft-proof`, `wordcraft-fonts`)
plus the PDF writer, `craft-pdf`, and its drawing backend, `krilla`. That is
the whole tree: `wordcraft-render`, `wordcraft-engine`, `wordcraft-ui-egui`,
`wordcraft-mcp`, `wordcraft-cli`, `wordcraft-formats` and `wordcraft-zotero` are
not dependencies of this project, and `scripts/sync-upstream.sh` fails the sync
if any of them appears in `native/Cargo.lock`.

The upstream workspace is used as-is. `native/` is its own Cargo workspace root,
so the lock file for this project is `native/Cargo.lock` and it is committed:
reproducible builds need one. Cargo still resolves upstream's crates through
their own manifests; nothing in the upstream workspace is modified and upstream
is not merged into `native/`'s workspace.

## The craft-libs patch

`craft-pdf` and the `krilla` it draws with are a git fork
(`https://github.com/storytold/craft-libs`), not registry releases: the fork
carries the writer fixes `craft-pdf` needs, and the registry `krilla` does not
compile against it. Upstream expresses this with `[patch.crates-io] krilla = {
git = …, rev = … }` in its workspace root.

`native/` is a separate workspace root, so that patch does not reach it, and the
plain registry `krilla` would be resolved — and fail to build. `native/Cargo.toml`
therefore repeats the patch with the same `rev`:

```toml
[patch.crates-io]
krilla = { git = "https://github.com/storytold/craft-libs", rev = "17744430be327d0257496a6a31c8d38fe20a6756" }
```

`scripts/sync-upstream.sh` compares this pin with upstream's on every sync and
rewrites the `rev` when they diverge; it stops if upstream removes the patch or
the dependency. Both revs must match: a `craft-pdf` at one rev and a `krilla` at
another is not a combination upstream tests. `native/Cargo.lock` records the
resolved git commits and is committed with the submodule pointer.

## Local patches

None. The binding calls upstream's public entry points only:

```rust
let document = match source {
    Source::Doc => wordcraft_docbin::read_with_password(&input, password)?,
    Source::Docx => wordcraft_docx::read_with_password(&input, password)?,
};
let docx = wordcraft_docx::write(&document)?;
let pdf = wordcraft_pdf::export(&document, &wordcraft_pdf::PdfOptions::default())?;
```

`wordcraft_fonts::FontDb::global().fallback_for(..)` is queried before a PDF
export, only to turn a document no installed font can draw into
`ERR_WORDCRAFT_FONTS` instead of a page of empty boxes.

If a future upstream change needs a fix that cannot be expressed in
`native/src/lib.rs`, record it here as a numbered patch, with the file, the
reason and the upstream issue link. Prefer reporting upstream over patching.

## Known compatibility issues

No upstream behaviour is known to break the binding at the pinned commit.

Things to watch on a future sync:

- `DocbinError`, `DocxError` and `PdfError` are matched exhaustively in
  `native/src/lib.rs`. A new variant breaks the build on purpose: add a code for
  it rather than letting it fall through.
- `wordcraft_pdf::PdfOptions` is built with `Default::default()` plus whatever
  the caller asked for. A new required field is a compile error; a new
  `Default` that changes pagination would silently change output, so check the
  PDF page counts in `tests/pdf.test.ts` after a sync.
- The font coverage check relies on `FontDb::global()` and
  `fallback_for(char, exclude_id)`. If upstream changes how a missing font is
  reported, update `check_fonts` and the `ERR_WORDCRAFT_FONTS` tests.
- `convertDocFileToDocx`/`convertDocFileToPdf` read the input size before
  reading the file, so a `read_with_password`-style API change does not affect
  the limit checks.
- The binding verifies the produced DOCX with its own zip reader
  (`verify_docx` in `native/src/lib.rs`) and the PDF with its own header/page/
  trailer check (`verify_pdf`), so a change to a writer or zip library upstream
  does not change what is accepted as output.
- The font check walks `Document::shown_stories()` and `Document::shown_text()`.
  A rename or a visibility change there is a compile error, which is intended.

## Syncing

```bash
./scripts/sync-upstream.sh v0.12.0        # a tag
./scripts/sync-upstream.sh 0123456abc    # a specific commit
```

The script refuses a dirty tree, fetches upstream, checks out the requested
ref, verifies the upstream API the binding needs (`.doc` reader, document model,
DOCX reader/writer, PDF exporter, font database), re-pins the `krilla` patch,
refreshes `native/Cargo.lock`, checks that no forbidden crate entered the
dependency graph, builds the addon, converts a fixture to DOCX and to PDF, and
updates the record above with the new submodule pointer staged. It never commits
and never publishes.

After it runs, review and commit:

```bash
git diff --submodule=log -- upstream/wordcraft
git diff -- UPSTREAM.md native/Cargo.toml native/Cargo.lock
git commit -m "chore(upstream): sync WordCraft to v0.12.0"
```

## Released against this pin

| Package version | Upstream tag | Upstream commit | Published |
|---|---|---|---|
| `@lkyhfx/wordcraft-doc@0.1.0` | v0.11.0 | e31f2f06a5f8004ceaa88f68c00b47908e321aa4 | 2026-10-28 |
| `@lkyhfx/wordcraft-doc@0.1.1` | v0.11.0 | e31f2f06a5f8004ceaa88f68c00b47908e321aa4 | 2026-10-28 |
| `@lkyhfx/wordcraft-doc@0.1.2` | v0.11.0 | e31f2f06a5f8004ceaa88f68c00b47908e321aa4 | 2026-10-28 |
