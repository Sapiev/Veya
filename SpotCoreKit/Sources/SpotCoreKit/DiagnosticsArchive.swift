import Foundation

/// Builds the zip behind Help > Export Diagnostics: the last 24 hours of
/// redacted logs, non-identifying system info and any crash reports the user
/// chose to keep. Nothing is uploaded.
public enum DiagnosticsArchive {
    public static let logWindowSeconds: UInt64 = 24 * 60 * 60

    /// Writes the archive into a fresh temporary directory and returns its URL.
    /// The caller moves it into place and deletes the parent directory.
    public static func make(named name: String, appVersion: String, crashReports: URL? = nil) throws -> URL {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
            .appending(path: "VeyaDiagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = parent.appending(path: name, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let logs = try recentLogs(windowSeconds: logWindowSeconds)
            try Data(logs.utf8).write(to: folder.appending(path: "logs.txt"))
            try Data(systemInfo(appVersion: appVersion).utf8).write(to: folder.appending(path: "system.txt"))
            if let crashReports, fileManager.fileExists(atPath: crashReports.path(percentEncoded: false)) {
                try fileManager.copyItem(at: crashReports, to: folder.appending(path: "Crashes"))
            }
            return try zip(folder, into: parent)
        } catch {
            try? fileManager.removeItem(at: parent)
            throw error
        }
    }

    static func systemInfo(appVersion: String) -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
            let arch = "arm64"
        #else
            let arch = "x86_64"
        #endif
        return redact(text: """
        Veya \(appVersion)
        spotcore \(version())
        macOS \(osVersion) (\(arch))
        Generated \(Date.now.ISO8601Format())

        """)
    }

    /// `.forUploading` makes the coordinator zip a directory; the zip it hands
    /// over is deleted when the accessor returns, so it is copied out inside.
    private static func zip(_ folder: URL, into parent: URL) throws -> URL {
        let destination = parent.appending(path: "\(folder.lastPathComponent).zip")
        var coordinatorError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipURL in
            do {
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError {
            throw error
        }
        return destination
    }
}
