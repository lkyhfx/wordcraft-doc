//! Node.js bindings for WordCraft's `.doc` → `.docx` conversion.
//!
//! This crate is deliberately thin: it calls the two upstream entry points
//! (`wordcraft_docbin::read` and `wordcraft_docx::write`), maps their errors onto
//! stable JavaScript error codes, and bounds the input and output sizes. No
//! parsing, document model or OOXML logic lives here.

use std::fs::OpenOptions;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use napi::bindgen_prelude::*;
use napi_derive::napi;

/// Default cap on the input size (512 MiB): a `.doc` file bigger than this is
/// refused before it is parsed.
const DEFAULT_MAX_INPUT_BYTES: u32 = 512 * 1024 * 1024;
/// Default cap on the produced `.docx` size (1 GiB).
const DEFAULT_MAX_OUTPUT_BYTES: u32 = 1024 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Public JavaScript surface
// ---------------------------------------------------------------------------

/// Options accepted by both conversion functions.
#[napi(object)]
pub struct ConvertOptions {
    /// Password of a password-protected (XOR/RC4/RC4 CryptoAPI) document.
    /// Ignored for unprotected files.
    pub password: Option<String>,
    /// Largest accepted input in bytes. Defaults to 512 MiB.
    pub max_input_bytes: Option<u32>,
    /// Largest accepted final output size in bytes. Checked after the writer finishes; this is not a peak-memory limit. Defaults to 1 GiB.
    pub max_output_bytes: Option<u32>,
}

/// Convert the bytes of a legacy Word `.doc` file into a `.docx` package.
///
/// Resolves with the DOCX bytes; rejects with an `Error` carrying a stable
/// `code` (see the README's Errors section).
#[napi(ts_return_type = "Promise<Buffer>")]
pub fn convert_doc_to_docx(input: Buffer, options: Option<ConvertOptions>) -> AsyncTask<ConvertTask> {
    let opts = Limits::from(options);
    // Reject oversized buffers before allocating a snapshot. The copy for valid
    // inputs is intentional: JavaScript may mutate its Buffer while the async
    // worker is reading it. Use the file API for large inputs to keep this copy
    // off the JavaScript thread.
    let (input, pre_error) = if input.len() as u64 > opts.max_input_bytes {
        let len = input.len();
        (
            Vec::new(),
            Some(ConvError::new(
                ERR_INPUT_TOO_LARGE,
                format!("input is {len} bytes, above the {}-byte limit", opts.max_input_bytes),
            )),
        )
    } else {
        (input.to_vec(), None)
    };
    AsyncTask::new(ConvertTask(Job::Bytes { input, pre_error, limits: opts }))
}

/// Convert a `.doc` file on disk into a `.docx` file on disk.
///
/// The work happens on the libuv thread pool, so neither the read nor the write
/// touches the JavaScript thread.
#[napi(ts_return_type = "Promise<void>")]
pub fn convert_doc_file_to_docx(input_path: String, output_path: String, options: Option<ConvertOptions>) -> AsyncTask<ConvertFileTask> {
    let limits = Limits::from(options);
    AsyncTask::new(ConvertFileTask(Job::File { input_path, output_path, limits }))
}

// ---------------------------------------------------------------------------
// Limits and errors
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Limits {
    password: Option<String>,
    max_input_bytes: u64,
    max_output_bytes: u64,
}

