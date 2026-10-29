//! One log pipeline for the whole app. Rust `log` records (spotcore and
//! librespot) and Swift messages (via [`log_message`]) are redacted, appended
//! to a daily file in the app's log directory and forwarded to a Swift
//! [`LogSink`] that writes them to `os.Logger`. Nothing leaves the machine:
//! diagnostics are exported only when the user asks (Help > Export Diagnostics).

use std::cell::Cell;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, Write};
use std::os::unix::fs::{FileExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

use log::{LevelFilter, Metadata, Record};
use time::format_description::well_known::Rfc3339;
use time::{Date, OffsetDateTime};

use crate::SpotCoreError;
use crate::redact::{self, redact};

/// Caps one day's file; the excess is dropped behind a single marker line.
const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;
/// Today plus two previous days covers any 24-hour export window.
const KEEP_DAYS: i64 = 2;
const FILE_PREFIX: &str = "veya-";
const FILE_SUFFIX: &str = ".log";
/// librespot logs raw tokens at trace level, so trace is never enabled.
const MAX_LEVEL_CAP: LevelFilter = LevelFilter::Debug;
/// Dependencies outside these crates stay at info and above.
const OWN_CRATES: [&str; 3] = ["spotcore", "librespot", "veya"];
/// Target prefix for messages logged from Swift.
const SWIFT_CRATE: &str = "veya";

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevel {
    Error,
    Warn,
    Info,
    Debug,
}

impl LogLevel {
    fn from_log(level: log::Level) -> Self {
        match level {
            log::Level::Error => Self::Error,
            log::Level::Warn => Self::Warn,
            log::Level::Info => Self::Info,
            log::Level::Debug | log::Level::Trace => Self::Debug,
        }
    }

    fn to_log(self) -> log::Level {
        match self {
            Self::Error => log::Level::Error,
            Self::Warn => log::Level::Warn,
            Self::Info => log::Level::Info,
            Self::Debug => log::Level::Debug,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Error => "ERROR",
            Self::Warn => "WARN",
            Self::Info => "INFO",
            Self::Debug => "DEBUG",
        }
    }
}

/// A redacted record handed to Swift. `subsystem` is the crate
/// (`librespot_core`, `spotcore`, `veya`) and `category` the module path
/// below it, so Swift maps them to `os.Logger(subsystem:category:)`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LogRecord {
    pub level: LogLevel,
    pub subsystem: String,
    pub category: String,
    pub message: String,
}

/// Implemented in Swift. Called on arbitrary Rust threads; must not block.
#[uniffi::export(with_foreign)]
pub trait LogSink: Send + Sync {
    fn log(&self, record: LogRecord);
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LoggingConfig {
    /// Directory for the daily log files; `None` disables file logging.
    pub log_dir: Option<String>,
    pub max_level: LogLevel,
}

/// Installs or reconfigures logging. Safe to call repeatedly: the global
/// logger is registered once and later calls swap its sink and settings.
#[uniffi::export]
pub fn configure_logging(
    config: LoggingConfig,
    sink: Option<Arc<dyn LogSink>>,
) -> Result<(), SpotCoreError> {
    let pipeline = Pipeline::new(config, sink, OffsetDateTime::now_utc())?;
    log::set_max_level(pipeline.max_level);
    *PIPELINE.write().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(pipeline));
    // Fails only when already set, which is the reconfigure case.
    let _ = log::set_logger(&GLOBAL_LOGGER);
    Ok(())
}

/// Logs a message from Swift through the same pipeline as Rust records.
#[uniffi::export]
pub fn log_message(level: LogLevel, category: String, message: String) {
    let target = format!("{SWIFT_CRATE}::{category}");
    log::logger().log(
        &Record::builder()
            .level(level.to_log())
            .target(&target)
            .args(format_args!("{message}"))
            .build(),
    );
}

/// Redacted log lines from the last `window_seconds`, oldest first.
#[uniffi::export]
pub fn recent_logs(window_seconds: u64) -> Result<String, SpotCoreError> {
    let dir = PIPELINE
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .and_then(|p| p.file.as_ref().map(|f| f.dir.clone()));
    let Some(dir) = dir else {
        return Ok(String::new());
    };
    read_recent(
        &dir,
        window_start(OffsetDateTime::now_utc(), window_seconds),
    )
    .map_err(internal)
}

