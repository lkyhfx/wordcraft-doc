/**
 * Build a minimal, valid DOCX package in memory.
 *
 * The PDF tests need a `.docx` input whose text the test controls — a character
 * no installed font can draw, an empty document, a damaged package — and none of
 * the `.doc` fixtures can express that. Writing the package here keeps the tests
 * free of fixtures and of any dependency; `tests/zip.ts` already knows how to
 * read the result back.
 *
 * This is a test helper, not a converter: it writes three parts and nothing else.
 */
import { deflateRawSync } from 'node:zlib';

const CONTENT_TYPES =
  '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
  '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
  '<Default Extension="xml" ContentType="application/xml"/>' +
  '<Override PartName="/word/document.xml" ' +
  'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
  '</Types>';

const ROOT_RELS =
  '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
  '<Relationship Id="rId1" ' +
  'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" ' +
  'Target="word/document.xml"/>' +
  '</Relationships>';

export interface DocxParagraphOptions {
  /** Run properties: `bold`, `italic`, `underline`, `size` (half-points). */
  bold?: boolean;
  italic?: boolean;
  size?: number;
}

/** XML-escape the five entities WordprocessingML needs. */
function escapeXml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/** The document part for one paragraph per string. */
function documentXml(paragraphs: string[], options: DocxParagraphOptions = {}): string {
  const props: string[] = [];
  if (options.bold) props.push('<w:b/>');
  if (options.italic) props.push('<w:i/>');
  if (options.size) props.push(`<w:sz w:val="${options.size}"/>`);
  const runProps = props.length > 0 ? `<w:rPr>${props.join('')}</w:rPr>` : '';
  const body = paragraphs
    .map((text) => `<w:p><w:r>${runProps}<w:t xml:space="preserve">${escapeXml(text)}</w:t></w:r></w:p>`)
    .join('');
  return (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
    `<w:body>${body}<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body>` +
    '</w:document>'
  );
}

// ---------------------------------------------------------------------------
// A tiny zip writer (stored or deflated entries, no zip64, no encryption)
// ---------------------------------------------------------------------------

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(bytes: Buffer): number {
  let c = 0xffffffff;
  for (const byte of bytes) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** Zip the entries into an archive, deflating each one. */
export function zip(entries: [string, string | Buffer][]): Buffer {
  const local: Buffer[] = [];
  const central: Buffer[] = [];
  let offset = 0;

  for (const [name, content] of entries) {
    const data = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
    const nameBytes = Buffer.from(name, 'utf8');
    const compressed = deflateRawSync(data);
    const crc = crc32(data);

    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4); // version needed
    header.writeUInt16LE(0, 6); // flags
    header.writeUInt16LE(8, 8); // deflate
    header.writeUInt16LE(0, 10); // time
    header.writeUInt16LE(0, 12); // date
    header.writeUInt32LE(crc, 14);
    header.writeUInt32LE(compressed.length, 18);
    header.writeUInt32LE(data.length, 22);
    header.writeUInt16LE(nameBytes.length, 26);
    header.writeUInt16LE(0, 28); // extra length
    local.push(header, nameBytes, compressed);

    const directory = Buffer.alloc(46);
    directory.writeUInt32LE(0x02014b50, 0);
    directory.writeUInt16LE(20, 4); // version made by
    directory.writeUInt16LE(20, 6); // version needed
    directory.writeUInt16LE(0, 8); // flags
    directory.writeUInt16LE(8, 10); // deflate
    directory.writeUInt16LE(0, 12); // time
    directory.writeUInt16LE(0, 14); // date
    directory.writeUInt32LE(crc, 16);
    directory.writeUInt32LE(compressed.length, 20);
    directory.writeUInt32LE(data.length, 24);
    directory.writeUInt16LE(nameBytes.length, 28);
    directory.writeUInt32LE(offset, 42);
    central.push(directory, nameBytes);

    offset += header.length + nameBytes.length + compressed.length;
  }

  const localPart = Buffer.concat(local);
  const centralPart = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralPart.length, 12);
  end.writeUInt32LE(localPart.length, 16);
  return Buffer.concat([localPart, centralPart, end]);
}

/** A minimal DOCX package holding one paragraph per string. */
export function buildDocx(paragraphs: string[], options: DocxParagraphOptions = {}): Buffer {
  return zip([
    ['[Content_Types].xml', CONTENT_TYPES],
    ['_rels/.rels', ROOT_RELS],
    ['word/document.xml', documentXml(paragraphs, options)],
  ]);
}
