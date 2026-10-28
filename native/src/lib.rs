//! Node.js bindings for WordCraft's `.doc`/`.docx` → `.docx`/`.pdf` conversions.
//!
//! This crate is deliberately thin. It calls the upstream entry points —
//! `wordcraft_docbin::read_with_password` and `wordcraft_docx::read_with_password`
//! for the input, `wordcraft_docx::write` and `wordcraft_pdf::export` for the
//! output — maps their errors onto stable JavaScript error codes, and bounds the
//! input and output sizes. No parsing, document model, OOXML or page layout logic
//! lives here.

use std::collections::HashSet;
use std::fs::OpenOptions;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use napi::bindgen_prelude::*;
use napi_derive::napi;
use wordcraft_doc::Document;

/// Default cap on the input size (512 MiB): a document bigger than this is
/// refused before it is parsed.
const DEFAULT_MAX_INPUT_BYTES: u32 = 512 * 1024 * 1024;
/// Default cap on the produced output size (1 GiB).
const DEFAULT_MAX_OUTPUT_BYTES: u32 = 1024 * 1024 * 1024;

/// Maximum distinct renderable characters checked; exceeding it is an error, not a pass.
const FONT_CHECK_MAX_CHARS: usize = 8192;
/// How many uncovered characters the font error names before it summarises.
const FONT_CHECK_MAX_REPORTED: usize = 8;

// ---------------------------------------------------------------------------
// Public JavaScript surface
// ---------------------------------------------------------------------------

/// Options accepted by every conversion function.
#[napi(object)]
pub struct ConvertOptions {
    /// Password of a password-protected document (`.doc`: XOR/RC4/RC4 CryptoAPI;
    /// `.docx`: ECMA-376 agile encryption). Ignored for unprotected files.
    pub password: Option<String>,
    /// Largest accepted input in bytes. Defaults to 512 MiB.
    pub max_input_bytes: Option<u32>,
    /// Largest accepted final output size in bytes. Checked after the writer finishes; this is not a peak-memory limit. Defaults to 1 GiB.
    pub max_output_bytes: Option<u32>,
    /// Reject a document whose text needs a character no installed font can draw, instead of writing missing-glyph boxes. Defaults to `true`.
    pub require_fonts: Option<bool>,
}

/// Convert the bytes of a legacy Word `.doc` file into a `.docx` package.
///
/// Resolves with the DOCX bytes; rejects with an `Error` carrying a stable
/// `code` (see the README's Errors section).
#[napi(ts_return_type = "Promise<Buffer>")]
pub fn convert_doc_to_docx(input: Buffer, options: Option<ConvertOptions>) -> AsyncTask<BufferTask> {
    AsyncTask::new(BufferTask::new(Source::Doc, Target::Docx, input, options))
}

/// Convert a `.doc` file on disk into a `.docx` file on disk.
///
/// The work happens on the libuv thread pool, so neither the read nor the write
/// touches the JavaScript thread.
#[napi(ts_return_type = "Promise<void>")]
pub fn convert_doc_file_to_docx(input_path: String, output_path: String, options: Option<ConvertOptions>) -> AsyncTask<FileTask> {
    AsyncTask::new(FileTask::new(Source::Doc, Target::Docx, input_path, output_path, options))
}

/// Convert the bytes of a legacy Word `.doc` file into a PDF.
#[napi(ts_return_type = "Promise<Buffer>")]
pub fn convert_doc_to_pdf(input: Buffer, options: Option<ConvertOptions>) -> AsyncTask<BufferTask> {
    AsyncTask::new(BufferTask::new(Source::Doc, Target::Pdf, input, options))
}

/// Convert a `.doc` file on disk into a PDF file on disk.
#[napi(ts_return_type = "Promise<void>")]
pub fn convert_doc_file_to_pdf(input_path: String, output_path: String, options: Option<ConvertOptions>) -> AsyncTask<FileTask> {
    AsyncTask::new(FileTask::new(Source::Doc, Target::Pdf, input_path, output_path, options))
}

