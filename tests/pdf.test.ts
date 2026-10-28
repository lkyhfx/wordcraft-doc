/**
 * PDF conversion tests for @lkyhfx/wordcraft-doc.
 *
 * Both sources are covered: legacy `.doc` files through `wordcraft-docbin` and
 * `.docx` packages through `wordcraft-docx`, each parsed into the shared
 * document model and written by `wordcraft-pdf`. As in `conversion.test.ts`,
 * every assertion inspects the produced file rather than only checking that the
 * promise resolved: the PDF header, the page objects, the trailer, and the
 * structure of the bytes at the cross-reference offset.
 *
 * Run with:
 *
 *   node --test tests/
 */
import assert from 'node:assert/strict';
import { copyFile, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  convertDocFileToDocx,
  convertDocFileToPdf,
  convertDocToDocx,
  convertDocToPdf,
  convertDocxFileToPdf,
  convertDocxToPdf,
} from '../npm/index.js';
import { buildDocx, zip } from './docx.ts';
import { assertPdf, normalizePdf, pdfContent, readPdf } from './pdf.ts';

const FIXTURES = fileURLToPath(new URL('./fixtures/', import.meta.url));
const fixture = (name: string) => join(FIXTURES, name);

/** Every `.doc` fixture, in the order the DOCX tests use them. */
const DOCUMENTS = ['test.doc', 'testWORD.doc', 'SampleDoc.doc', 'simple-table.doc', 'empty.doc', '47304.doc', 'rich-structures.doc'];

/** A character no font in the test environment covers (Supplementary Private Use Area-B). */
const UNCOVERED = '\u{10FFFD}';

/**
 * Whether the machine running the tests has a font that covers Chinese. The
 * bundled WordCraft faces are Latin-only, so a bare container has none and
 * `rich-structures.doc` (which carries Chinese text) would be refused with
 * `ERR_WORDCRAFT_FONTS`. Probed once, so the fixture tests exercise the default
 * path when a CJK font is installed and `requireFonts: false` when it is not.
 */
let hasCjkFont = false;

let scratch: string;

before(async () => {
  scratch = await mkdtemp(join(tmpdir(), 'wordcraft-doc-pdf-test-'));
  try {
    await convertDocxToPdf(buildDocx(['中文']));
    hasCjkFont = true;
  } catch (error) {
    // Any other failure (a broken install, say) must still fail the suite
    // rather than being read as "no CJK font".
    if ((error as NodeJS.ErrnoException).code !== 'ERR_WORDCRAFT_FONTS') throw error;
    hasCjkFont = false;
  }
});

after(async () => {
  await rm(scratch, { recursive: true, force: true });
});

async function convertDocToPdfBytes(name: string, options?: Parameters<typeof convertDocToPdf>[1]) {
  return convertDocToPdf(await readFile(fixture(name)), options);
}

/**
 * Convert a fixture for PDF. The Chinese fixture needs a CJK font, which the
 * test machine may not have; without one the export is asked for with
 * `requireFonts: false` so the rest of the pipeline is still covered.
 */
async function convertFixtureToPdf(name: string) {
  return convertDocToPdfBytes(name, hasCjkFont ? undefined : { requireFonts: false });
}

// ---------------------------------------------------------------------------
// DOC → PDF
// ---------------------------------------------------------------------------

