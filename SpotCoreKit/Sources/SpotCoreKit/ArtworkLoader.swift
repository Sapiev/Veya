import CryptoKit
import Foundation
import ImageIO
import os

extension Artwork {
    /// Spotify's CDN widths per size class, used when the metadata omits `width`.
    var pixelWidth: Int {
        if width > 0 { return Int(width) }
        switch size {
        case .small: return 64
        case .default: return 300
        case .large: return 640
        case .xLarge: return 1280
        }
    }
}

extension [Artwork] {
    /// The smallest artwork at least `pixels` wide, or the largest when none is.
    public func best(forPixels pixels: Int) -> Artwork? {
        let bySize = sorted { $0.pixelWidth < $1.pixelWidth }
        return bySize.first { $0.pixelWidth >= pixels } ?? bySize.last
    }
}

/// Cover art for the UI: picks a size, caches downloads on disk and decoded
/// thumbnails in memory, and decodes off the main thread.
public actor ArtworkLoader {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let defaultDiskLimitBytes = 300 * 1024 * 1024

    private let memory = NSCache<NSString, CGImage>()
    private let disk: ArtworkDiskCache
    private let fetch: Fetch
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    public init(directory: URL, diskLimitBytes: Int = defaultDiskLimitBytes, fetch: Fetch? = nil) {
        disk = ArtworkDiskCache(directory: directory, limitBytes: diskLimitBytes)
        self.fetch = fetch ?? Self.download
        memory.totalCostLimit = 100 * 1024 * 1024
    }

    /// The artwork decoded to fit `pixels` on its longer side; nil when it cannot be loaded.
    public func image(for artwork: [Artwork], pixels: Int) async -> CGImage? {
        guard let chosen = artwork.best(forPixels: pixels), let url = URL(string: chosen.url) else {
            return nil
        }
        let key = "\(pixels)|\(chosen.url)" as NSString
        if let cached = memory.object(forKey: key) { return cached }
        if let running = inFlight[key as String] { return await running.value }

        let task = Task { await load(url, pixels: pixels) }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image { memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }

    private nonisolated func load(_ url: URL, pixels: Int) async -> CGImage? {
        if let data = disk.data(for: url), let image = Self.thumbnail(data, pixels: pixels) {
            return image
        }
        do {
            let data = try await fetch(url)
            // Only bytes that decode are cached, so an error page never sticks.
            guard let image = Self.thumbnail(data, pixels: pixels) else {
                Self.log.error("artwork did not decode: \(url, privacy: .public)")
                return nil
            }
            await disk.store(data, for: url)
            return image
        } catch {
            Self.log.error("artwork download failed: \(error, privacy: .public)")
            return nil
        }
    }

    static func thumbnail(_ data: Data, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static let log = Logger(subsystem: "veya", category: "artwork")
}

/// Downloaded artwork files, evicted least recently used first once over the limit.
/// Writes are atomic, so a crash mid-write leaves either the old file or none.
actor ArtworkDiskCache {
    private let directory: URL
    private let limitBytes: Int
    private var totalBytes: Int?

    init(directory: URL, limitBytes: Int) {
        self.directory = directory
        self.limitBytes = limitBytes
    }

    /// Reading marks the file as recently used.
    nonisolated func data(for url: URL) -> Data? {
        let file = file(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func store(_ data: Data, for url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(for: url), options: .atomic)
        } catch {
            return
        }
        // The first store scans what earlier launches left. Overwrites count
        // twice in the running total; the next scan corrects it.
        guard let known = totalBytes else { return trim() }
        totalBytes = known + data.count
        if known + data.count > limitBytes { trim() }
    }

    /// Evicts down to 90% of the limit so a full cache does not rescan on every store.
    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        )) ?? []
        var entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        if total > limitBytes {
            entries.sort { $0.2 < $1.2 }
            for (file, size, _) in entries where total > limitBytes * 9 / 10 {
                try? FileManager.default.removeItem(at: file)
                total -= size
            }
        }
        totalBytes = total
    }

    private nonisolated func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined())
    }
}