/// Convert the bytes of a `.docx` package (`.docx`, `.docm`, `.dotx`, `.dotm`) into a PDF.
#[napi(ts_return_type = "Promise<Buffer>")]
pub fn convert_docx_to_pdf(input: Buffer, options: Option<ConvertOptions>) -> AsyncTask<BufferTask> {
    AsyncTask::new(BufferTask::new(Source::Docx, Target::Pdf, input, options))
}

/// Convert a `.docx` file on disk into a PDF file on disk.
#[napi(ts_return_type = "Promise<void>")]
pub fn convert_docx_file_to_pdf(input_path: String, output_path: String, options: Option<ConvertOptions>) -> AsyncTask<FileTask> {
    AsyncTask::new(FileTask::new(Source::Docx, Target::Pdf, input_path, output_path, options))
}

// ---------------------------------------------------------------------------
// Limits and errors
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Limits {
    password: Option<String>,
    max_input_bytes: u64,
    max_output_bytes: u64,
    require_fonts: bool,
}

impl From<Option<ConvertOptions>> for Limits {
    fn from(options: Option<ConvertOptions>) -> Self {
        let options = options.unwrap_or(ConvertOptions {
            password: None,
            max_input_bytes: None,
            max_output_bytes: None,
            require_fonts: None,
        });
        Self {
            // An empty password is the same as no password.
            password: options.password.filter(|p| !p.is_empty()),
            max_input_bytes: options.max_input_bytes.map_or(DEFAULT_MAX_INPUT_BYTES as u64, |v| v as u64),
            max_output_bytes: options.max_output_bytes.map_or(DEFAULT_MAX_OUTPUT_BYTES as u64, |v| v as u64),
            require_fonts: options.require_fonts.unwrap_or(true),
        }
    }
}

/// A conversion failure, carrying the JavaScript error code it maps to.
#[derive(Debug)]
pub struct ConvError {
    code: &'static str,
    message: String,
}

impl ConvError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    fn io(context: &str, err: &std::io::Error) -> Self {
        Self::new(ERR_IO, format!("{context}: {err}"))
    }
}

const ERR_IO: &str = "ERR_WORDCRAFT_IO";
const ERR_NOT_A_DOC: &str = "ERR_WORDCRAFT_NOT_A_DOC";
const ERR_NOT_A_DOCX: &str = "ERR_WORDCRAFT_NOT_A_DOCX";
const ERR_PASSWORD_REQUIRED: &str = "ERR_WORDCRAFT_PASSWORD_REQUIRED";
const ERR_WRONG_PASSWORD: &str = "ERR_WORDCRAFT_WRONG_PASSWORD";
const ERR_ENCRYPTED: &str = "ERR_WORDCRAFT_ENCRYPTED";
const ERR_INPUT_TOO_LARGE: &str = "ERR_WORDCRAFT_INPUT_TOO_LARGE";
const ERR_OUTPUT_TOO_LARGE: &str = "ERR_WORDCRAFT_OUTPUT_TOO_LARGE";
const ERR_MALFORMED: &str = "ERR_WORDCRAFT_MALFORMED";
const ERR_LIMIT: &str = "ERR_WORDCRAFT_LIMIT";
const ERR_DOCX: &str = "ERR_WORDCRAFT_DOCX";
const ERR_PDF: &str = "ERR_WORDCRAFT_PDF";
const ERR_FONTS: &str = "ERR_WORDCRAFT_FONTS";
const ERR_PANIC: &str = "ERR_WORDCRAFT_PANIC";

impl From<wordcraft_docbin::DocbinError> for ConvError {
    fn from(err: wordcraft_docbin::DocbinError) -> Self {
        use wordcraft_docbin::DocbinError as E;
        let message = err.to_string();
        match err {
            E::Container(_) => Self::new(ERR_NOT_A_DOC, message),
            E::NotWord(_) => Self::new(ERR_NOT_A_DOC, message),
            E::PasswordRequired => Self::new(ERR_PASSWORD_REQUIRED, message),
            E::WrongPassword => Self::new(ERR_WRONG_PASSWORD, message),
            E::Encryption(_) => Self::new(ERR_ENCRYPTED, message),
            E::Limit(_) => Self::new(ERR_LIMIT, message),
            E::Malformed(_) => Self::new(ERR_MALFORMED, message),
        }
    }
}