describe('convertDocToPdf', () => {
  for (const name of DOCUMENTS) {
    test(`converts ${name} into a complete PDF file`, async () => {
      const output = await convertFixtureToPdf(name);
      assert.ok(Buffer.isBuffer(output), `${name}: expected a Buffer`);
      const info = assertPdf(output, name);
      assert.match(info.version, /^1\.\d+$/, `${name}: unexpected PDF version`);
      assert.ok(info.pages >= 1, `${name}: expected at least one page`);
    });
  }

  test('keeps the page count of the document', async () => {
    // rich-structures.doc is a single page; testWORD.doc is longer.
    assert.equal(assertPdf(await convertFixtureToPdf('rich-structures.doc')).pages, 1);
    assert.ok(assertPdf(await convertFixtureToPdf('testWORD.doc')).pages >= 1);
  });

  test('starts with a PDF header and ends with the EOF marker', async () => {
    const output = await convertFixtureToPdf('rich-structures.doc');
    assert.equal(output.subarray(0, 5).toString('latin1'), '%PDF-');
    assert.ok(output.subarray(-16).toString('latin1').includes('%%EOF'), 'no %%EOF in the last 16 bytes');
  });

  test('embeds font subsets and a Unicode map, so the text can be selected', async () => {
    const output = await convertFixtureToPdf('rich-structures.doc');
    const objects = output.toString('latin1');
    // Fonts are embedded (FontFile2/FontFile3) and reachable by name; the
    // Unicode map is what makes the glyphs selectable and searchable.
    assert.ok(objects.includes('/Font'), 'no font object in the PDF');
    assert.ok(/\/FontFile[23]/.test(objects), 'no embedded font program in the PDF');
    assert.ok(objects.includes('/ToUnicode'), 'no Unicode map in the PDF');

    // The content stream draws text: a `BT` block with `Tj`/`TJ` operators.
    const content = pdfContent(output);
    assert.match(content, /\bBT\b/, 'no text object in the content stream');
    assert.match(content, /\bT[Jj]\b/, 'no text-showing operator in the content stream');
    assert.match(content, /\bET\b/, 'unterminated text object');
  });

  test('is deterministic: the same input twice gives the same bytes', async () => {
    // The creation timestamp is the one field that legitimately differs between
    // runs, so it is normalized before comparing.
    const input = await readFile(fixture('rich-structures.doc'));
    const options = hasCjkFont ? undefined : { requireFonts: false };
    const first = await convertDocToPdf(input, options);
    const second = await convertDocToPdf(input, options);
    assert.deepEqual(normalizePdf(first), normalizePdf(second));
  });

  test('returns a Buffer, not a Uint8Array or an array', async () => {
    const output = await convertDocToPdfBytes('simple-table.doc');
    assert.ok(Buffer.isBuffer(output));
    assert.equal(output.constructor.name, 'Buffer');
  });

  test('concurrent conversions do not interfere', async () => {
    const names = ['test.doc', 'testWORD.doc', 'simple-table.doc'];
    const outputs = await Promise.all(names.map((name) => convertFixtureToPdf(name)));
    outputs.forEach((output, index) => assertPdf(output, names[index]));
    assert.notDeepEqual(outputs[0], outputs[1]);
  });
});

// ---------------------------------------------------------------------------
// DOCX → PDF
// ---------------------------------------------------------------------------

describe('convertDocxToPdf', () => {
  test('converts a DOCX produced by this package back into a PDF', async () => {
    const input = await readFile(fixture('rich-structures.doc'));
    const docx = await convertDocToDocx(input);
    const options = hasCjkFont ? undefined : { requireFonts: false };
    const pdf = await convertDocxToPdf(docx, options);
    assertPdf(pdf, 'doc->docx->pdf');
    // The intermediate DOCX re-encodes the document, so the PDF is not required
    // to be byte-identical to the DOC→PDF one, only to be a valid PDF of the
    // same page count.
    assert.equal(readPdf(pdf).pages, readPdf(await convertDocToPdf(input, options)).pages);
  });

  test('converts a hand-built package with text', async () => {
    const docx = buildDocx(['WordCraft DOCX to PDF', 'A second paragraph.']);
    const pdf = await convertDocxToPdf(docx);
    const info = assertPdf(pdf, 'built docx');
    assert.equal(info.pages, 1);
  });

  test('a multi-page package produces several pages', async () => {
    // Enough paragraphs to overflow one Letter page at the default size.
    const paragraphs = Array.from({ length: 200 }, (_, i) => `Paragraph number ${i + 1} of a long document.`);
    const pdf = await convertDocxToPdf(buildDocx(paragraphs));
    assert.ok(assertPdf(pdf).pages >= 2, 'expected more than one page');
  });

  test('converts a package with bold and italic runs', async () => {
    const pdf = await convertDocxToPdf(buildDocx(['bold and italic'], { bold: true, italic: true }));
    assertPdf(pdf, 'styled docx');
  });

  test('an empty package still yields one empty page', async () => {
    const pdf = await convertDocxToPdf(buildDocx([]));
    const info = assertPdf(pdf, 'empty docx');
    assert.equal(info.pages, 1);
  });

  test('is deterministic', async () => {
    const docx = buildDocx(['deterministic output']);
    const first = await convertDocxToPdf(docx);
    const second = await convertDocxToPdf(docx);
    assert.deepEqual(normalizePdf(first), normalizePdf(second));
  });
});

