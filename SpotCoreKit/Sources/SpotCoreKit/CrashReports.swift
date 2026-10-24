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

    @ObservationIgnored private let defaults: UserDefaults
    /// Absent until answered, so a crash before then asks again.
    private static let consentKey = "crashReports.keep"
    @ObservationIgnored private var unanswered: [String] = []

    public init(defaults: UserDefaults = .standard, directory: URL) {
        self.defaults = defaults
        self.directory = directory
        keepsReports = defaults.bool(forKey: Self.consentKey)
    }

    /// Takes MetricKit crash diagnostics as JSON.
    public func received(_ reports: [String]) {
        guard !reports.isEmpty else { return }
        if keepsReports {
            save(reports)
        } else if defaults.object(forKey: Self.consentKey) == nil {
            unanswered += reports
            asksForConsent = true
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
    }

    /// Redacted again here: MetricKit payloads carry no account details, but a
    /// crash message could quote a token or username the core registered.
    private func save(_ reports: [String]) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for report in reports {
                let name = "\(Date.now.timeIntervalSince1970)-\(UUID().uuidString).json"
                try Data(redact(text: report).utf8).write(to: directory.appending(path: name))
            }
            let saved = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in saved.dropFirst(Self.limit) {
                try fileManager.removeItem(at: old)
            }
        } catch {
            logMessage(level: .error, category: "diagnostics", message: "Crash report not saved: \(error)")
        }
    }
}