impl From<wordcraft_docx::DocxError> for ConvError {
    fn from(err: wordcraft_docx::DocxError) -> Self {
        use wordcraft_docx::DocxError as E;
        let message = err.to_string();
        match err {
            // Reading a `.docx` input.
            E::Zip(_) | E::MissingPart(_) | E::Xml(_) | E::NotWord(_) | E::NotWordXml => Self::new(ERR_NOT_A_DOCX, message),
            E::Limit(_) => Self::new(ERR_LIMIT, message),
            E::PasswordRequired => Self::new(ERR_PASSWORD_REQUIRED, message),
            E::WrongPassword => Self::new(ERR_WRONG_PASSWORD, message),
            E::Encryption(_) => Self::new(ERR_ENCRYPTED, message),
        }
    }
}

impl From<wordcraft_pdf::PdfError> for ConvError {
    fn from(err: wordcraft_pdf::PdfError) -> Self {
        use wordcraft_pdf::PdfError as E;
        let message = err.to_string();
        match err {
            E::NoPages => Self::new(ERR_PDF, format!("{message} (no page could be laid out)")),
            E::BadPage(_) | E::Write(_) => Self::new(ERR_PDF, message),
        }
    }
}

impl ConvError {
    /// Turn this into a `napi::Error` whose `code` property is the stable
    /// JavaScript code. Building it through a real JS `Error` object is the only
    /// way to reach the `code` property; `napi::Error` itself only carries a
    /// status and a message.
    fn into_napi(self, env: Env) -> napi::Error {
        let Self { code, message } = self;
        let js = napi::JsError::from(napi::Error::new(code, message));
        // SAFETY: `into_value` only needs a valid env, which `Env` guarantees.
        let raw = unsafe { js.into_value(env.raw()) };
        if raw.is_null() {
            // The env could not build an error object (teardown). Fall back to a
            // plain error so the rejection still carries the message.
            return napi::Error::new(napi::Status::GenericFailure, "wordcraft-doc: conversion failed");
        }
        // SAFETY: `into_value` returns a valid JS value for this env.
        let unknown = unsafe { Unknown::from_raw_unchecked(env.raw(), raw) };
        napi::Error::from(unknown)
    }
}

// ---------------------------------------------------------------------------
// The conversion itself
// ---------------------------------------------------------------------------

/// Which reader parses the input.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Source {
    /// Legacy Word 97–2003 binary format (`wordcraft-docbin`).
    Doc,
    /// WordprocessingML package (`wordcraft-docx`).
    Docx,
}

/// Which writer produces the output.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Target {
    Docx,
    Pdf,
}

/// Parse the input into the shared WordCraft document model. Both formats go
/// through the same `Document`, so every target is reachable from either source.
fn read_document(input: &[u8], source: Source, limits: &Limits) -> std::result::Result<Document, ConvError> {
    let password = limits.password.as_deref();
    // Upstream is written to be lenient and bounded, but a bug there must not
    // unwind across the FFI boundary and abort the process.
    match source {
        Source::Doc => std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| wordcraft_docbin::read_with_password(input, password)))
            .map_err(|_| ConvError::new(ERR_PANIC, "the document parser panicked on this input"))?
            .map_err(ConvError::from),
        Source::Docx => std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| wordcraft_docx::read_with_password(input, password)))
            .map_err(|_| ConvError::new(ERR_PANIC, "the DOCX reader panicked on this input"))?
            .map_err(ConvError::from),
    }
}