// ---------------------------------------------------------------------------
// The file API
// ---------------------------------------------------------------------------

describe('file APIs', () => {
  test('convertDocFileToPdf writes the same bytes as convertDocToPdf', async () => {
    const target = join(scratch, 'doc.pdf');
    await convertDocFileToPdf(fixture('rich-structures.doc'), target);

    const written = await readFile(target);
    assertPdf(written, 'doc file api');
    // The two runs can land in different seconds; the timestamp is normalized.
    assert.deepEqual(normalizePdf(written), normalizePdf(await convertFixtureToPdf('rich-structures.doc')));
  });

  test('convertDocxFileToPdf writes the same bytes as convertDocxToPdf', async () => {
    const source = join(scratch, 'source.docx');
    const target = join(scratch, 'docx.pdf');
    await convertDocFileToDocx(fixture('test.doc'), source);
    await convertDocxFileToPdf(source, target);

    const written = await readFile(target);
    assertPdf(written, 'docx file api');
    assert.deepEqual(normalizePdf(written), normalizePdf(await convertDocxToPdf(await readFile(source))));
  });

  test('resolve with undefined', async () => {
    const first = join(scratch, 'void-doc.pdf');
    const second = join(scratch, 'void-docx.pdf');
    assert.equal(await convertDocFileToPdf(fixture('empty.doc'), first), undefined);
    const docx = join(scratch, 'void.docx');
    await convertDocFileToDocx(fixture('empty.doc'), docx);
    assert.equal(await convertDocxFileToPdf(docx, second), undefined);
  });

  test('overwrite an existing output file', async () => {
    const target = join(scratch, 'overwrite.pdf');
    await writeFile(target, 'stale content, longer than a short PDF header');
    await convertDocFileToPdf(fixture('test.doc'), target);
    assertPdf(await readFile(target), 'overwritten');
  });

  test('reject identical input and output paths without touching the source', async () => {
    const source = join(scratch, 'same.doc');
    await copyFile(fixture('test.doc'), source);
    const original = await readFile(source);

    await assert.rejects(convertDocFileToPdf(source, source), { code: 'ERR_WORDCRAFT_IO' });
    assert.deepEqual(await readFile(source), original);
  });

  test('keep an existing output untouched when the conversion fails', async () => {
    const source = join(scratch, 'bad-docx.docx');
    const target = join(scratch, 'preserved.pdf');
    const marker = Buffer.from('an existing output must survive a failed conversion');
    await writeFile(source, 'this is not a DOCX package');
    await writeFile(target, marker);

    await assert.rejects(convertDocxFileToPdf(source, target), { code: 'ERR_WORDCRAFT_NOT_A_DOCX' });
    assert.deepEqual(await readFile(target), marker);
  });

  test('reject a missing input file', async () => {
    await assert.rejects(convertDocxFileToPdf(fixture('nope.docx'), join(scratch, 'x.pdf')), { code: 'ERR_WORDCRAFT_IO' });
    await assert.rejects(convertDocFileToPdf(fixture('nope.doc'), join(scratch, 'y.pdf')), { code: 'ERR_WORDCRAFT_IO' });
  });

  test('reject a missing output directory', async () => {
    await assert.rejects(convertDocFileToPdf(fixture('test.doc'), join(scratch, 'no', 'such', 'dir.pdf')), {
      code: 'ERR_WORDCRAFT_IO',
    });
  });

  test('apply the input limit before reading the file', async () => {
    const size = (await stat(fixture('test.doc'))).size;
    await assert.rejects(convertDocFileToPdf(fixture('test.doc'), join(scratch, 'limited.pdf'), { maxInputBytes: size - 1 }), {
      code: 'ERR_WORDCRAFT_INPUT_TOO_LARGE',
    });
  });
});

