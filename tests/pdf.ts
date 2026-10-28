/**
 * A minimal PDF reader for the tests, enough to verify the files this package
 * writes without pulling in a PDF library.
 *
 * It knows three things about the format: the header, the trailer
 * (`startxref` / `%%EOF`), and how to walk the indirect objects to inflate a
 * stream. That is exactly what the assertions here need, and no PDF library
 * becomes a test dependency.
 */
import { inflateSync } from 'node:zlib';

export interface PdfInfo {
  /** The `%PDF-x.y` version from the header. */
  version: string;
  /** Number of page objects (`/Type /Page`, not the `/Type /Pages` tree node). */
  pages: number;
  /** The byte offset the trailer points at; it must land on an `xref` table. */
  xrefOffset: number;
}

/** Throw unless `bytes` is a complete PDF file; return what was read. */
export function readPdf(bytes: Buffer): PdfInfo {
  if (!Buffer.isBuffer(bytes)) throw new Error('not a Buffer');
  if (bytes.length < 16) throw new Error(`too short to be a PDF: ${bytes.length} bytes`);
  const header = bytes.subarray(0, 8).toString('latin1');
  const match = /^%PDF-(\d+\.\d+)$/.exec(header);
  if (!match) throw new Error(`bad PDF header: ${JSON.stringify(header)}`);

  const text = bytes.toString('latin1');
  // The xref offset and the EOF marker live in the trailer at the very end; a
  // 2 KiB window is far more than the last few objects ever need.
  const tail = text.slice(Math.max(0, text.length - 2048));
  const startxref = tail.lastIndexOf('startxref');
  if (startxref < 0) throw new Error('no startxref keyword; the PDF is truncated');
  const offset = /\d+/.exec(tail.slice(startxref + 'startxref'.length));
  if (!offset) throw new Error('startxref carries no offset');
  if (tail.lastIndexOf('%%EOF') < 0) throw new Error('no %%EOF marker; the PDF is truncated');

  return { version: match[1], pages: countPages(text), xrefOffset: Number(offset[0]) };
}

/** Page objects: `/Type/Page` or `/Type /Page`, never the `/Type/Pages` tree node. */
function countPages(text: string): number {
  return (text.match(/\/Type\s*\/Page(?![A-Za-z])/g) ?? []).length;
}

/** Assert the bytes are a complete, non-empty PDF; return its shape. */
export function assertPdf(bytes: Buffer, label = 'output'): PdfInfo {
  if (bytes.length === 0) throw new Error(`${label}: empty output`);
  const info = readPdf(bytes);
  if (info.pages < 1) throw new Error(`${label}: no page objects`);
  if (info.xrefOffset <= 0 || info.xrefOffset >= bytes.length) {
    throw new Error(`${label}: startxref offset ${info.xrefOffset} is outside the file`);
  }
  if (!bytes.subarray(info.xrefOffset, info.xrefOffset + 4).toString('latin1').startsWith('xref')) {
    throw new Error(`${label}: startxref does not point at the cross-reference table`);
  }
  return info;
}

/**
 * Every stream in the file, inflated when it is Flate-compressed.
 *
 * Each object is found by its `<</Length N ...>>` dictionary, and the stream is
 * read as exactly N bytes: a byte search for `stream`/`endstream` would be
 * fooled by those words inside binary font programs.
 */
export function pdfStreams(bytes: Buffer): Buffer[] {
  const text = bytes.toString('latin1');
  const streams: Buffer[] = [];
  const dictionary = /<<([^<>]*\/Length\s+(\d+)[^<>]*)>>\s*stream(\r\n|\n|\r)/g;
  let match: RegExpExecArray | null;
  while ((match = dictionary.exec(text)) !== null) {
    const length = Number(match[2]);
    const start = match.index + match[0].length;
    const raw = bytes.subarray(start, start + length);
    const filtered = /\/(?:Filter\s*)?\/FlateDecode/.test(match[1]);
    try {
      streams.push(filtered ? inflateSync(raw) : raw);
    } catch {
      streams.push(raw);
    }
    dictionary.lastIndex = start + length;
  }
  return streams;
}

/** The content streams' text: every `Tj`/`TJ`/`BT`/`ET` operator the PDF draws. */
export function pdfContent(bytes: Buffer): string {
  return pdfStreams(bytes)
    .map((stream) => stream.toString('latin1'))
    .filter((stream) => /\bBT\b/.test(stream))
    .join('\n');
}

/**
 * Replace the embedded timestamps with a fixed value.
 *
 * The exporter stamps the trailer and the XMP metadata with the creation time,
 * so two runs a second apart differ by a few bytes. Every timestamp has the same
 * length, so nothing else in the file (xref offsets included) moves and the
 * result can still be compared byte for byte.
 */
export function normalizePdf(bytes: Buffer): Buffer {
  return Buffer.from(
    bytes
      .toString('latin1')
      .replace(/D:\d{14}Z/g, 'D:00000000000000Z')
      .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/g, '0000-00-00T00:00:00Z')
      .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+\d{2}:\d{2}/g, '0000-00-00T00:00:00+00:00'),
    'latin1',
  );
}