/// The epoch for a window too long to subtract, so it covers every log.
fn window_start(now: OffsetDateTime, window_seconds: u64) -> OffsetDateTime {
    i64::try_from(window_seconds)
        .ok()
        .and_then(|seconds| now.checked_sub(time::Duration::seconds(seconds)))
        .unwrap_or(OffsetDateTime::UNIX_EPOCH)
}

#[uniffi::export(name = "redact")]
pub fn redact_text(text: String) -> String {
    redact(&text)
}

/// Registers a value (such as the signed-in username) to scrub from logs.
#[uniffi::export]
pub fn add_log_redaction(secret: String) {
    redact::add_secret(&secret);
}

static PIPELINE: RwLock<Option<Arc<Pipeline>>> = RwLock::new(None);
static GLOBAL_LOGGER: GlobalLogger = GlobalLogger;

struct GlobalLogger;

impl log::Log for GlobalLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        current().is_some_and(|p| p.enabled(metadata.level(), metadata.target()))
    }

    fn log(&self, record: &Record) {
        if let Some(pipeline) = current() {
            pipeline.log(record, OffsetDateTime::now_utc());
        }
    }

    fn flush(&self) {}
}

/// Clones the pipeline out so the sink runs without holding the lock; a
/// sink that logs again would otherwise deadlock.
fn current() -> Option<Arc<Pipeline>> {
    PIPELINE.read().unwrap_or_else(|e| e.into_inner()).clone()
}

struct Pipeline {
    max_level: LevelFilter,
    sink: Option<Arc<dyn LogSink>>,
    file: Option<LogFile>,
}

impl Pipeline {
    fn new(
        config: LoggingConfig,
        sink: Option<Arc<dyn LogSink>>,
        now: OffsetDateTime,
    ) -> Result<Self, SpotCoreError> {
        let file = match config.log_dir {
            Some(dir) => Some(LogFile::open(PathBuf::from(dir), now).map_err(internal)?),
            None => None,
        };
        Ok(Self {
            max_level: config
                .max_level
                .to_log()
                .to_level_filter()
                .min(MAX_LEVEL_CAP),
            sink,
            file,
        })
    }

    fn enabled(&self, level: log::Level, target: &str) -> bool {
        let crate_name = target.split("::").next().unwrap_or(target);
        let own = OWN_CRATES.iter().any(|c| crate_name.starts_with(c));
        let max = if own {
            self.max_level
        } else {
            self.max_level.min(LevelFilter::Info)
        };
        level <= max
    }

    fn log(&self, record: &Record, now: OffsetDateTime) {
        if !self.enabled(record.level(), record.target()) {
            return;
        }
        // A sink that logs again would recurse until the stack overflows.
        let Some(_guard) = ReentrancyGuard::enter() else {
            return;
        };
        let (subsystem, category) = split_target(record.target());
        let entry = LogRecord {
            level: LogLevel::from_log(record.level()),
            subsystem: subsystem.to_owned(),
            category: category.to_owned(),
            message: redact(&record.args().to_string()),
        };
        if let Some(file) = &self.file {
            file.append(&entry, now);
        }
        if let Some(sink) = &self.sink {
            sink.log(entry);
        }
    }
}

thread_local! {
    static IN_PIPELINE: Cell<bool> = const { Cell::new(false) };
}

struct ReentrancyGuard;

impl ReentrancyGuard {
    fn enter() -> Option<Self> {
        IN_PIPELINE.with(|flag| (!flag.replace(true)).then_some(Self))
    }
}

impl Drop for ReentrancyGuard {
    fn drop(&mut self) {
        IN_PIPELINE.with(|flag| flag.set(false));
    }
}

/// `librespot_core::session` -> (`librespot_core`, `session`); a bare crate
/// name is its own category.
fn split_target(target: &str) -> (&str, &str) {
    match target.split_once("::") {
        Some((krate, rest)) if !rest.is_empty() => (krate, rest),
        _ => (target, target),
    }
}

struct LogFile {
    dir: PathBuf,
    state: Mutex<FileState>,
}

#[derive(Default)]
struct FileState {
    day: Option<Date>,
    file: Option<File>,
    bytes: u64,
    capped: bool,
}

impl LogFile {
    fn open(dir: PathBuf, now: OffsetDateTime) -> std::io::Result<Self> {
        crate::util::create_private_dir(&dir)?;
        // Best effort: an undeletable old file must not disable file logging.
        let _ = prune(&dir, now.date());
        Ok(Self {
            dir,
            state: Mutex::new(FileState::default()),
        })
    }

