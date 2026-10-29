import AppKit
import MetricKit
import OSLog
import SpotCoreKit
import UniformTypeIdentifiers

enum Diagnostics {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "Veya"

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// The Settings › Advanced choice, stored by name.
    static let levelKey = "advanced.logLevel"

    #if DEBUG
        static let defaultLevel = LogLevel.debug
    #else
        static let defaultLevel = LogLevel.info
    #endif

    static func savedLevel(in defaults: UserDefaults) -> LogLevel {
        defaults.string(forKey: levelKey).flatMap(LogLevel.init(storedName:)) ?? defaultLevel
    }

    /// Safe to call more than once; spotcore swaps the configuration in place.
    static func startLogging(level: LogLevel) {
        let logDir = URL.libraryDirectory.appending(path: "Logs/Veya", directoryHint: .isDirectory)
        let sink = OSLogSink(subsystemPrefix: bundleID)
        do {
            let config = LoggingConfig(logDir: logDir.path(percentEncoded: false), maxLevel: level)
            try configureLogging(config: config, sink: sink)
        } catch {
            // Still log to os.Logger; export will just have no file history.
            try? configureLogging(config: LoggingConfig(logDir: nil, maxLevel: level), sink: sink)
            logMessage(level: .error, category: "diagnostics", message: "File logging unavailable: \(error)")
        }
    }

    static let crashReportsDirectory = URL.libraryDirectory.appending(path: "Logs/Veya/Crashes", directoryHint: .isDirectory)

    /// A second Export Diagnostics while the first runs would stack save panels and archives.
    @MainActor private static var isExporting = false

    @MainActor static func export(crashReports: URL) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        let localDay = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        let name = "Veya Diagnostics \(Date.now.formatted(localDay))"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).zip"
        panel.allowedContentTypes = [.zip]
        guard await panel.begin() == .OK, let destination = panel.url else { return }

        let appVersion = appVersion
        do {
            let archive = try await Task.detached {
                try DiagnosticsArchive.make(named: name, appVersion: appVersion, crashReports: crashReports)
            }.value
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            // Written in place rather than moved: the sandbox grants only this
            // URL, and it may sit on another volume than the temp directory.
            try Data(contentsOf: archive).write(to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            logMessage(level: .error, category: "diagnostics", message: "Export failed: \(error)")
            NSAlert(error: error).runModal()
        }
    }
}

extension LogLevel {
    static let choices: [LogLevel] = [.error, .warn, .info, .debug]

    /// Stable names, so a reordered Rust enum cannot remap saved choices.
    var storedName: String {
        switch self {
        case .error: "error"
        case .warn: "warn"
        case .info: "info"
        case .debug: "debug"
        }
    }

    init?(storedName: String) {
        guard let level = Self.choices.first(where: { $0.storedName == storedName }) else { return nil }
        self = level
    }
}

/// Hands each launch's MetricKit crash diagnostics to `CrashReports`.
final class MetricKitCrashes: NSObject, MXMetricManagerSubscriber {
    /// MetricKit does not document keeping its subscribers alive.
    private static var subscriber: MetricKitCrashes?
    private let received: @MainActor ([String]) -> Void

    private init(received: @escaping @MainActor ([String]) -> Void) {
        self.received = received
    }

    static func subscribe(_ received: @escaping @MainActor ([String]) -> Void) {
        let subscriber = MetricKitCrashes(received: received)
        Self.subscriber = subscriber
        MXMetricManager.shared.add(subscriber)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { $0.crashDiagnostics ?? [] }
            .compactMap { String(bytes: $0.jsonRepresentation(), encoding: .utf8) }
        Task { @MainActor in received(reports) }
    }
}
