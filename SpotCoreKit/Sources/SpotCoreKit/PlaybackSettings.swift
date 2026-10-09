import Foundation
import Observation

/// App volume and loudness normalisation, persisted across launches.
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

    @ObservationIgnored private let defaults: UserDefaults

    /// Defaults to full volume, which leaves the signal unchanged, and Normal
    /// loudness as Spotify does.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedVolume = Self.clamped(defaults.object(forKey: Key.volume) as? Double ?? 1)
        normalises = defaults.object(forKey: Key.normalises) as? Bool ?? true
        loudness = defaults.string(forKey: Key.loudness).flatMap(LoudnessPreset.init(storedName:)) ?? .normal
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