/// Run the reader and the chosen writer, then validate the result.
fn convert(input: &[u8], source: Source, target: Target, limits: &Limits) -> std::result::Result<Vec<u8>, ConvError> {
    if input.len() as u64 > limits.max_input_bytes {
        return Err(ConvError::new(
            ERR_INPUT_TOO_LARGE,
            format!("input is {} bytes, above the {}-byte limit", input.len(), limits.max_input_bytes),
        ));
    }
    let document = read_document(input, source, limits)?;
    let output = match target {
        Target::Docx => {
            let output = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| wordcraft_docx::write(&document)))
                .map_err(|_| ConvError::new(ERR_PANIC, "the DOCX writer panicked on this document"))??;
            verify_docx(&output)?;
            output
        }
        Target::Pdf => {
            if limits.require_fonts {
                check_fonts(&document)?;
            }
            let output = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                wordcraft_pdf::export(&document, &wordcraft_pdf::PdfOptions::default())
            }))
            .map_err(|_| ConvError::new(ERR_PANIC, "the PDF exporter panicked on this document"))??;
            verify_pdf(&output)?;
            output
        }
    };
    if output.len() as u64 > limits.max_output_bytes {
        return Err(ConvError::new(
            ERR_OUTPUT_TOO_LARGE,
            format!("output is {} bytes, above the {}-byte limit", output.len(), limits.max_output_bytes),
        ));
    }
    Ok(output)
}

/// Check that the writer produced a real DOCX package: a zip archive holding a
/// non-empty main document part and a content-types part.
fn verify_docx(bytes: &[u8]) -> std::result::Result<(), ConvError> {
    if bytes.is_empty() {
        return Err(ConvError::new(ERR_DOCX, "the writer produced no output"));
    }
    let mut zip = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|e| ConvError::new(ERR_DOCX, format!("output is not a zip package: {e}")))?;

    for part in ["[Content_Types].xml", "word/document.xml"] {
        let file = zip
            .by_name(part)
            .map_err(|e| ConvError::new(ERR_DOCX, format!("output has no {part} part: {e}")))?;
        if file.size() == 0 {
            return Err(ConvError::new(ERR_DOCX, format!("output part {part} is empty")));
        }
    }
    Ok(())
}

/// Detect a page dictionary entry while respecting PDF name boundaries.
fn has_pdf_page_object(bytes: &[u8]) -> bool {
    const TYPE_TAG: &[u8] = b"/Type";
    const PAGE_NAME: &[u8] = b"/Page";
    bytes.windows(TYPE_TAG.len()).enumerate().any(|(index, window)| {
        if window != TYPE_TAG {
            return false;
        }
        let mut value_start = index + TYPE_TAG.len();
        while bytes.get(value_start).is_some_and(|b| b.is_ascii_whitespace()) {
            value_start += 1;
        }
        if !bytes.get(value_start..).is_some_and(|suffix| suffix.starts_with(PAGE_NAME)) {
            return false;
        }
        let boundary = value_start + PAGE_NAME.len();
        bytes.get(boundary).map_or(true, |next| {
            next.is_ascii_whitespace()
                || matches!(*next, b'/' | b'>' | b'<' | b'[' | b']' | b'(' | b')' | b'{' | b'}' | b'%')
        })
    })
}

/// Check that the exporter produced a complete PDF file: header, page object,
/// cross-reference offset and end-of-file marker.
fn verify_pdf(bytes: &[u8]) -> std::result::Result<(), ConvError> {
    if bytes.is_empty() {
        return Err(ConvError::new(ERR_PDF, "the exporter produced no output"));
    }
    if !bytes.starts_with(b"%PDF-") {
        return Err(ConvError::new(ERR_PDF, "output does not start with a PDF header"));
    }
    if !has_pdf_page_object(bytes) {
        return Err(ConvError::new(ERR_PDF, "output has no page object"));
    }

    // The final trailer markers should be near the end. Validate the numeric
    // startxref offset instead of accepting a marker that appears in arbitrary
    // trailing bytes.
    let tail_start = bytes.len().saturating_sub(2048);
    let tail = &bytes[tail_start..];
    let startxref_marker = b"startxref";
    let Some(startxref_pos) = tail.windows(startxref_marker.len()).rposition(|window| window == startxref_marker) else {
        return Err(ConvError::new(ERR_PDF, "output has no startxref marker; it is truncated"));
    };
    let eof_marker = b"%%EOF";
    let Some(eof_pos) = tail.windows(eof_marker.len()).rposition(|window| window == eof_marker) else {
        return Err(ConvError::new(ERR_PDF, "output has no %%EOF marker; it is truncated"));
    };
    if eof_pos < startxref_pos {
        return Err(ConvError::new(ERR_PDF, "the %%EOF marker precedes startxref"));
    }

    let after_startxref = &tail[startxref_pos + startxref_marker.len()..];
    let first_non_whitespace = after_startxref.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(after_startxref.len());
    let offset_bytes = &after_startxref[first_non_whitespace..];
    let digit_count = offset_bytes.iter().take_while(|b| b.is_ascii_digit()).count();
    if digit_count == 0 {
        return Err(ConvError::new(ERR_PDF, "startxref carries no numeric offset"));
    }
    let offset = std::str::from_utf8(&offset_bytes[..digit_count])
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .ok_or_else(|| ConvError::new(ERR_PDF, "startxref offset is invalid"))?;
    if offset >= bytes.len() {
        return Err(ConvError::new(ERR_PDF, "startxref offset is outside the PDF"));
    }
    let xref = &bytes[offset..];
    if !xref.starts_with(b"xref") || !xref.get(4).is_some_and(|b| b.is_ascii_whitespace()) {
        return Err(ConvError::new(ERR_PDF, "startxref does not point to a cross-reference table"));
    }
    Ok(())
}

