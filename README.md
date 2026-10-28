# @lkyhfx/wordcraft-doc

Convert legacy Word `.doc` files (Word 97–2003, the binary format) into `.docx`
packages, from Node.js, with a native addon.

The conversion is done by [WordCraft](https://github.com/storytold/wordcraft):
the `.doc` reader and the DOCX writer are used directly, unmodified. This
package is the Node.js binding around them.

- Node.js 24
- Linux x64 and Linux arm64 (glibc)
- Prebuilt binaries: no Rust toolchain and no LibreOffice needed at install time
- No runtime JavaScript dependencies; the native binary ships in a platform package

## Install

```bash
npm install @lkyhfx/wordcraft-doc
```

## Use

```js
import { convertDocToDocx } from '@lkyhfx/wordcraft-doc';
import { readFile, writeFile } from 'node:fs/promises';

const input = await readFile('input.doc');
const output = await convertDocToDocx(input);
await writeFile('output.docx', output);
```

For a file on disk, skip the JavaScript-side copy:

```js
import { convertDocFileToDocx } from '@lkyhfx/wordcraft-doc';

await convertDocFileToDocx('input.doc', 'output.docx');
```

The parsing and writing work runs on the libuv thread pool. The Buffer API must
snapshot the input before scheduling the worker because JavaScript can still
mutate the original Buffer; that copy happens on the JavaScript thread. For
large documents, prefer the file API: it reads the input on the worker thread
and avoids that JavaScript-side copy.

## API

```ts
interface ConvertOptions {
  /** Password of a protected document. Ignored for unprotected files. */
  password?: string;
  /** Largest accepted input, in bytes. Default 512 MiB. */
  maxInputBytes?: number;
  /** Largest accepted final DOCX size, checked after writing; not a peak-memory cap. Default 1 GiB. */
  maxOutputBytes?: number;
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
```

## Errors

A rejection is an `Error` with a stable `code`:

| `code` | Meaning |
|---|---|
| `ERR_WORDCRAFT_NOT_A_DOC` | The bytes are not a readable Word 97–2003 document. |
| `ERR_WORDCRAFT_PASSWORD_REQUIRED` | The document is protected and no `password` was given. |
| `ERR_WORDCRAFT_WRONG_PASSWORD` | The password does not open the document. |
| `ERR_WORDCRAFT_ENCRYPTED` | The document uses encryption this reader cannot handle. |
| `ERR_WORDCRAFT_MALFORMED` | The file is damaged beyond recovery. |
| `ERR_WORDCRAFT_LIMIT` | The file hit an internal safety limit (stream size, piece count). |
| `ERR_WORDCRAFT_INPUT_TOO_LARGE` | The input exceeds `maxInputBytes`. |
| `ERR_WORDCRAFT_OUTPUT_TOO_LARGE` | The result exceeds `maxOutputBytes`. |
| `ERR_WORDCRAFT_DOCX` | The writer produced an invalid package. |
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

Unknown or damaged structures are skipped: the reader is lenient by design and
bounded, so hostile input yields an error or a best-effort document, never a
crash.

## Scope

This package converts DOC to DOCX and nothing else. It has no PDF export, no
rendering, no GUI, no CLI and no document editing API.

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

The upstream reader and writer are a git submodule:

```bash
git clone --recurse-submodules https://github.com/lkyhfx/wordcraft-doc.git
cd wordcraft-doc

npm install                        # dev tooling (napi CLI)
./scripts/build-native.sh --target all
npm test
cargo install cargo-about --locked # required to include third-party Rust license texts
./scripts/package-native.sh
./scripts/test-package.sh

# Convert every test fixture into fixtures-docx/ for inspection
node scripts/convert-fixtures.ts
```

See [UPSTREAM.md](UPSTREAM.md) for the pinned upstream version and the sync
procedure.

## License

MIT OR Apache-2.0, matching upstream WordCraft. The published main and platform
packages include [NOTICE](NOTICE) and a generated `THIRD-PARTY-LICENSES.md`
containing license texts for the resolved native Rust dependency graph. The
report is generated from `native/Cargo.lock` with `cargo-about` during packaging.
