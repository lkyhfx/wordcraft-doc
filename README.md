# @lkyhfx/wordcraft-doc

Convert Word documents from Node.js with a native addon:

- legacy `.doc` files (Word 97–2003, the binary format) → `.docx` or PDF
- `.docx` packages (`docm`, `dotx`, `dotm` too) → PDF

The conversion is done by [WordCraft](https://github.com/storytold/wordcraft):
the `.doc` reader, the DOCX reader and writer, and the PDF exporter are used
directly, unmodified. This package is the Node.js binding around them.

- Node.js 24
- Linux x64 and Linux arm64 (glibc)
- Prebuilt binaries: no Rust toolchain and no LibreOffice needed at install time
- No runtime JavaScript dependencies; the native binary ships in a platform package
- No external office suite, GUI, or background service

## Install

```bash
npm install @lkyhfx/wordcraft-doc
```

## Use

DOC → DOCX:

```js
import { convertDocToDocx } from '@lkyhfx/wordcraft-doc';
import { readFile, writeFile } from 'node:fs/promises';

const input = await readFile('input.doc');
const output = await convertDocToDocx(input);
await writeFile('output.docx', output);
```

DOC → PDF and DOCX → PDF:

```js
import { convertDocToPdf, convertDocxToPdf } from '@lkyhfx/wordcraft-doc';

const pdf = await convertDocToPdf(await readFile('input.doc'));
await writeFile('output.pdf', pdf);

const pdfFromDocx = await convertDocxToPdf(await readFile('input.docx'));
await writeFile('output-from-docx.pdf', pdfFromDocx);
```

For a file on disk, skip the JavaScript-side copy:

```js
import {
  convertDocFileToDocx,
  convertDocFileToPdf,
  convertDocxFileToPdf,
} from '@lkyhfx/wordcraft-doc';

await convertDocFileToDocx('input.doc', 'output.docx');
await convertDocFileToPdf('input.doc', 'output.pdf');
await convertDocxFileToPdf('input.docx', 'output.pdf');
```

`input.doc` and `input.docx` may really be `.dot`, `.docm`, `.dotx` or `.dotm`:
the readers decide from the bytes, not from the file name, so the same functions
handle every variant of each family.

The parsing, layout and rendering work runs on the libuv thread pool. The Buffer
API must snapshot the input before scheduling the worker because JavaScript can
still mutate the original Buffer; that copy happens on the JavaScript thread. For
large documents, prefer the file API: it reads the input on the worker thread
and avoids that JavaScript-side copy.

## API

```ts
interface ConvertOptions {
  /** Password of a protected document. Ignored for unprotected files. */
  password?: string;
  /** Largest accepted input, in bytes. Default 512 MiB. */
  maxInputBytes?: number;
  /** Largest accepted final output size, checked after writing; not a peak-memory cap. Default 1 GiB. */
  maxOutputBytes?: number;
  /** Reject text no installed font can draw, instead of writing missing glyphs. Default true; PDF only. */
  requireFonts?: boolean;
}

function convertDocToDocx(
  input: Buffer,
  options?: ConvertOptions,
): Promise<Buffer>;

function convertDocFileToDocx(
  inputPath: string,
  outputPath: string,
  options?: ConvertOptions,
): Promise<void>;

function convertDocToPdf(
  input: Buffer,
  options?: ConvertOptions,
): Promise<Buffer>;

function convertDocFileToPdf(
  inputPath: string,
  outputPath: string,
  options?: ConvertOptions,
): Promise<void>;

function convertDocxToPdf(
  input: Buffer,
  options?: ConvertOptions,
): Promise<Buffer>;

function convertDocxFileToPdf(
  inputPath: string,
  outputPath: string,
  options?: ConvertOptions,
): Promise<void>;
```

All six functions share `ConvertOptions` and the same error contract.

## Fonts

WordCraft bundles a few Latin OpenType families (Source Sans 3, Source Serif 4,
Inter, JetBrains Mono) and draws every other script with the fonts installed on
the machine. **CJK text needs a CJK font in the deployment image**: install one
of the Noto CJK or Source Han families (for example
`fonts-noto-cjk` on Debian/Ubuntu, `google-noto-sans-cjk-fonts` on Fedora) in the
container that runs the conversion.

When a character cannot be drawn by any installed font, PDF export rejects with
`ERR_WORDCRAFT_FONTS` and names the first few uncovered code points, instead of
silently writing empty boxes:

```js
try {
  await convertDocToPdf(bytes);
} catch (error) {
  if (error.code === 'ERR_WORDCRAFT_FONTS') {
    // install a font that covers the reported characters, or:
    const withBoxes = await convertDocToPdf(bytes, { requireFonts: false });
  }
}
```

No font file is bundled or installed by this package, and no font is looked up
over the network.

## Errors

A rejection is an `Error` with a stable `code`:

| `code` | Meaning |
|---|---|
| `ERR_WORDCRAFT_NOT_A_DOC` | The bytes are not a readable Word 97–2003 document. |
| `ERR_WORDCRAFT_NOT_A_DOCX` | The bytes are not a readable DOCX package. |
| `ERR_WORDCRAFT_PASSWORD_REQUIRED` | The document is protected and no `password` was given. |
| `ERR_WORDCRAFT_WRONG_PASSWORD` | The password does not open the document. |
| `ERR_WORDCRAFT_ENCRYPTED` | The document uses encryption this reader cannot handle. |
| `ERR_WORDCRAFT_MALFORMED` | The file is damaged beyond recovery. |
| `ERR_WORDCRAFT_LIMIT` | The file hit an internal safety limit (stream size, piece count). |
| `ERR_WORDCRAFT_INPUT_TOO_LARGE` | The input exceeds `maxInputBytes`. |
| `ERR_WORDCRAFT_OUTPUT_TOO_LARGE` | The result exceeds `maxOutputBytes`. |
| `ERR_WORDCRAFT_DOCX` | The writer produced an invalid package. |
| `ERR_WORDCRAFT_PDF` | The exporter produced an invalid or empty PDF. |
| `ERR_WORDCRAFT_FONTS` | No installed font can draw the document's text (PDF; see [Fonts](#fonts)). |
| `ERR_WORDCRAFT_IO` | A file could not be read or written. |
| `ERR_WORDCRAFT_PANIC` | An internal failure; the input is reported, not a crash. |

```js
try {
  await convertDocToDocx(bytes);
} catch (error) {
  if (error.code === 'ERR_WORDCRAFT_PASSWORD_REQUIRED') {
    // retry with { password }
  }
}
```

## What is preserved

Text, paragraphs, runs and their character formatting, styles, tables, lists
and numbering, pictures, headers and footers, footnotes and endnotes, comments,
fields, sections and page setup, and document metadata.

The PDF export keeps the page layout, embeds subsetted fonts with a Unicode map
(so text is selectable, searchable and extractable), and writes link annotations
and a document outline from the headings. It is a WordCraft layout, not a
byte-for-byte facsimile of how Word or LibreOffice would paginate a document.

Unknown or damaged structures are skipped: the readers are lenient by design and
bounded, so hostile input yields an error or a best-effort document, never a
crash.

## Scope

This package converts `.doc` to `.docx`, `.doc` to PDF and `.docx` to PDF. It has
no GUI, no CLI, no document editing API, no PNG or image export, and no
dependency on LibreOffice, Microsoft Word, WPS or a background service.

## Size

The prebuilt addon is about 16 MiB per platform (stripped) and covers both the
format crates and the PDF exporter:

| | |
|---|---|
| `wordcraft-docbin`, `wordcraft-doc`, `wordcraft-docx` | the readers and the DOCX writer |
| `wordcraft-pdf` (+ `layout`, `geom`, `metafile`, `proof`, `fonts`) | page layout and PDF writing |
| `craft-pdf`, `krilla`, `skrifa`, `harfrust`, `image` | the PDF backend and font/image handling |

The GUI, the image renderer, the automation Engine, the MCP server and the CLI
are not linked in, and `scripts/package-native.sh` refuses to package a binary
above 64 MiB in case one of them ever creeps in. No font file is shipped beyond
the four small OFL Latin families WordCraft compiles in (about 4 MiB, inside the
binary); CJK fonts come from the system (see [Fonts](#fonts)).

## Platform support

| | |
|---|---|
| Node.js | 24 |
| Linux x64 | `@lkyhfx/wordcraft-doc-linux-x64-gnu` |
| Linux arm64 | `@lkyhfx/wordcraft-doc-linux-arm64-gnu` |
| ABI | Node-API 9 |

The binaries are linked against glibc 2.17 or newer. They do not load on musl
(Alpine) systems.

## Build from source

The upstream reader and writers are a git submodule:

```bash
git clone --recurse-submodules https://github.com/lkyhfx/wordcraft-doc.git
cd wordcraft-doc

npm install                        # dev tooling (napi CLI)
./scripts/build-native.sh --target all
npm test
cargo install cargo-about --locked # required to include third-party Rust license texts
./scripts/package-native.sh
./scripts/test-package.sh

# Convert every test fixture into fixtures-docx/ and fixtures-pdf/ for inspection
node scripts/convert-fixtures.ts
```

The arm64 binary cannot be loaded natively on an x64 machine, but it can be
exercised under qemu with an arm64 Node build:

```bash
qemu-aarch64-static -L /path/to/arm64/rootfs \
  /path/to/arm64/node -e '
    const fs = require("node:fs");
    const addon = require("./npm/wordcraft-doc.linux-arm64-gnu.node");
    (async () => {
      const doc = fs.readFileSync("tests/fixtures/test.doc");
      console.log((await addon.convertDocToDocx(doc)).length, (await addon.convertDocToPdf(doc)).length);
    })();'
```

See [UPSTREAM.md](UPSTREAM.md) for the pinned upstream version and the sync
procedure.

## License

MIT OR Apache-2.0, matching upstream WordCraft. The published main and platform
packages include [NOTICE](NOTICE) and a generated `THIRD-PARTY-LICENSES.md`
containing license texts for the resolved native Rust dependency graph. The
report is generated from `native/Cargo.lock` with `cargo-about` during packaging.