/// Characters that affect shaping, direction, or presentation but do not need an
/// independent visible glyph in the font. Checking them as ordinary characters
/// can reject otherwise valid text containing joiners or variation selectors.
fn is_non_rendering_format_char(c: char) -> bool {
    matches!(
        c,
        '\u{034F}'
            | '\u{061C}'
            | '\u{180B}'..='\u{180F}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{206F}'
            | '\u{FE00}'..='\u{FE0F}'
            | '\u{FEFF}'
            | '\u{E0000}'..='\u{E0FFF}'
    )
}

/// Remember a character for font coverage checking. Returns Ok(false) for
/// whitespace, formatting characters, or duplicates; returns Err(()) when a
/// new character would exceed the budget.
fn remember_font_char(c: char, seen: &mut HashSet<char>, max: usize) -> Result<bool, ()> {
    if c.is_whitespace() || c.is_control() || is_non_rendering_format_char(c) || seen.contains(&c) {
        return Ok(false);
    }
    if seen.len() >= max {
        return Err(());
    }
    seen.insert(c);
    Ok(true)
}

/// Refuse to export when the document's text needs a character no installed font
/// can draw: the exporter would otherwise fill the page with missing-glyph boxes.
///
/// WordCraft bundles a handful of Latin OpenType faces and takes everything else
/// from the system's font directories, so a bare container image has Latin text
/// but no Chinese, Japanese or Korean. Coverage is asked of the same font
/// database the layout uses, so an installed family, a fallback or a lazily
/// loaded system font all count as available.
fn check_fonts(document: &Document) -> std::result::Result<(), ConvError> {
    let db = wordcraft_fonts::FontDb::global();
    let mut seen: HashSet<char> = HashSet::new();
    let mut missing: Vec<char> = Vec::new();
    for story in document.shown_stories() {
        for c in document.shown_text(story).chars() {
            let should_check = remember_font_char(c, &mut seen, FONT_CHECK_MAX_CHARS).map_err(|_| {
                ConvError::new(
                    ERR_FONTS,
                    format!(
                        "font coverage checking exceeded its {} distinct-character limit, so full coverage could not be verified. \
                         Install fonts covering the document or pass {{ requireFonts: false }} to export without this check",
                        FONT_CHECK_MAX_CHARS
                    ),
                )
            })?;
            if !should_check {
                continue;
            }
            // u32::MAX is never a loaded face's id, so the fallback search
            // considers every face it knows: bundled, installed and lazily
            // loaded system fonts alike.
            if db.fallback_for(c, u32::MAX).is_none() && missing.len() < FONT_CHECK_MAX_REPORTED {
                missing.push(c);
            }
        }
    }
    if missing.is_empty() {
        return Ok(());
    }
    let list = missing.iter().map(|c| format!("U+{:04X} {c:?}", u32::from(*c))).collect::<Vec<_>>().join(", ");
    Err(ConvError::new(
        ERR_FONTS,
        format!(
            "no installed font can draw this document: {list}. \
             Install a font covering these characters (for example the Noto CJK or Source Han families) \
             and restart, or pass {{ requireFonts: false }} to export with missing glyphs instead"
        ),
    ))
}