impl From<Option<ConvertOptions>> for Limits {
    fn from(options: Option<ConvertOptions>) -> Self {
        let options = options.unwrap_or(ConvertOptions { password: None, max_input_bytes: None, max_output_bytes: None });
        Self {
            // An empty password is the same as no password.
            password: options.password.filter(|p| !p.is_empty()),
            max_input_bytes: options.max_input_bytes.map_or(DEFAULT_MAX_INPUT_BYTES as u64, |v| v as u64),
            max_output_bytes: options.max_output_bytes.map_or(DEFAULT_MAX_OUTPUT_BYTES as u64, |v| v as u64),
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
const ERR_PASSWORD_REQUIRED: &str = "ERR_WORDCRAFT_PASSWORD_REQUIRED";
const ERR_WRONG_PASSWORD: &str = "ERR_WORDCRAFT_WRONG_PASSWORD";
const ERR_ENCRYPTED: &str = "ERR_WORDCRAFT_ENCRYPTED";
const ERR_INPUT_TOO_LARGE: &str = "ERR_WORDCRAFT_INPUT_TOO_LARGE";
const ERR_OUTPUT_TOO_LARGE: &str = "ERR_WORDCRAFT_OUTPUT_TOO_LARGE";
const ERR_MALFORMED: &str = "ERR_WORDCRAFT_MALFORMED";
const ERR_LIMIT: &str = "ERR_WORDCRAFT_LIMIT";
const ERR_DOCX: &str = "ERR_WORDCRAFT_DOCX";
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
            E::Limit(_) => Self::new(ERR_LIMIT, message),
            _ => Self::new(ERR_DOCX, message),
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

/// Run the upstream read/write pair and validate the result.
fn convert(input: &[u8], limits: &Limits) -> std::result::Result<Vec<u8>, ConvError> {
    if input.len() as u64 > limits.max_input_bytes {
        return Err(ConvError::new(
            ERR_INPUT_TOO_LARGE,
            format!("input is {} bytes, above the {}-byte limit", input.len(), limits.max_input_bytes),
        ));
    }
    // Upstream is written to be lenient and bounded, but a bug there must not
    // unwind across the FFI boundary and abort the process.
    let document = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        wordcraft_docbin::read_with_password(input, limits.password.as_deref())
    }))
    .map_err(|_| ConvError::new(ERR_PANIC, "the document parser panicked on this input"))??;

    let output = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| wordcraft_docx::write(&document)))
        .map_err(|_| ConvError::new(ERR_PANIC, "the DOCX writer panicked on this document"))??;

    if output.len() as u64 > limits.max_output_bytes {
        return Err(ConvError::new(
            ERR_OUTPUT_TOO_LARGE,
            format!("output is {} bytes, above the {}-byte limit", output.len(), limits.max_output_bytes),
        ));
    }
    verify_docx(&output)?;
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
        input: Vec<u8>,
        pre_error: Option<ConvError>,
        limits: Limits,
    },
    File {
        input_path: String,
        output_path: String,
        limits: Limits,
    },
}

impl Job {
    fn limits(&self) -> &Limits {
        match self {
            Job::Bytes { limits, .. } | Job::File { limits, .. } => limits,
        }
    }
}

/// Shared by both tasks: run the conversion, mapping panics to an error.
fn run_bytes(job: &Job, input: &[u8]) -> std::result::Result<Vec<u8>, ConvError> {
    convert(input, job.limits())
}

// ---------------------------------------------------------------------------
// napi tasks
// ---------------------------------------------------------------------------

/// Buffer → Buffer conversion.
pub struct ConvertTask(Job);

impl Task for ConvertTask {
    type Output = std::result::Result<Vec<u8>, ConvError>;
    type JsValue = Buffer;

    fn compute(&mut self) -> napi::Result<Self::Output> {
        // Errors travel as a value so `resolve` can attach the JavaScript error
        // code (`compute` runs off-thread and cannot build a JS error).
        let Job::Bytes { input, pre_error, .. } = &self.0 else {
            return Err(napi::Error::new(napi::Status::GenericFailure, "wrong task kind"));
        };
        if let Some(err) = pre_error {
            return Ok(Err(ConvError::new(err.code, err.message.clone())));
        }
        Ok(run_bytes(&self.0, input))
    }

    fn resolve(&mut self, env: Env, output: Self::Output) -> napi::Result<Self::JsValue> {
        match output {
            Ok(bytes) => Ok(bytes.into()),
            Err(err) => Err(err.into_napi(env)),
        }
    }
}

/// File → file conversion.
pub struct ConvertFileTask(Job);

impl Task for ConvertFileTask {
    type Output = std::result::Result<(), ConvError>;
    type JsValue = ();

    fn compute(&mut self) -> napi::Result<Self::Output> {
        let Job::File { input_path, output_path, limits } = &self.0 else {
            return Err(napi::Error::new(napi::Status::GenericFailure, "wrong task kind"));
        };
        if let Err(err) = ensure_distinct_paths(input_path, output_path) {
            return Ok(Err(err));
        }
        let input = match read_bounded(input_path, limits) {
            Ok(input) => input,
            Err(err) => return Ok(Err(err)),
        };
        let output = match convert(&input, limits) {
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
