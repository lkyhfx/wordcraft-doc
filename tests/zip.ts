/**
 * A minimal ZIP reader, enough to verify the DOCX packages this addon produces.
 *
 * The tests must not trust the converter's own writer when checking its output,
 * and adding a zip dependency just for tests would defeat the point of a
 * zero-dependency package. Central-directory parsing plus `inflateRaw` covers
 * every archive the writer can emit (stored or deflated entries).
 */
import { inflateRawSync } from 'node:zlib';

export interface ZipEntry {
  name: string;
  size: number;
  read(): Buffer;
}

const EOCD_SIGNATURE = 0x06054b50;
const CENTRAL_SIGNATURE = 0x02014b50;
const LOCAL_SIGNATURE = 0x04034b50;

/** Throw unless `bytes` is a zip archive; return its entries. */
export function readZip(bytes: Buffer): ZipEntry[] {
  // The end-of-central-directory record is the last 22 bytes plus a comment of
  // up to 64 KiB, so the search window is bounded.
  const window = Math.min(bytes.length, 22 + 0xffff);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= bytes.length - window; i -= 1) {
    if (i >= 0 && bytes.readUInt32LE(i) === EOCD_SIGNATURE) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a zip archive: no end-of-central-directory record');

  const entryCount = bytes.readUInt16LE(eocd + 10);
  let offset = bytes.readUInt32LE(eocd + 16);
  const entries: ZipEntry[] = [];

  for (let i = 0; i < entryCount; i += 1) {
    if (bytes.readUInt32LE(offset) !== CENTRAL_SIGNATURE) {
      throw new Error(`corrupt central directory at entry ${i}`);
    }
    const method = bytes.readUInt16LE(offset + 10);
    const compressedSize = bytes.readUInt32LE(offset + 20);
    const size = bytes.readUInt32LE(offset + 24);
    const nameLength = bytes.readUInt16LE(offset + 28);
    const extraLength = bytes.readUInt16LE(offset + 30);
    const commentLength = bytes.readUInt16LE(offset + 32);
    const localOffset = bytes.readUInt32LE(offset + 42);
    const name = bytes.toString('utf8', offset + 46, offset + 46 + nameLength);

    entries.push({
      name,
      size,
      read() {
        if (bytes.readUInt32LE(localOffset) !== LOCAL_SIGNATURE) {
          throw new Error(`corrupt local header for ${name}`);
        }
        const localNameLength = bytes.readUInt16LE(localOffset + 26);
        const localExtraLength = bytes.readUInt16LE(localOffset + 28);
        const start = localOffset + 30 + localNameLength + localExtraLength;
        const raw = bytes.subarray(start, start + compressedSize);
        if (method === 0) return Buffer.from(raw);
        if (method === 8) return inflateRawSync(raw);
        throw new Error(`unsupported compression method ${method} for ${name}`);
      },
    });

    offset += 46 + nameLength + extraLength + commentLength;
  }

  return entries;
}

/** Map of entry name to its decompressed bytes. */
export function readZipMap(bytes: Buffer): Map<string, Buffer> {
  return new Map(readZip(bytes).map((entry) => [entry.name, entry.read()]));
}

/** All `w:t` text of a WordprocessingML part, in document order. */
export function xmlTexts(xml: string): string[] {
  const texts: string[] = [];
  const pattern = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(xml)) !== null) {
    texts.push(decodeXmlText(match[1]));
  }
  return texts;
}

/** Undo the five XML entities the writer can emit. */
export function decodeXmlText(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/** Count occurrences of an element, self-closing or not. */
export function countTag(xml: string, tag: string): number {
  // `<w:b/>` and `<w:b w:val="1"/>` have no separate closing `>`, so the
  // pattern allows the self-closing slash.
  return (xml.match(new RegExp(`<${tag}(?:\\s[^>]*)?/?>`, 'g')) ?? []).length;
}