/// Read a file with the size limit applied before the read, so a huge input is
/// never materialised.
fn read_bounded(path: &str, limits: &Limits) -> std::result::Result<Vec<u8>, ConvError> {
    let meta = std::fs::metadata(path).map_err(|e| ConvError::io(&format!("cannot read input file '{path}'"), &e))?;
    if !meta.is_file() {
        return Err(ConvError::new(ERR_IO, format!("input '{path}' is not a regular file")));
    }
    if meta.len() > limits.max_input_bytes {
        return Err(ConvError::new(
            ERR_INPUT_TOO_LARGE,
            format!("input file is {} bytes, above the {}-byte limit", meta.len(), limits.max_input_bytes),
        ));
    }
    std::fs::read(path).map_err(|e| ConvError::io(&format!("cannot read input file '{path}'"), &e))
}

fn canonical_output_path(path: &Path) -> std::io::Result<PathBuf> {
    if path.exists() {
        return std::fs::canonicalize(path);
    }
    let file_name = path.file_name().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "output path does not name a file")
    })?;
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    Ok(std::fs::canonicalize(parent)?.join(file_name))
}

fn ensure_distinct_paths(input_path: &str, output_path: &str) -> std::result::Result<(), ConvError> {
    let input = std::fs::canonicalize(input_path)
        .map_err(|e| ConvError::io(&format!("cannot resolve input path '{input_path}'"), &e))?;
    let output = canonical_output_path(Path::new(output_path))
        .map_err(|e| ConvError::io(&format!("cannot resolve output path '{output_path}'"), &e))?;
    if input == output {
        return Err(ConvError::new(ERR_IO, "input and output paths resolve to the same file"));
    }
    Ok(())
}

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn write_atomic(output_path: &str, bytes: &[u8]) -> std::result::Result<(), ConvError> {
    let target = Path::new(output_path);
    if target.file_name().is_none() {
        return Err(ConvError::new(ERR_IO, format!("output path '{output_path}' does not name a file")));
    }
    let parent = target.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    let mut temporary = None;
    for _ in 0..32 {
        let name = format!(".wordcraft-doc-{}-{}.tmp", std::process::id(), TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed));
        let path = parent.join(name);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => { temporary = Some((path, file)); break; }
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(ConvError::io(&format!("cannot create temporary output for '{output_path}'"), &err)),
        }
    }
    let Some((temporary_path, mut file)) = temporary else {
        return Err(ConvError::new(ERR_IO, "could not allocate a unique temporary output file"));
    };
    let write_result = file.write_all(bytes).and_then(|_| file.sync_all());
    drop(file);
    if let Err(err) = write_result {
        let _ = std::fs::remove_file(&temporary_path);
        return Err(ConvError::io(&format!("cannot write temporary output for '{output_path}'"), &err));
    }
    if let Err(err) = std::fs::rename(&temporary_path, target) {
        let _ = std::fs::remove_file(&temporary_path);
        return Err(ConvError::io(&format!("cannot replace output file '{output_path}'"), &err));
    }
    Ok(())
}

enum Job {
    Bytes {
        source: Source,
        target: Target,
        input: Vec<u8>,
        pre_error: Option<ConvError>,
        limits: Limits,
    },
    File {
        source: Source,
        target: Target,
        input_path: String,
        output_path: String,
        limits: Limits,
    },
}

// ---------------------------------------------------------------------------
// napi tasks
// ---------------------------------------------------------------------------

/// Buffer → Buffer conversion.
pub struct BufferTask(Job);

impl BufferTask {
    /// Snapshot the input on the JavaScript thread: JavaScript may mutate its
    /// Buffer while the worker reads it. Use the file API for large inputs to
    /// keep that copy off the JavaScript thread.
    fn new(source: Source, target: Target, input: Buffer, options: Option<ConvertOptions>) -> Self {
        let limits = Limits::from(options);
        // Reject oversized buffers before allocating a snapshot.
        let (input, pre_error) = if input.len() as u64 > limits.max_input_bytes {
            let len = input.len();
            (
                Vec::new(),
                Some(ConvError::new(
                    ERR_INPUT_TOO_LARGE,
                    format!("input is {len} bytes, above the {}-byte limit", limits.max_input_bytes),
                )),
            )
        } else {
            (input.to_vec(), None)
        };
        Self(Job::Bytes { source, target, input, pre_error, limits })
    }
}