// ---------------------------------------------------------------------------
// Invalid input and error handling
// ---------------------------------------------------------------------------

describe('rejects input that is not a readable document', () => {
  test('plain text as a .doc', async () => {
    await assert.rejects(convertDocToPdf(Buffer.from('definitely not a Word document')), (error: NodeJS.ErrnoException) => {
      assert.equal(error.code, 'ERR_WORDCRAFT_NOT_A_DOC');
      assert.ok(error.message.length > 0);
      return true;
    });
  });

  test('an empty buffer as a .doc', async () => {
    await assert.rejects(convertDocToPdf(Buffer.alloc(0)), { code: 'ERR_WORDCRAFT_NOT_A_DOC' });
  });

  test('a truncated .doc', async () => {
    const full = await readFile(fixture('test.doc'));
    await assert.rejects(convertDocToPdf(full.subarray(0, 1024)), { code: 'ERR_WORDCRAFT_NOT_A_DOC' });
  });

  test('plain text as a .docx', async () => {
    await assert.rejects(convertDocxToPdf(Buffer.from('definitely not a DOCX package')), { code: 'ERR_WORDCRAFT_NOT_A_DOCX' });
  });

  test('an empty buffer as a .docx', async () => {
    await assert.rejects(convertDocxToPdf(Buffer.alloc(0)), { code: 'ERR_WORDCRAFT_NOT_A_DOCX' });
  });

  test('a zip archive without a document part', async () => {
    const package_ = zip([['[Content_Types].xml', '<Types/>']]);
    await assert.rejects(convertDocxToPdf(package_), { code: 'ERR_WORDCRAFT_NOT_A_DOCX' });
  });

  test('a truncated .docx', async () => {
    const docx = await convertDocToDocx(await readFile(fixture('test.doc')));
    await assert.rejects(convertDocxToPdf(docx.subarray(0, Math.floor(docx.length / 2))), { code: 'ERR_WORDCRAFT_NOT_A_DOCX' });
  });

  test('a .doc fed in as if it were a .docx', async () => {
    await assert.rejects(convertDocxToPdf(await readFile(fixture('test.doc'))), { code: 'ERR_WORDCRAFT_NOT_A_DOCX' });
  });

  test('random bytes as a .docx', async () => {
    const noise = Buffer.alloc(4096);
    for (let i = 0; i < noise.length; i += 1) noise[i] = (i * 37) & 0xff;
    await assert.rejects(convertDocxToPdf(noise), (error: NodeJS.ErrnoException) => {
      assert.match(error.code ?? '', /^ERR_WORDCRAFT_/);
      return true;
    });
  });

  test('never rejects with a non-Error', async () => {
    for (const convert of [convertDocToPdf, convertDocxToPdf]) {
      try {
        await convert(Buffer.from('nope'));
        assert.fail('should have rejected');
      } catch (error) {
        assert.ok(error instanceof Error, 'rejection value must be an Error');
        assert.equal(typeof (error as NodeJS.ErrnoException).code, 'string');
      }
    }
  });
});

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

describe('size limits', () => {
  test('maxInputBytes rejects a document above the limit', async () => {
    const input = await readFile(fixture('test.doc'));
    await assert.rejects(convertDocToPdf(input, { maxInputBytes: 1024 }), { code: 'ERR_WORDCRAFT_INPUT_TOO_LARGE' });
  });

  test('maxInputBytes equal to the size is accepted', async () => {
    const input = await readFile(fixture('test.doc'));
    assertPdf(await convertDocToPdf(input, { maxInputBytes: input.length }));
  });

  test('maxOutputBytes rejects a PDF that would be larger', async () => {
    const input = await readFile(fixture('test.doc'));
    await assert.rejects(convertDocToPdf(input, { maxOutputBytes: 1024 }), { code: 'ERR_WORDCRAFT_OUTPUT_TOO_LARGE' });
  });

  test('maxOutputBytes applies to the DOCX path too', async () => {
    const docx = buildDocx(['a paragraph']);
    await assert.rejects(convertDocxToPdf(docx, { maxOutputBytes: 512 }), { code: 'ERR_WORDCRAFT_OUTPUT_TOO_LARGE' });
  });

  test('limits do not otherwise change the output', async () => {
    const input = await readFile(fixture('simple-table.doc'));
    const plain = await convertDocToPdf(input);
    const limited = await convertDocToPdf(input, { maxInputBytes: 1 << 24, maxOutputBytes: 1 << 24 });
    assert.deepEqual(normalizePdf(plain), normalizePdf(limited));
  });
});

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------

