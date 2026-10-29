import Foundation
import OSLog
@testable import SpotCoreKit
import Testing

private final class CollectingSink: LogSink {
    let records = OSAllocatedUnfairLock<[LogRecord]>(initialState: [])

    func log(record: LogRecord) {
        records.withLock { $0.append(record) }
    }
}

/// Serialized: both tests reconfigure spotcore's process-wide logger.
@Suite(.serialized) struct LoggingTests {
    let logDir = FileManager.default.temporaryDirectory
        .appending(path: "SpotCoreKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func configure(sink: LogSink) throws {
        let config = LoggingConfig(logDir: logDir.path(percentEncoded: false), maxLevel: .info)
        try configureLogging(config: config, sink: sink)
    }

    @Test func swiftMessagesReachTheSinkRedacted() throws {
        let sink = CollectingSink()
        try configure(sink: sink)
        defer { try? FileManager.default.removeItem(at: logDir) }

        logMessage(level: .warn, category: "tests", message: "Authenticated as 'alice' !")

        let expected = LogRecord(
            level: .warn, subsystem: "veya", category: "tests", message: "Authenticated as '<redacted>' !"
        )
        #expect(sink.records.withLock { $0 } == [expected])
        #expect(try recentLogs(windowSeconds: 60).contains("WARN\tveya/tests\tAuthenticated as '<redacted>' !"))
    }

    @Test func archiveZipsRedactedLogsSystemInfoAndKeptCrashReports() throws {
        try configure(sink: CollectingSink())
        defer { try? FileManager.default.removeItem(at: logDir) }
        logMessage(level: .info, category: "tests", message: "access_token=secret123")
        let crashes = FileManager.default.temporaryDirectory.appending(path: "Crashes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: crashes) }
        try Data(#"{"m": "access_token=crashsecret"}"#.utf8).write(to: crashes.appending(path: "1.json"))

        let zip = try DiagnosticsArchive.make(named: "Veya Diagnostics", appVersion: "1.0 (1)", crashReports: crashes)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        let listing = try run("/usr/bin/unzip", "-l", zip.path)
        #expect(listing.contains("Veya Diagnostics/logs.txt"))
        #expect(listing.contains("Veya Diagnostics/system.txt"))
        #expect(listing.contains("Veya Diagnostics/Crashes/1.json"))
        let logs = try run("/usr/bin/unzip", "-p", zip.path, "Veya Diagnostics/logs.txt")
        #expect(logs.contains("access_token=<redacted>"))
        #expect(!logs.contains("secret123"))
        let crash = try run("/usr/bin/unzip", "-p", zip.path, "Veya Diagnostics/Crashes/1.json")
        #expect(!crash.contains("crashsecret"), "crash reports are redacted again at export")
    }

    @Test(arguments: ["", ".", "..", "../x", "a/b", "/etc"])
    func archiveRejectsNamesThatCouldEscapeTheTemporaryFolder(name: String) {
        #expect(throws: (any Error).self) { try DiagnosticsArchive.make(named: name, appVersion: "1") }
    }

    @Test func subsystemPerCrateAndLevelMapping() {
        let sink = OSLogSink(subsystemPrefix: "app.veya")
        let record = { (crate: String) in LogRecord(level: .info, subsystem: crate, category: "c", message: "") }
        #expect(sink.subsystem(for: record("librespot_core")) == "app.veya.librespot_core")
        #expect(sink.subsystem(for: record("veya")) == "app.veya")
        #expect([LogLevel.error, .warn, .info, .debug].map(\.osLogType) == [.error, .default, .info, .debug])
    }

    private func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: output, encoding: .utf8) ?? ""
    }
}
