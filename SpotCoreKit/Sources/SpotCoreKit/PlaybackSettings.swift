import Foundation
import Observation

/// App volume, loudness normalisation, output device, streaming quality and
/// audio cache size, persisted across launches.
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

    /// UID of the chosen output device; `nil` follows the system default.
    public var outputDeviceUID: String? {
        didSet { defaults.set(outputDeviceUID, forKey: Key.outputDevice) }
    }

    public var bitrate: Bitrate {
        didSet { defaults.set(bitrate.storedName, forKey: Key.bitrate) }
    }

    /// Read when the audio cache opens; `SessionModel.setAudioCacheLimit` applies a change.
    public var audioCacheLimitBytes: UInt64 {
        didSet { defaults.set(String(audioCacheLimitBytes), forKey: Key.audioCacheLimit) }
    }

    public static let defaultAudioCacheLimitBytes: UInt64 = 1 << 30

    @ObservationIgnored private let defaults: UserDefaults

    /// Defaults to full volume, which leaves the signal unchanged, Normal
    /// loudness as Spotify does, 320 kbps and a 1 GB cache.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedVolume = Self.clamped(defaults.object(forKey: Key.volume) as? Double ?? 1)
        normalises = defaults.object(forKey: Key.normalises) as? Bool ?? true
        loudness = defaults.string(forKey: Key.loudness).flatMap(LoudnessPreset.init(storedName:)) ?? .normal
        outputDeviceUID = defaults.string(forKey: Key.outputDevice)
        bitrate = defaults.string(forKey: Key.bitrate).flatMap(Bitrate.init(storedName:)) ?? .kbps320
        audioCacheLimitBytes = defaults.string(forKey: Key.audioCacheLimit).flatMap(UInt64.init)
            ?? Self.defaultAudioCacheLimitBytes
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
    private static func clamped(_ volume: Double) -> Double {
        volume.isNaN ? 1 : min(max(volume, 0), 1)
    }

    private enum Key {
        static let volume = "playback.volume"
        static let normalises = "playback.normalises"
        static let loudness = "playback.loudness"
        static let outputDevice = "playback.outputDevice"
        static let bitrate = "playback.bitrate"
        // A string: UserDefaults has no UInt64 and Int64 would admit negatives.
        static let audioCacheLimit = "playback.audioCacheLimit"
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