impl Task for BufferTask {
    type Output = std::result::Result<Vec<u8>, ConvError>;
    type JsValue = Buffer;

    fn compute(&mut self) -> napi::Result<Self::Output> {
        // Errors travel as a value so `resolve` can attach the JavaScript error
        // code (`compute` runs off-thread and cannot build a JS error).
        let Job::Bytes { source, target, input, pre_error, limits } = &self.0 else {
            return Err(napi::Error::new(napi::Status::GenericFailure, "wrong task kind"));
        };
        if let Some(err) = pre_error {
            return Ok(Err(ConvError::new(err.code, err.message.clone())));
        }
        Ok(convert(input, *source, *target, limits))
    }

    fn resolve(&mut self, env: Env, output: Self::Output) -> napi::Result<Self::JsValue> {
        match output {
            Ok(bytes) => Ok(bytes.into()),
            Err(err) => Err(err.into_napi(env)),
        }
    }
}

/// File → file conversion.
pub struct FileTask(Job);

impl FileTask {
    fn new(source: Source, target: Target, input_path: String, output_path: String, options: Option<ConvertOptions>) -> Self {
        Self(Job::File { source, target, input_path, output_path, limits: Limits::from(options) })
    }
}

impl Task for FileTask {
    type Output = std::result::Result<(), ConvError>;
    type JsValue = ();

    fn compute(&mut self) -> napi::Result<Self::Output> {
        let Job::File { source, target, input_path, output_path, limits } = &self.0 else {
            return Err(napi::Error::new(napi::Status::GenericFailure, "wrong task kind"));
        };
        if let Err(err) = ensure_distinct_paths(input_path, output_path) {
            return Ok(Err(err));
        }
        let input = match read_bounded(input_path, limits) {
            Ok(input) => input,
            Err(err) => return Ok(Err(err)),
        };
        let output = match convert(&input, *source, *target, limits) {
            Ok(output) => output,
            Err(err) => return Ok(Err(err)),
        };
        Ok(write_atomic(output_path, &output))
    }

    fn resolve(&mut self, env: Env, output: Self::Output) -> napi::Result<Self::JsValue> {
        match output {
            Ok(()) => Ok(()),
            Err(err) => Err(err.into_napi(env)),
        }
    }
}


#[cfg(test)]
mod tests {
    use super::{has_pdf_page_object, is_non_rendering_format_char, remember_font_char};
    use std::collections::HashSet;

    #[test]
    fn font_check_fails_closed_when_character_budget_is_exceeded() {
        let mut seen = HashSet::new();
        assert_eq!(remember_font_char('a', &mut seen, 2), Ok(true));
        assert_eq!(remember_font_char('b', &mut seen, 2), Ok(true));
        assert_eq!(remember_font_char('a', &mut seen, 2), Ok(false));
        assert_eq!(remember_font_char('c', &mut seen, 2), Err(()));
    }

    #[test]
    fn font_check_skips_non_rendering_format_characters() {
        assert!(is_non_rendering_format_char('\u{200D}'));
        assert!(is_non_rendering_format_char('\u{FE0F}'));
        let mut seen = HashSet::new();
        assert_eq!(remember_font_char('\u{200D}', &mut seen, 2), Ok(false));
        assert_eq!(remember_font_char('\u{FE0F}', &mut seen, 2), Ok(false));
        assert!(seen.is_empty());
    }

    #[test]
    fn pdf_page_detection_handles_spacing_and_name_boundaries() {
        assert!(has_pdf_page_object(b"/Type /Page "));
        assert!(has_pdf_page_object(b"/Type/Page>"));
        assert!(!has_pdf_page_object(b"/Type /Pages "));
        assert!(!has_pdf_page_object(b"/Type /PageLabel "));
    }
}
