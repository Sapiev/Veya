import OSLog

/// Writes spotcore log records to the unified log, one subsystem per crate
/// (`<prefix>.librespot_core`) and the module path as category. Records from
/// Swift (crate `veya`) use the bare prefix. Rust redacts messages before they
/// cross the FFI, so they are logged as public.
public final class OSLogSink: LogSink {
    private let subsystemPrefix: String
    private let loggers = OSAllocatedUnfairLock<[String: Logger]>(initialState: [:])

    public init(subsystemPrefix: String) {
        self.subsystemPrefix = subsystemPrefix
    }

    public func log(record: LogRecord) {
        logger(for: record).log(level: record.level.osLogType, "\(record.message, privacy: .public)")
    }

    func subsystem(for record: LogRecord) -> String {
        record.subsystem == "veya" ? subsystemPrefix : "\(subsystemPrefix).\(record.subsystem)"
    }

    private func logger(for record: LogRecord) -> Logger {
        let subsystem = subsystem(for: record)
        let key = "\(subsystem)\t\(record.category)"
        return loggers.withLock { cache in
            if let logger = cache[key] {
                return logger
            }
            let logger = Logger(subsystem: subsystem, category: record.category)
            cache[key] = logger
            return logger
        }
    }
}

extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .error: .error
        case .warn: .default
        case .info: .info
        case .debug: .debug
        }
    }
}
