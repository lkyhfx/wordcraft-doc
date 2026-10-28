# Test fixtures

Real `.doc` files, used to check that conversion keeps documents intact.

## Provenance

| File | Source | License |
|---|---|---|
| `test.doc`, `simple-table.doc`, `SampleDoc.doc`, `empty.doc`, `47304.doc` | [Apache POI](https://github.com/apache/poi) `test-data/document/` | Apache-2.0 |
| `testWORD.doc` | [Apache Tika](https://github.com/apache/tika) `tika-parser-microsoft-module` test documents | Apache-2.0 |
| `rich-structures.doc` | Generated for this project | MIT OR Apache-2.0 |

Files fetched from the Apache projects are redistributed unmodified under the
Apache License 2.0; see `LICENSE-APACHE`.

`rich-structures.doc` was produced by building a `.docx` with a script
(`.dev/gen/make_docx.py` in a developer checkout) that lays out one of each
structure the package promises to preserve — headings, mixed Chinese and
English text, bold/italic/underline, numbered and bulleted lists, a table, an
inline picture, a header, a footer, and two footnotes — and then saving it as
Word 97 with LibreOffice 7.4 (`--convert-to 'doc:MS Word 97'`). It is written
by LibreOffice rather than Word, which is worth knowing when reading a failure:
a bug here may be in LibreOffice's `.doc` output rather than in the converter.

The fixtures are redistributable only. Do not add a document that cannot be
redistributed under a license compatible with this project.

## Converted output

`../../fixtures-docx/` holds the result of converting every fixture, so the
output can be inspected without rebuilding. It is git-ignored; regenerate it
with:

```bash
node scripts/convert-fixtures.ts
```

Add `--installed` to load the package from `node_modules` instead of the
in-repository `npm/index.js`.

## Adding a fixture

Prefer documents produced by Microsoft Word. Keep them small. Add the file, add
a row to the table above, and add the name to the `documents` list in
`../conversion.test.ts`. A fixture that is not listed there is dead weight.
