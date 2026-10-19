import Foundation
import Observation
import SystemConfiguration

/// App volume, loudness normalisation, crossfade, output device, streaming quality,
/// audio cache size, episode speed, autoplay, the Spotify Connect device and
/// local file folders, persisted across launches.
@MainActor
@Observable
public final class PlaybackSettings {
    /// 0...1 along the player's logarithmic curve, independent of the system volume.
    public var volume: Double {
        get { storedVolume }
        set {
            storedVolume = Self.clamped(newValue)
            defaults.set(storedVolume, forKey: Key.volume)
        }
    }

    private var storedVolume: Double

    public var normalises: Bool {
        didSet { defaults.set(normalises, forKey: Key.normalises) }
    }

    public var loudness: LoudnessPreset {
        didSet { defaults.set(loudness.storedName, forKey: Key.loudness) }
    }

    /// Seconds a naturally ending track blends into the next, 0 (off) to 12.
    public var crossfadeSeconds: UInt8 {
        get { storedCrossfadeSeconds }
        set {
            storedCrossfadeSeconds = min(newValue, Self.maxCrossfadeSeconds)
            defaults.set(Int(storedCrossfadeSeconds), forKey: Key.crossfade)
        }
    }

    private var storedCrossfadeSeconds: UInt8

    public static let maxCrossfadeSeconds: UInt8 = 12

    /// UID of the chosen output device; `nil` follows the system default.
    public var outputDeviceUID: String? {
        didSet { defaults.set(outputDeviceUID, forKey: Key.outputDevice) }
    }

    public var bitrate: Bitrate {
        didSet { defaults.set(bitrate.storedName, forKey: Key.bitrate) }
    }

    /// Whether radio for the context follows once it runs out.
    public var autoplay: Bool {
        didSet { defaults.set(autoplay, forKey: Key.autoplay) }
    }

    /// Read when the audio cache opens; `SessionModel.setAudioCacheLimit` applies a change.
    public var audioCacheLimitBytes: UInt64 {
        didSet { defaults.set(String(audioCacheLimitBytes), forKey: Key.audioCacheLimit) }
    }

    public static let defaultAudioCacheLimitBytes: UInt64 = 1 << 30

    /// Podcast episode speed, clamped to `AudioEngine.rateRange`; music always plays at 1x.
    public var episodeSpeed: Float {
        get { storedEpisodeSpeed }
        set {
            storedEpisodeSpeed = AudioEngine.clamped(rate: newValue)
            defaults.set(storedEpisodeSpeed, forKey: Key.episodeSpeed)
        }
    }

    private var storedEpisodeSpeed: Float

    /// What phones list this Mac as; a blank name falls back to the Mac's name.
    public var connectDeviceName: String {
        get { storedConnectDeviceName ?? macName }
        set {
            let name = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            storedConnectDeviceName = name.isEmpty ? nil : name
            defaults.set(storedConnectDeviceName, forKey: Key.connectDeviceName)
        }
    }

    private var storedConnectDeviceName: String?

    /// Advertises the Connect device to other Spotify apps on the local network.
    public var zeroconf: Bool {
        didSet { defaults.set(zeroconf, forKey: Key.zeroconf) }
    }

    /// This Mac's last playback, for the launch restore. One key, so each write replaces it whole.
    public var lastPlayback: SavedPlayback? {
        get {
            guard let saved = defaults.dictionary(forKey: Key.lastPlayback),
                  let track = saved["track"] as? String,
                  let position = saved["positionMs"] as? Int,
                  let savedAt = saved["savedAtMs"] as? Int64
            else { return nil }
            return SavedPlayback(
                trackUri: track,
                contextUri: saved["context"] as? String,
                positionMs: UInt32(clamping: position),
                savedAtMs: savedAt
            )
        }
        set {
            let stored = newValue.map { saved -> [String: Any] in
                var stored: [String: Any] = [
                    "track": saved.trackUri, "positionMs": Int(saved.positionMs), "savedAtMs": saved.savedAtMs,
                ]
                stored["context"] = saved.contextUri
                return stored
            }
            defaults.set(stored, forKey: Key.lastPlayback)
        }
    }

    /// Folders scanned for `spotify:local:` files, in the order the user added them.
    public var localFolders: [URL] {
        folders.map(\.url)
    }

    private var folders: [LocalFolder]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let macName: String

