#!/usr/bin/env node
/**
 * Convert every `.doc` in tests/fixtures into fixtures-docx/, so the output can
 * be opened and inspected without rebuilding the addon.
 *
 *   node scripts/convert-fixtures.ts          # from the built addon in npm/
 *   node scripts/convert-fixtures.ts --installed
 *
 * `--installed` loads the package from node_modules instead, which is what a
 * user gets; the default loads npm/index.js from this repository.
 */
import { createRequire } from 'node:module';
import { mkdir, readdir, readFile, stat } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SOURCE = join(ROOT, 'tests', 'fixtures');
const TARGET = join(ROOT, 'fixtures-docx');

type Converter = (input: string, output: string) => Promise<void>;

async function loadConverter(installed: boolean): Promise<Converter> {
  // `--installed` resolves from the current directory, not from this file, so
  // the script can be run inside a project that has installed the package.
  const specifier = installed
    ? createRequire(join(process.cwd(), 'noop.js')).resolve('@lkyhfx/wordcraft-doc')
    : new URL('../npm/index.js', import.meta.url).href;
  const module = (await import(specifier)) as { convertDocFileToDocx: Converter };
  return module.convertDocFileToDocx;
}

async function main(): Promise<void> {
  const installed = process.argv.includes('--installed');
  const convert = await loadConverter(installed);

  await mkdir(TARGET, { recursive: true });

  const entries = await readdir(SOURCE);
  const documents = entries.filter((name) => name.toLowerCase().endsWith('.doc')).sort();
  if (documents.length === 0) {
    console.error(`no .doc files in ${relative(ROOT, SOURCE)}`);
    process.exit(1);
  }

  const width = Math.max(...documents.map((name) => name.length));
  let failures = 0;

  for (const name of documents) {
    const input = join(SOURCE, name);
    const output = join(TARGET, name.replace(/\.doc$/i, '.docx'));
    try {
      const started = performance.now();
      await convert(input, output);
      const elapsed = Math.round(performance.now() - started);
      const size = (await stat(output)).size;
      // Read the result back: a file that exists but cannot be an OOXML package
      // is not a successful conversion.
      const bytes = await readFile(output);
      if (bytes.readUInt32LE(0) !== 0x04034b50) throw new Error('output is not a zip package');
      console.log(
        `  ${name.padEnd(width)}  ->  ${String(size).padStart(7)} bytes  ${elapsed} ms`,
      );
    } catch (error) {
      failures += 1;
      const code = (error as NodeJS.ErrnoException).code ?? 'ERROR';
      console.error(`  ${name.padEnd(width)}  ->  ${code}: ${(error as Error).message}`);
    }
  }

  console.log(`\n${documents.length - failures}/${documents.length} converted into ${relative(ROOT, TARGET)}/`);
  if (failures > 0) process.exit(1);
}

await main();