    /// Logging must never fail the caller, so I/O errors drop the line.
    fn append(&self, entry: &LogRecord, now: OffsetDateTime) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let _ = self.append_locked(&mut state, entry, now);
    }

    fn append_locked(
        &self,
        state: &mut FileState,
        entry: &LogRecord,
        now: OffsetDateTime,
    ) -> std::io::Result<()> {
        if state.day != Some(now.date()) || state.file.is_none() {
            if state.day.is_some_and(|day| day != now.date()) {
                // Long-running app: prune on day rollover, not only at launch.
                let _ = prune(&self.dir, now.date());
            }
            let mut file = OpenOptions::new()
                .create(true)
                .read(true)
                .append(true)
                .mode(0o600)
                .open(day_path(&self.dir, now.date()))?;
            state.bytes = file.metadata()?.len();
            // Terminate a line torn by a crash so the next record parses.
            let mut last = [0u8];
            if state.bytes > 0 && file.read_at(&mut last, state.bytes - 1)? == 1 && last[0] != b'\n'
            {
                file.write_all(b"\n")?;
                state.bytes += 1;
            }
            state.capped = state.bytes >= MAX_FILE_BYTES;
            state.file = Some(file);
            state.day = Some(now.date());
        }
        if state.capped {
            return Ok(());
        }
        let mut line = format_line(entry, now);
        if state.bytes + line.len() as u64 > MAX_FILE_BYTES {
            state.capped = true;
            line = format_line(
                &LogRecord {
                    level: LogLevel::Warn,
                    subsystem: "spotcore".to_owned(),
                    category: "logging".to_owned(),
                    message: "daily log size cap reached; dropping further lines".to_owned(),
                },
                now,
            );
        }
        let file = state.file.as_mut().expect("opened above");
        file.write_all(line.as_bytes())?;
        state.bytes += line.len() as u64;
        Ok(())
    }
}

/// One record per line: `<RFC 3339 UTC>\t<LEVEL>\t<subsystem>/<category>\t<message>`.
/// Newlines in the message are escaped so a line is always a whole record.
fn format_line(entry: &LogRecord, now: OffsetDateTime) -> String {
    let ts = now.format(&Rfc3339).unwrap_or_default();
    let message = entry.message.replace('\r', "\\r").replace('\n', "\\n");
    format!(
        "{ts}\t{}\t{}/{}\t{message}\n",
        entry.level.label(),
        entry.subsystem,
        entry.category
    )
}

fn day_path(dir: &Path, day: Date) -> PathBuf {
    dir.join(format!("{FILE_PREFIX}{day}{FILE_SUFFIX}"))
}

fn log_file_day(path: &Path) -> Option<Date> {
    let name = path.file_name()?.to_str()?;
    let day = name.strip_prefix(FILE_PREFIX)?.strip_suffix(FILE_SUFFIX)?;
    Date::parse(
        day,
        time::macros::format_description!("[year]-[month]-[day]"),
    )
    .ok()
}

fn log_files(dir: &Path) -> std::io::Result<Vec<(Date, PathBuf)>> {
    let mut files: Vec<_> = fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter_map(|p| log_file_day(&p).map(|d| (d, p)))
        .collect();
    files.sort();
    Ok(files)
}

fn prune(dir: &Path, today: Date) -> std::io::Result<()> {
    let oldest_kept = today - time::Duration::days(KEEP_DAYS);
    for (day, path) in log_files(dir)? {
        if day < oldest_kept {
            // Already gone (another prune won the race) is fine.
            match fs::remove_file(&path) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
                _ => {}
            }
        }
    }
    Ok(())
}

/// Lines at or after `since`. Lines without a parseable timestamp (a write
/// cut short by a crash) are skipped. Re-redacts line by line, to catch
/// secrets registered after the line was written.
fn read_recent(dir: &Path, since: OffsetDateTime) -> std::io::Result<String> {
    read_recent_capped(dir, since, MAX_RECENT_BYTES)
}

/// Export size limit; the newest lines are kept.
const MAX_RECENT_BYTES: usize = 4 * 1024 * 1024;

