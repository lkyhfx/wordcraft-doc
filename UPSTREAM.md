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
above. `native/Cargo.toml` depends on three of its crates by path:

| Crate | Path | Role |
|---|---|---|
| `wordcraft-docbin` | `upstream/wordcraft/crates/docbin` | reads the `.doc` binary format ([MS-DOC]) |
| `wordcraft-doc` | `upstream/wordcraft/crates/doc` | the in-memory document model |
| `wordcraft-docx` | `upstream/wordcraft/crates/docx` | writes the `.docx` (OOXML) package |

Only these three crates and whatever Cargo resolves transitively for them are
compiled. `wordcraft-layout`, `wordcraft-pdf`, `wordcraft-render`,
`wordcraft-engine`, `wordcraft-ui-egui`, `wordcraft-mcp`, `wordcraft-cli` and
`wordcraft-zotero` are not dependencies of this project.

The upstream workspace is used as-is. `native/` is its own Cargo workspace root,
so the lock file for this project is `native/Cargo.lock` and it is committed:
reproducible builds need one. Cargo still resolves upstream's crates through
their own manifests; nothing in the upstream workspace is modified and upstream
is not merged into `native/`'s workspace.

## Local patches

None. The binding calls the two upstream entry points:

```rust
let document = wordcraft_docbin::read_with_password(&input, password)?;
let output = wordcraft_docx::write(&document)?;
```

If a future upstream change needs a fix that cannot be expressed in
`native/src/lib.rs`, record it here as a numbered patch, with the file, the
reason and the upstream issue link. Prefer reporting upstream over patching.

## Known compatibility issues

No upstream behaviour is known to break the binding at the pinned commit.

Things to watch on a future sync:

- `DocbinError` and `DocxError` are matched exhaustively in
  `native/src/lib.rs`. A new variant breaks the build on purpose: add a code
  for it rather than letting it fall through.
- `convertDocFileToDocx` reads the input size before reading the file, so a
  `read_with_password`-style API change does not affect the limit checks.
- The binding verifies the produced package with its own zip reader
  (`verify_docx` in `native/src/lib.rs`), so a change to the zip library
  upstream does not change what is accepted as output.

## Syncing

```bash
./scripts/sync-upstream.sh v0.12.0        # a tag
./scripts/sync-upstream.sh 0123456abc    # a specific commit
```

The script refuses a dirty tree, fetches upstream, checks out the requested
ref, verifies the upstream API the binding needs, builds the addon, converts a
fixture, updates the record above, and stages the new submodule pointer. It
never commits and never publishes.

After it runs, review and commit:

```bash
git diff --submodule=log -- upstream/wordcraft
git diff -- UPSTREAM.md
git commit -m "chore(upstream): sync WordCraft to v0.12.0"
```
