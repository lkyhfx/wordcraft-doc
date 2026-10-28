/**
 * Conversion tests for @lkyhfx/wordcraft-doc.
 *
 * Every assertion checks the produced DOCX itself — is it a valid package, is
 * the body non-empty, did the text and the structures survive — never just that
 * the call resolved. Run with:
 *
 *   node --test tests/
 */
import assert from 'node:assert/strict';
import { copyFile, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { convertDocFileToDocx, convertDocToDocx } from '../npm/index.js';
import { countTag, readZipMap, xmlTexts } from './zip.ts';

const FIXTURES = fileURLToPath(new URL('./fixtures/', import.meta.url));

const fixture = (name: string) => join(FIXTURES, name);

/** Read a fixture and convert it, failing the test with a readable message. */
async function convert(name: string, options?: Parameters<typeof convertDocToDocx>[1]) {
  const input = await readFile(fixture(name));
  return convertDocToDocx(input, options);
}

/** Assert the bytes are a DOCX package; return its parts. */
function assertDocxPackage(bytes: Buffer, label = 'output') {
  assert.ok(Buffer.isBuffer(bytes), `${label}: expected a Buffer`);
  assert.ok(bytes.length > 0, `${label}: expected non-empty bytes`);
  assert.equal(bytes.readUInt32LE(0), 0x04034b50, `${label}: expected a zip local header`);

  const parts = readZipMap(bytes);
  for (const required of ['[Content_Types].xml', '_rels/.rels', 'word/document.xml']) {
    assert.ok(parts.has(required), `${label}: missing ${required}`);
    assert.ok(parts.get(required)!.length > 0, `${label}: ${required} is empty`);
  }
  return parts;
}

/** The visible text of the main document part. */
function bodyText(parts: Map<string, Buffer>): string {
  return xmlTexts(parts.get('word/document.xml')!.toString('utf8')).join('');
}

let scratch: string;

before(async () => {
  scratch = await mkdtemp(join(tmpdir(), 'wordcraft-doc-test-'));
});

after(async () => {
  await rm(scratch, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// Correctness
// ---------------------------------------------------------------------------

describe('representation formats', () => {
  const documents = [
    'test.doc',
    'testWORD.doc',
    'SampleDoc.doc',
    'simple-table.doc',
    'empty.doc',
    '47304.doc',
    'rich-structures.doc',
  ];

  for (const name of documents) {
    test(`converts ${name} into a readable DOCX package`, async () => {
      const output = await convert(name);
      const parts = assertDocxPackage(output, name);
      assert.ok(parts.has('word/styles.xml'), `${name}: no styles part`);
      // Even an empty document has a body element and a section.
      const documentXml = parts.get('word/document.xml')!.toString('utf8');
      assert.ok(documentXml.includes('<w:body>'), `${name}: no body`);
      assert.ok(countTag(documentXml, 'w:sectPr') >= 1, `${name}: no section properties`);
    });
  }
});

test('returns a Buffer, not a Uint8Array or an array', async () => {
  const output = await convert('test.doc');
  assert.ok(Buffer.isBuffer(output));
  assert.equal(output.constructor.name, 'Buffer');
});

test('preserves the metadata of a document that has it', async () => {
  const output = await convert('testWORD.doc');
  const parts = assertDocxPackage(output);
  const core = parts.get('docProps/core.xml');
  assert.ok(core, 'expected docProps/core.xml');
  const xml = core.toString('utf8');
  assert.match(xml, /<dc:title>Sample Word Document<\/dc:title>/);
});

// ---------------------------------------------------------------------------
// Content: the structures the requirement lists
// ---------------------------------------------------------------------------

describe('document structures survive the round trip', () => {
  let parts: Map<string, Buffer>;
  let documentXml: string;

  before(async () => {
    parts = assertDocxPackage(await convert('rich-structures.doc'), 'rich');
    documentXml = parts.get('word/document.xml')!.toString('utf8');
  });

  test('keeps the English text', () => {
    const text = bodyText(parts);
    assert.ok(text.includes('WordCraft DOC to DOCX'), 'heading text missing');
    assert.ok(text.includes('bold text'), 'bold run missing');
    assert.ok(text.includes('italic text'), 'italic run missing');
    assert.ok(text.includes('underlined'), 'underlined run missing');
    assert.ok(text.includes('row one'), 'table cell missing');
  });

  test('keeps the Chinese text intact (mixed Chinese and English)', () => {
    const text = bodyText(parts);
    // These exact characters are what the fixture's source .docx carried.
    assert.ok(text.includes('中文正文'), `CJK text damaged: ${text.slice(0, 120)}`);
    assert.ok(text.includes('包含标点'), 'CJK punctuation damaged');
    assert.ok(text.includes('第二项'), 'CJK list item missing');
    assert.ok(text.includes('表格'), 'CJK table heading missing');
    assert.ok(text.includes('名称'), 'CJK table header missing');
  });

  test('keeps special characters and entities', () => {
    const text = bodyText(parts);
    assert.ok(text.includes('&'), 'ampersand lost');
    assert.ok(text.includes('<'), 'less-than lost');
    assert.ok(text.includes('>'), 'greater-than lost');
    assert.ok(text.includes('\u201cquotes\u201d'), 'smart quotes lost');
    assert.ok(text.includes('\u2014 dash'), 'em dash lost');
    assert.ok(text.includes('\u00e9\u00e8\u00fc'), 'accented letters lost');
    assert.ok(text.includes('\u20ac 100'), 'euro sign lost');
  });

  test('keeps bold, italic and underline as run properties', () => {
    assert.ok(countTag(documentXml, 'w:b') >= 1, 'no bold runs');
    assert.ok(countTag(documentXml, 'w:i') >= 1, 'no italic runs');
    assert.ok(countTag(documentXml, 'w:u') >= 1, 'no underlined runs');
  });

  test('keeps the table as a real table', () => {
    assert.ok(countTag(documentXml, 'w:tbl') >= 1, 'no table');
    assert.ok(countTag(documentXml, 'w:tr') >= 3, 'expected header plus two rows');
    assert.ok(countTag(documentXml, 'w:tc') >= 6, 'expected two columns per row');
  });

  test('keeps the picture and its media part', () => {
    const media = [...parts.keys()].filter((name) => name.startsWith('word/media/'));
    assert.ok(media.length >= 1, `no media part; parts: ${[...parts.keys()].join(', ')}`);
    for (const name of media) {
      assert.ok(parts.get(name)!.length > 0, `${name} is empty`);
    }
    const hasDrawing = documentXml.includes('<w:drawing>') || documentXml.includes('<w:pict>');
    assert.ok(hasDrawing, 'no drawing element for the image');
  });

  test('keeps the header and the footer', () => {
    const headers = [...parts.keys()].filter((n) => /^word\/header\d+\.xml$/.test(n));
    const footers = [...parts.keys()].filter((n) => /^word\/footer\d+\.xml$/.test(n));
    assert.ok(headers.length >= 1, 'no header part');
    assert.ok(footers.length >= 1, 'no footer part');
    assert.ok(documentXml.includes('<w:headerReference'), 'body has no header reference');
    assert.ok(documentXml.includes('<w:footerReference'), 'body has no footer reference');
    const headerText = xmlTexts(parts.get(headers[0])!.toString('utf8')).join('');
    assert.ok(headerText.length > 0, 'header part has no text');
  });

  test('keeps the footnotes', () => {
    const notes = parts.get('word/footnotes.xml');
    assert.ok(notes, 'no footnotes part');
    const notesXml = notes.toString('utf8');
    const noteText = xmlTexts(notesXml).join('');
    assert.ok(noteText.includes('footnote text'), `footnote text missing: ${noteText}`);
    assert.ok(noteText.includes('中文'), 'the second footnote missing');
    assert.ok(documentXml.includes('<w:footnoteReference'), 'body has no footnote reference');
  });

  test('keeps numbering as a numbering part plus list references', () => {
    assert.ok(parts.has('word/numbering.xml'), 'no numbering part');
    assert.ok(documentXml.includes('<w:numPr>'), 'no list paragraphs');
    assert.ok(documentXml.includes('<w:numId'), 'no list references');
  });
});

// ---------------------------------------------------------------------------
// Broken and hostile input
// ---------------------------------------------------------------------------

describe('rejects input that is not a readable .doc', () => {
  test('plain text', async () => {
    await assert.rejects(
      convertDocToDocx(Buffer.from('this is definitely not a Word document')),
      (error: NodeJS.ErrnoException) => {
        assert.equal(error.code, 'ERR_WORDCRAFT_NOT_A_DOC');
        assert.ok(error.message.length > 0);
        return true;
      },
    );
  });

  test('an empty buffer', async () => {
    await assert.rejects(convertDocToDocx(Buffer.alloc(0)), { code: 'ERR_WORDCRAFT_NOT_A_DOC' });
  });

  test('a truncated .doc', async () => {
    const full = await readFile(fixture('test.doc'));
    await assert.rejects(convertDocToDocx(full.subarray(0, 1024)), { code: 'ERR_WORDCRAFT_NOT_A_DOC' });
  });

  test('a .docx fed in as if it were a .doc', async () => {
    const docx = await convert('test.doc');
    await assert.rejects(convertDocToDocx(docx), { code: 'ERR_WORDCRAFT_NOT_A_DOC' });
  });

  test('random bytes', async () => {
    const noise = Buffer.alloc(4096);
    for (let i = 0; i < noise.length; i += 1) noise[i] = (i * 37) & 0xff;
    await assert.rejects(convertDocToDocx(noise), (error: NodeJS.ErrnoException) => {
      assert.match(error.code ?? '', /^ERR_WORDCRAFT_/);
      return true;
    });
  });

  test('never rejects with a non-Error', async () => {
    try {
      await convertDocToDocx(Buffer.from('nope'));
      assert.fail('should have rejected');
    } catch (error) {
      assert.ok(error instanceof Error, 'rejection value must be an Error');
      assert.equal(typeof (error as NodeJS.ErrnoException).code, 'string');
    }
  });
});

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

describe('size limits', () => {
  test('maxInputBytes rejects a document above the limit', async () => {
    const input = await readFile(fixture('test.doc'));
    await assert.rejects(convertDocToDocx(input, { maxInputBytes: 1024 }), {
      code: 'ERR_WORDCRAFT_INPUT_TOO_LARGE',
    });
  });

  test('maxInputBytes equal to the size is accepted', async () => {
    const input = await readFile(fixture('test.doc'));
    const output = await convertDocToDocx(input, { maxInputBytes: input.length });
    assertDocxPackage(output);
  });

  test('maxOutputBytes rejects a document whose DOCX would be larger', async () => {
    const input = await readFile(fixture('test.doc'));
    await assert.rejects(convertDocToDocx(input, { maxOutputBytes: 1024 }), {
      code: 'ERR_WORDCRAFT_OUTPUT_TOO_LARGE',
    });
  });

  test('limits do not otherwise change the output', async () => {
    const input = await readFile(fixture('simple-table.doc'));
    const plain = await convertDocToDocx(input);
    const limited = await convertDocToDocx(input, { maxInputBytes: 1 << 24, maxOutputBytes: 1 << 24 });
    assert.deepEqual(plain, limited);
  });
});

// ---------------------------------------------------------------------------
// Passwords
// ---------------------------------------------------------------------------

describe('password option', () => {
  test('is ignored for an unprotected document', async () => {
    const input = await readFile(fixture('test.doc'));
    const withPassword = await convertDocToDocx(input, { password: 'unused' });
    const without = await convertDocToDocx(input);
    assert.deepEqual(withPassword, without);
  });

  test('an empty password is treated as no password', async () => {
    const input = await readFile(fixture('test.doc'));
    const withEmpty = await convertDocToDocx(input, { password: '' });
    const without = await convertDocToDocx(input);
    assert.deepEqual(withEmpty, without);
  });
});

// ---------------------------------------------------------------------------
// The file API
// ---------------------------------------------------------------------------

describe('convertDocFileToDocx', () => {
  test('writes a DOCX file identical to the Buffer API output', async () => {
    const target = join(scratch, 'file-api.docx');
    await convertDocFileToDocx(fixture('test.doc'), target);

    const written = await readFile(target);
    assertDocxPackage(written, 'file-api');

    const fromBuffer = await convert('test.doc');
    assert.deepEqual(written, fromBuffer, 'the file API must produce the same bytes');
  });

  test('resolves with undefined', async () => {
    const target = join(scratch, 'void.docx');
    const result = await convertDocFileToDocx(fixture('empty.doc'), target);
    assert.equal(result, undefined);
  });

  test('overwrites an existing output file', async () => {
    const target = join(scratch, 'overwrite.docx');
    await writeFile(target, 'stale content that is longer than nothing');
    await convertDocFileToDocx(fixture('test.doc'), target);
    const written = await readFile(target);
    assertDocxPackage(written);
    assert.ok(written.length > 100);
  });

  test('rejects identical input and output paths without modifying the source', async () => {
    const source = join(scratch, 'same-path.doc');
    await copyFile(fixture('test.doc'), source);
    const original = await readFile(source);

    await assert.rejects(convertDocFileToDocx(source, source), {
      code: 'ERR_WORDCRAFT_IO',
    });
    assert.deepEqual(await readFile(source), original);
  });

  test('keeps an existing output untouched when conversion fails', async () => {
    const source = join(scratch, 'invalid-source.doc');
    const target = join(scratch, 'preserved-output.docx');
    const marker = Buffer.from('existing output must survive a failed conversion');
    await writeFile(source, 'not a Word document');
    await writeFile(target, marker);

    await assert.rejects(convertDocFileToDocx(source, target), {
      code: 'ERR_WORDCRAFT_NOT_A_DOC',
    });
    assert.deepEqual(await readFile(target), marker);
  });

  test('rejects when the input file does not exist', async () => {
    await assert.rejects(convertDocFileToDocx(join(FIXTURES, 'nope.doc'), join(scratch, 'x.docx')), {
      code: 'ERR_WORDCRAFT_IO',
    });
  });

  test('rejects when the output directory does not exist', async () => {
    await assert.rejects(convertDocFileToDocx(fixture('test.doc'), join(scratch, 'no', 'such', 'dir.docx')), {
      code: 'ERR_WORDCRAFT_IO',
    });
  });

  test('applies the input limit before reading the file', async () => {
    await assert.rejects(
      convertDocFileToDocx(fixture('test.doc'), join(scratch, 'y.docx'), { maxInputBytes: 16 }),
      { code: 'ERR_WORDCRAFT_INPUT_TOO_LARGE' },
    );
  });

  test('rejects a directory as input', async () => {
    await assert.rejects(convertDocFileToDocx(FIXTURES, join(scratch, 'z.docx')), {
      code: 'ERR_WORDCRAFT_IO',
    });
  });
});

// ---------------------------------------------------------------------------
// Runtime behaviour
// ---------------------------------------------------------------------------

test('does not block the event loop while converting', async () => {
  // A timer scheduled before the conversion must fire while it runs: the work
  // happens on the libuv pool, not on the JavaScript thread.
  const input = await readFile(fixture('test.doc'));
  let ticks = 0;
  const timer = setInterval(() => {
    ticks += 1;
  }, 1);
  try {
    await Promise.all(Array.from({ length: 8 }, () => convertDocToDocx(input)));
  } finally {
    clearInterval(timer);
  }
  assert.ok(ticks > 0, `the event loop was blocked (ticks=${ticks})`);
});

test('runs independent conversions concurrently', async () => {
  const names = ['test.doc', 'testWORD.doc', 'SampleDoc.doc', 'simple-table.doc'];
  const outputs = await Promise.all(names.map((name) => convert(name)));
  outputs.forEach((output, index) => assertDocxPackage(output, names[index]));
  // Concurrent runs must not cross-contaminate each other.
  assert.notDeepEqual(outputs[0], outputs[1]);
});

test('is deterministic: the same input twice gives the same bytes', async () => {
  const input = await readFile(fixture('rich-structures.doc'));
  const first = await convertDocToDocx(input);
  const second = await convertDocToDocx(input);
  assert.deepEqual(first, second);
});

test('a large document converts without hitting a limit', async () => {
  // The fixture is small, so this only asserts the path works for the biggest
  // real sample available; the limit tests cover the enforced bounds.
  const biggest = 'test.doc';
  const size = (await stat(fixture(biggest))).size;
  assert.ok(size > 0);
  const output = await convert(biggest);
  assertDocxPackage(output, biggest);
});
