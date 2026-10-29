import Foundation
import Observation

/// PBI-804: MetricKit crash reports, kept only after the user opts in. They
/// stay on this Mac and leave it only inside Export Diagnostics.
@MainActor
@Observable
public final class CrashReports {
    /// True while the one-time question after the first crash is unanswered.
    public var asksForConsent = false

    public var keepsReports: Bool {
        didSet {
            defaults.set(keepsReports, forKey: Self.consentKey)
            if !keepsReports {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    public static let limit = 10
    public let directory: URL
    /// Holds reports awaiting the consent answer so quitting before it does not lose them.
    /// Beside `directory`, so Export Diagnostics never picks them up.
    private var pendingDirectory: URL {
        directory.appendingPathExtension("pending")
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Absent until answered, so a crash before then asks again.
    private static let consentKey = "crashReports.keep"
    @ObservationIgnored private var unanswered: [String] = []

    public init(defaults: UserDefaults = .standard, directory: URL) {
        self.defaults = defaults
        self.directory = directory
        keepsReports = defaults.bool(forKey: Self.consentKey)
        if defaults.object(forKey: Self.consentKey) == nil {
            unanswered = Self.reports(in: pendingDirectory)
            asksForConsent = !unanswered.isEmpty
        }
    }

    /// Takes MetricKit crash diagnostics as JSON.
    public func received(_ reports: [String]) {
        guard !reports.isEmpty else { return }
        if keepsReports {
            save(reports)
        } else if defaults.object(forKey: Self.consentKey) == nil {
            unanswered += reports
            asksForConsent = true
            write(reports, to: pendingDirectory)
        }
    }

    /// The reports that prompted the question are kept too when the answer is yes.
    public func answer(keep: Bool) {
        keepsReports = keep
        asksForConsent = false
        if keep {
            save(unanswered)
        }
        unanswered = []
        try? FileManager.default.removeItem(at: pendingDirectory)
    }

    /// Redacted again here: MetricKit payloads carry no account details, but a
    /// crash message could quote a token or username the core registered.
    private func save(_ reports: [String]) {
        write(reports, to: directory)
    }

    private func write(_ reports: [String], to folder: URL) {
        let fileManager = FileManager.default
        // Pruned even after a failed write, so a full disk cannot let the folder grow.
        defer { prune(folder) }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for report in reports {
                let name = "\(Date.now.timeIntervalSince1970)-\(UUID().uuidString).json"
                try Data(redact(text: report).utf8).write(to: folder.appending(path: name), options: .atomic)
            }
        } catch {
            logMessage(level: .error, category: "diagnostics", message: "Crash report not saved: \(error)")
        }
    }

    private func prune(_ folder: URL) {
        let fileManager = FileManager.default
        guard let saved = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for old in saved.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(Self.limit) {
            try? fileManager.removeItem(at: old)
        }
    }

    private static func reports(in folder: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