    /// Defaults to full volume, which leaves the signal unchanged, Normal
    /// loudness as Spotify does, no crossfade, 320 kbps, a 1 GB cache, autoplay on, the
    /// Mac's name as the Connect device name and zeroconf off.
    public init(defaults: UserDefaults = .standard, macName: String? = PlaybackSettings.computerName()) {
        self.defaults = defaults
        self.macName = macName ?? "Veya"
        storedVolume = Self.clamped(defaults.object(forKey: Key.volume) as? Double ?? 1)
        normalises = defaults.object(forKey: Key.normalises) as? Bool ?? true
        loudness = defaults.string(forKey: Key.loudness).flatMap(LoudnessPreset.init(storedName:)) ?? .normal
        storedCrossfadeSeconds = UInt8(clamping: min(defaults.integer(forKey: Key.crossfade), Int(Self.maxCrossfadeSeconds)))
        outputDeviceUID = defaults.string(forKey: Key.outputDevice)
        bitrate = defaults.string(forKey: Key.bitrate).flatMap(Bitrate.init(storedName:)) ?? .kbps320
        autoplay = defaults.object(forKey: Key.autoplay) as? Bool ?? true
        audioCacheLimitBytes = defaults.string(forKey: Key.audioCacheLimit).flatMap(UInt64.init)
            ?? Self.defaultAudioCacheLimitBytes
        storedEpisodeSpeed = AudioEngine.clamped(rate: defaults.object(forKey: Key.episodeSpeed) as? Float ?? 1)
        storedConnectDeviceName = defaults.string(forKey: Key.connectDeviceName)
        zeroconf = defaults.object(forKey: Key.zeroconf) as? Bool ?? false
        let saved = defaults.array(forKey: Key.localFolders) as? [Data] ?? []
        folders = []
        for bookmark in saved {
            guard let folder = LocalFolder(bookmark: bookmark) else { continue }
            if folders.contains(where: { $0.path == folder.path }) {
                folder.stopAccessing()
            } else {
                folders.append(folder)
            }
        }
        if folders.map(\.bookmark) != saved {
            saveLocalFolders()
        }
    }

    isolated deinit {
        folders.forEach { $0.stopAccessing() }
    }

    /// Adds the folders not already listed; a folder that cannot be bookmarked is skipped.
    public func addLocalFolders(_ urls: [URL]) {
        for url in urls where !folders.contains(where: { $0.path == LocalFolder.path(url) }) {
            // An open panel's URL may need its scope opened before it can be bookmarked.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? LocalFolder.bookmark(url), let folder = LocalFolder(bookmark: bookmark) else { continue }
            folders.append(folder)
        }
        saveLocalFolders()
    }

    public func removeLocalFolder(_ url: URL) {
        folders.removeAll { folder in
            guard folder.path == LocalFolder.path(url) else { return false }
            folder.stopAccessing()
            return true
        }
        saveLocalFolders()
    }

    /// What `SpotPlayer.setLocalFolders` takes.
    public var localFolderPaths: [String] {
        folders.map(\.path)
    }

    private func saveLocalFolders() {
        defaults.set(folders.map(\.bookmark), forKey: Key.localFolders)
    }

    /// The Mac's localized name from Sharing settings.
    public nonisolated static func computerName() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    /// What `AudioEngine.rate` should be while `uri` plays.
    public func rate(for uri: String) -> Float {
        uri.hasPrefix("spotify:episode:") ? episodeSpeed : 1
    }

    /// What `SpotPlayer` takes for `volume`.
    public var playerVolume: UInt16 {
        UInt16((volume * Double(UInt16.max)).rounded())
    }

    /// What `SpotPlayer` takes for `normalisation`; `nil` turns it off.
    public var normalisation: LoudnessPreset? {
        normalises ? loudness : nil
    }

    /// NaN would trap in `playerVolume`, so it falls back to full volume.
    static func clamped(_ volume: Double) -> Double {
        volume.isNaN ? 1 : min(max(volume, 0), 1)
    }

    private enum Key {
        static let volume = "playback.volume"
        static let normalises = "playback.normalises"
        static let loudness = "playback.loudness"
        static let crossfade = "playback.crossfadeSeconds"
        static let outputDevice = "playback.outputDevice"
        static let bitrate = "playback.bitrate"
        static let autoplay = "playback.autoplay"
        // A string: UserDefaults has no UInt64 and Int64 would admit negatives.
        static let audioCacheLimit = "playback.audioCacheLimit"
        static let episodeSpeed = "playback.episodeSpeed"
        static let connectDeviceName = "connect.deviceName"
        static let zeroconf = "connect.zeroconf"
        static let localFolders = "playback.localFolders"
        static let lastPlayback = "playback.last"
    }
}

/// A chosen folder, read through its security-scoped bookmark so access survives relaunch.
private struct LocalFolder {
    let url: URL
    /// Refreshed when the bookmark went stale, e.g. after the folder moved.
    let bookmark: Data
    private let accessing: Bool

    /// Nil when the folder is gone. Starts access, which `stopAccessing` balances once.
    /// shortcut: an unresolvable folder (unmounted volume) is dropped, keep its bookmark if that bites.
    init?(bookmark: Data) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        else { return nil }
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
        self.bookmark = stale ? (try? Self.bookmark(url)) ?? bookmark : bookmark
    }

    /// Compares folders whatever their trailing slash or `..` components.
    var path: String {
        Self.path(url)
    }

    static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func stopAccessing() {
        if accessing { url.stopAccessingSecurityScopedResource() }
    }
}

private extension LoudnessPreset {
    /// Stable names, so a reordered Rust enum cannot remap saved choices.
    var storedName: String {
        switch self {
        case .quiet: "quiet"
        case .normal: "normal"
        case .loud: "loud"
        }
    }

    init?(storedName: String) {
        switch storedName {
        case "quiet": self = .quiet
        case "normal": self = .normal
        case "loud": self = .loud
        default: return nil
        }
    }
}

private extension Bitrate {
    /// Stable names, so a reordered Rust enum cannot remap saved choices.
    var storedName: String {
        switch self {
        case .kbps96: "96"
        case .kbps160: "160"
        case .kbps320: "320"
        }
    }

    init?(storedName: String) {
        switch storedName {
        case "96": self = .kbps96
        case "160": self = .kbps160
        case "320": self = .kbps320
        default: return nil
        }
    }
}
