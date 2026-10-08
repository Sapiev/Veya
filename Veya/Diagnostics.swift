import AppKit
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

    /// Safe to call more than once; spotcore swaps the configuration in place.
    static func startLogging() {
        #if DEBUG
            let level = LogLevel.debug
        #else
            let level = LogLevel.info
        #endif
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

    static func export() async {
        let localDay = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        let name = "Veya Diagnostics \(Date.now.formatted(localDay))"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).zip"
        panel.allowedContentTypes = [.zip]
        guard await panel.begin() == .OK, let destination = panel.url else { return }

        let appVersion = appVersion
        do {
            let archive = try await Task.detached {
                try DiagnosticsArchive.make(named: name, appVersion: appVersion)
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