fn read_recent_capped(
    dir: &Path,
    since: OffsetDateTime,
    max_bytes: usize,
) -> std::io::Result<String> {
    let mut lines = std::collections::VecDeque::new();
    let mut bytes = 0;
    for (day, path) in log_files(dir)? {
        if day < since.date() {
            continue;
        }
        // Day rollover may prune a file between listing and reading it.
        let file = match File::open(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            file => file?,
        };
        for line in std::io::BufReader::new(file).split(b'\n') {
            let line = line?;
            let line = String::from_utf8_lossy(&line);
            let ts = line.split('\t').next().unwrap_or_default();
            if OffsetDateTime::parse(ts, &Rfc3339).is_ok_and(|t| t >= since) {
                let line = redact(&line) + "\n";
                bytes += line.len();
                lines.push_back(line);
                while bytes > max_bytes {
                    bytes -= lines.pop_front().map_or(0, |dropped| dropped.len());
                }
            }
        }
    }
    Ok(lines.into_iter().collect::<String>())
}

fn internal(e: impl std::fmt::Display) -> SpotCoreError {
    SpotCoreError::Internal {
        message: e.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::macros::datetime;

    #[test]
    fn a_window_too_long_to_subtract_starts_at_the_epoch() {
        let now = datetime!(2026-01-01 0:00 UTC);
        assert_eq!(window_start(now, 60), datetime!(2025-12-31 23:59 UTC));
        assert_eq!(window_start(now, u64::MAX), OffsetDateTime::UNIX_EPOCH);
        assert_eq!(
            window_start(now, i64::MAX.unsigned_abs()),
            OffsetDateTime::UNIX_EPOCH
        );
    }

    #[derive(Default)]
    struct CollectingSink(Mutex<Vec<LogRecord>>);

    impl LogSink for CollectingSink {
        fn log(&self, record: LogRecord) {
            self.0.lock().unwrap().push(record);
        }
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(name: &str) -> Self {
            let nanos = OffsetDateTime::now_utc().unix_timestamp_nanos();
            let dir = std::env::temp_dir()
                .join(format!("spotcore-{name}-{}-{nanos}", std::process::id()));
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn path(&self) -> String {
            self.0.to_str().unwrap().to_owned()
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn pipeline(dir: &TempDir, level: LogLevel, sink: Arc<CollectingSink>) -> Pipeline {
        let config = LoggingConfig {
            log_dir: Some(dir.path()),
            max_level: level,
        };
        Pipeline::new(config, Some(sink), datetime!(2026-10-08 12:00 UTC)).unwrap()
    }

    fn emit(p: &Pipeline, level: log::Level, target: &str, msg: &str, now: OffsetDateTime) {
        p.log(
            &Record::builder()
                .level(level)
                .target(target)
                .args(format_args!("{msg}"))
                .build(),
            now,
        );
    }

    #[test]
    fn forwards_redacted_records_with_subsystem_and_category() {
        let dir = TempDir::new("forward");
        let sink = Arc::new(CollectingSink::default());
        let p = pipeline(&dir, LogLevel::Info, sink.clone());
        let now = datetime!(2026-10-08 12:00 UTC);

        emit(
            &p,
            log::Level::Info,
            "librespot_core::session",
            "Authenticated as 'alice' !",
            now,
        );

        assert_eq!(
            sink.0.lock().unwrap().as_slice(),
            [LogRecord {
                level: LogLevel::Info,
                subsystem: "librespot_core".to_owned(),
                category: "session".to_owned(),
                message: "Authenticated as '<redacted>' !".to_owned(),
            }]
        );
        let file = fs::read_to_string(dir.0.join("veya-2026-10-08.log")).unwrap();
        assert_eq!(
            file,
            "2026-10-08T12:00:00Z\tINFO\tlibrespot_core/session\tAuthenticated as '<redacted>' !\n"
        );
    }

    #[test]
    fn log_files_and_new_directories_are_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new("private");
        let nested = dir.0.join("a").join("logs");
        let config = LoggingConfig {
            log_dir: Some(nested.to_str().unwrap().to_owned()),
            max_level: LogLevel::Info,
        };
        let sink = Arc::new(CollectingSink::default());
        let now = datetime!(2026-10-08 12:00 UTC);
        let p = Pipeline::new(config, Some(sink), now).unwrap();
        emit(&p, log::Level::Info, "veya", "hello", now);
        let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&nested), 0o700);
        assert_eq!(mode(&nested.join("veya-2026-10-08.log")), 0o600);
    }

    #[test]
    fn trace_is_never_enabled_and_dependencies_stop_at_info() {
        let dir = TempDir::new("levels");
        let sink = Arc::new(CollectingSink::default());
        let p = pipeline(&dir, LogLevel::Debug, sink.clone());
        let now = datetime!(2026-10-08 12:00 UTC);

        emit(&p, log::Level::Trace, "librespot_oauth", "token", now);
        emit(&p, log::Level::Debug, "hyper::client", "noise", now);
        emit(&p, log::Level::Debug, "spotcore", "kept", now);
        emit(&p, log::Level::Info, "hyper::client", "kept too", now);

        let messages: Vec<_> = sink
            .0
            .lock()
            .unwrap()
            .iter()
            .map(|r| r.message.clone())
            .collect();
        assert_eq!(messages, ["kept", "kept too"]);
    }

    #[test]
    fn escapes_newlines_so_each_line_is_one_record() {
        let entry = LogRecord {
            level: LogLevel::Warn,
            subsystem: "veya".to_owned(),
            category: "ui".to_owned(),
            message: "a\nb\r\nc".to_owned(),
        };
        assert_eq!(
            format_line(&entry, datetime!(2026-10-08 12:00 UTC)),
            "2026-10-08T12:00:00Z\tWARN\tveya/ui\ta\\nb\\r\\nc\n"
        );
    }

    #[test]
    fn recent_logs_keep_only_the_newest_lines_within_the_cap() {
        let dir = TempDir::new("recent-cap");
        let p = pipeline(&dir, LogLevel::Info, Arc::new(CollectingSink::default()));
        let since = datetime!(2026-10-08 0:00 UTC);
        for minute in 0..5 {
            emit(
                &p,
                log::Level::Info,
                "spotcore",
                &format!("line {minute}"),
                since + time::Duration::minutes(minute),
            );
        }
        let line_len = read_recent_capped(&dir.0, since, usize::MAX).unwrap().len() / 5;
        let kept = read_recent_capped(&dir.0, since, line_len * 2).unwrap();
        assert_eq!(kept.lines().count(), 2);
        assert!(kept.contains("line 4") && kept.contains("line 3") && !kept.contains("line 2"));
    }

    #[test]
    fn recent_logs_keep_the_window_across_day_files_and_skip_torn_lines() {
        let dir = TempDir::new("recent");
        let sink = Arc::new(CollectingSink::default());
        let p = pipeline(&dir, LogLevel::Info, sink);

        emit(
            &p,
            log::Level::Info,
            "spotcore",
            "too old",
            datetime!(2026-10-07 11:59 UTC),
        );
        emit(
            &p,
            log::Level::Info,
            "spotcore",
            "yesterday",
            datetime!(2026-10-07 13:00 UTC),
        );
        emit(
            &p,
            log::Level::Info,
            "spotcore",
            "today",
            datetime!(2026-10-08 11:00 UTC),
        );
        let mut torn = OpenOptions::new()
            .append(true)
            .open(dir.0.join("veya-2026-10-08.log"))
            .unwrap();
        torn.write_all(b"2026-10-08T11:3").unwrap();
        // Relaunch after the crash: the first record must still parse.
        let relaunched = pipeline(&dir, LogLevel::Info, Arc::new(CollectingSink::default()));
        emit(
            &relaunched,
            log::Level::Info,
            "spotcore",
            "after crash",
            datetime!(2026-10-08 11:40 UTC),
        );

        let text = read_recent(&dir.0, datetime!(2026-10-07 12:00 UTC)).unwrap();

        assert_eq!(
            text,
            "2026-10-07T13:00:00Z\tINFO\tspotcore/spotcore\tyesterday\n\
             2026-10-08T11:00:00Z\tINFO\tspotcore/spotcore\ttoday\n\
             2026-10-08T11:40:00Z\tINFO\tspotcore/spotcore\tafter crash\n"
        );
    }

    #[test]
    fn day_rollover_prunes_while_running() {
        let dir = TempDir::new("rollover");
        let sink = Arc::new(CollectingSink::default());
        let p = pipeline(&dir, LogLevel::Info, sink);

        emit(
            &p,
            log::Level::Info,
            "spotcore",
            "a",
            datetime!(2026-10-08 12:00 UTC),
        );
        emit(
            &p,
            log::Level::Info,
            "spotcore",
            "b",
            datetime!(2026-10-11 0:01 UTC),
        );

        assert!(!dir.0.join("veya-2026-10-08.log").exists());
        assert!(dir.0.join("veya-2026-10-11.log").exists());
    }

    struct EchoingSink(Arc<Pipeline>, Mutex<usize>);

    impl LogSink for EchoingSink {
        fn log(&self, _record: LogRecord) {
            *self.1.lock().unwrap() += 1;
            emit(
                &self.0,
                log::Level::Info,
                "veya::echo",
                "again",
                datetime!(2026-10-08 12:00 UTC),
            );
        }
    }

    #[test]
    fn sink_that_logs_does_not_recurse() {
        let dir = TempDir::new("reentrant");
        let inner = Arc::new(pipeline(
            &dir,
            LogLevel::Info,
            Arc::new(CollectingSink::default()),
        ));
        let sink = Arc::new(EchoingSink(inner.clone(), Mutex::new(0)));
        let config = LoggingConfig {
            log_dir: None,
            max_level: LogLevel::Info,
        };
        let outer =
            Pipeline::new(config, Some(sink.clone()), datetime!(2026-10-08 12:00 UTC)).unwrap();

        emit(
            &outer,
            log::Level::Info,
            "spotcore",
            "once",
            datetime!(2026-10-08 12:00 UTC),
        );

        assert_eq!(*sink.1.lock().unwrap(), 1);
        let file = fs::read_to_string(dir.0.join("veya-2026-10-08.log")).unwrap_or_default();
        assert!(
            !file.contains("again"),
            "nested log on the same thread is dropped"
        );
    }

    #[test]
    fn prune_removes_only_expired_day_files_and_is_rerunnable() {
        let dir = TempDir::new("prune");
        for name in [
            "veya-2026-10-05.log",
            "veya-2026-10-06.log",
            "veya-2026-10-08.log",
            "notes.txt",
        ] {
            fs::write(dir.0.join(name), "x").unwrap();
        }

        prune(&dir.0, datetime!(2026-10-08 0:00 UTC).date()).unwrap();
        prune(&dir.0, datetime!(2026-10-08 0:00 UTC).date()).unwrap();

        let mut left: Vec<_> = fs::read_dir(&dir.0)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        left.sort();
        assert_eq!(
            left,
            ["notes.txt", "veya-2026-10-06.log", "veya-2026-10-08.log"]
        );
    }

    #[test]
    fn file_size_cap_writes_one_marker_then_drops() {
        let dir = TempDir::new("cap");
        let path = dir.0.join("veya-2026-10-08.log");
        fs::write(&path, vec![b'x'; MAX_FILE_BYTES as usize - 10]).unwrap();
        let sink = Arc::new(CollectingSink::default());
        let p = pipeline(&dir, LogLevel::Info, sink.clone());
        let now = datetime!(2026-10-08 12:00 UTC);

        emit(&p, log::Level::Info, "spotcore", "first overflow", now);
        emit(&p, log::Level::Info, "spotcore", "second overflow", now);

        let text = fs::read_to_string(&path).unwrap();
        assert_eq!(text.matches("size cap reached").count(), 1);
        assert!(!text.contains("overflow"));
        assert_eq!(
            sink.0.lock().unwrap().len(),
            2,
            "os.Logger still gets every record"
        );
    }

    /// The only test touching the global logger, so no cross-test races.
    #[test]
    fn global_api_reconfigures_and_exports_swift_messages() {
        let first = TempDir::new("global-a");
        let second = TempDir::new("global-b");
        let sink = Arc::new(CollectingSink::default());
        let config = |dir: &TempDir| LoggingConfig {
            log_dir: Some(dir.path()),
            max_level: LogLevel::Info,
        };

        configure_logging(config(&first), None).unwrap();
        configure_logging(config(&second), Some(sink.clone())).unwrap();
        add_log_redaction("alice99".to_owned());
        log_message(
            LogLevel::Info,
            "diagnostics".to_owned(),
            "hello alice99".to_owned(),
        );
        log_message(
            LogLevel::Debug,
            "diagnostics".to_owned(),
            "filtered".to_owned(),
        );

        let messages: Vec<_> = sink
            .0
            .lock()
            .unwrap()
            .iter()
            .map(|r| (r.subsystem.clone(), r.message.clone()))
            .collect();
        assert_eq!(
            messages,
            [("veya".to_owned(), "hello <redacted>".to_owned())]
        );
        let exported = recent_logs(3600).unwrap();
        assert!(
            exported.ends_with("\tINFO\tveya/diagnostics\thello <redacted>\n"),
            "{exported}"
        );
        assert_eq!(
            fs::read_dir(&first.0).unwrap().count(),
            0,
            "reconfigure moved logging to the new dir"
        );
    }

    #[test]
    fn split_target_maps_crate_and_module() {
        assert_eq!(
            split_target("librespot_core::connection::handshake"),
            ("librespot_core", "connection::handshake")
        );
        assert_eq!(split_target("spotcore"), ("spotcore", "spotcore"));
    }
}