describe('fonts', () => {
  test('reports a character no installed font can draw', async () => {
    const docx = buildDocx([`Latin text, then an uncovered character: ${UNCOVERED}`]);
    await assert.rejects(convertDocxToPdf(docx), (error: NodeJS.ErrnoException) => {
      assert.equal(error.code, 'ERR_WORDCRAFT_FONTS');
      // The message must name the character and say what to install.
      assert.match(error.message, /U\+10FFFD/);
      assert.match(error.message, /font/i);
      assert.match(error.message, /requireFonts/);
      return true;
    });
  });

  test('requireFonts: false exports with missing glyphs instead', async () => {
    const docx = buildDocx([`Latin text, then an uncovered character: ${UNCOVERED}`]);
    const pdf = await convertDocxToPdf(docx, { requireFonts: false });
    assertPdf(pdf, 'missing glyphs allowed');
  });

  test('does not reject ordinary Latin text', async () => {
    // The bundled OFL faces cover Latin, so a default install exports without
    // any system font at all.
    assertPdf(await convertDocxToPdf(buildDocx(['The quick brown fox jumps over the lazy dog.'])), 'latin');
  });

  test('does not reject documents whose text the system fonts cover', async () => {
    for (const name of DOCUMENTS) assertPdf(await convertFixtureToPdf(name), name);
  });

  test('the Chinese fixture is exported either way, and refused only when the font is absent', async () => {
    const input = await readFile(fixture('rich-structures.doc'));
    if (hasCjkFont) {
      // A CJK font is installed: the default (strict) path must succeed.
      assertPdf(await convertDocToPdf(input), 'cjk present');
    } else {
      // No CJK font: the strict path names the characters rather than writing boxes.
      await assert.rejects(convertDocToPdf(input), (error: NodeJS.ErrnoException) => {
        assert.equal(error.code, 'ERR_WORDCRAFT_FONTS');
        assert.match(error.message, /U\+[0-9A-F]{4,6}/);
        return true;
      });
      // And the opt-out still produces a valid PDF.
      assertPdf(await convertDocToPdf(input, { requireFonts: false }), 'cjk absent');
    }
  });

  test('the font check does not change the DOCX output', async () => {
    const input = await readFile(fixture('test.doc'));
    const withCheck = await convertDocToDocx(input, { requireFonts: true });
    const without = await convertDocToDocx(input, { requireFonts: false });
    assert.deepEqual(withCheck, without);
  });
});

// ---------------------------------------------------------------------------
// Compatibility with the existing DOC → DOCX surface
// ---------------------------------------------------------------------------

describe('DOC to DOCX compatibility', () => {
  test('the DOCX output is unchanged by the PDF feature', async () => {
    const input = await readFile(fixture('rich-structures.doc'));
    const output = await convertDocToDocx(input);
    assert.equal(output.readUInt32LE(0), 0x04034b50, 'expected a zip local header');
    // A document's DOCX is produced by wordcraft-docx alone; the PDF path must
    // not have changed how it is parsed.
    assert.deepEqual(output, await convertDocToDocx(input));
  });

  test('the two targets agree on what they accept', async () => {
    const input = await readFile(fixture('test.doc'));
    await assert.rejects(convertDocToDocx(Buffer.from('nope')), { code: 'ERR_WORDCRAFT_NOT_A_DOC' });
    await assert.rejects(convertDocToPdf(Buffer.from('nope')), { code: 'ERR_WORDCRAFT_NOT_A_DOC' });
    assert.ok((await convertDocToDocx(input)).length > 0);
    assert.ok((await convertDocToPdf(input)).length > 0);
  });
});
