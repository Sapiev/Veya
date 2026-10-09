import Foundation
@testable import SpotCoreKit
import Testing

@MainActor
struct PlaybackSettingsTests {
    private let defaults: UserDefaults

    init() {
        let suite = "PlaybackSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func freshInstallPlaysAtFullVolumeWithNormalLoudness() {
        let settings = PlaybackSettings(defaults: defaults)

        #expect(settings.volume == 1)
        #expect(settings.playerVolume == .max)
        #expect(settings.normalisation == .normal)
        #expect(settings.outputDeviceUID == nil)
        #expect(settings.bitrate == .kbps320)
        #expect(settings.audioCacheLimitBytes == 1_073_741_824)
        #expect(settings.autoplay)
    }

    @Test func episodeSpeedIsClampedPersistedAndAppliedToEpisodesOnly() {
        let settings = PlaybackSettings(defaults: defaults)
        #expect(settings.episodeSpeed == 1)

        settings.episodeSpeed = 1.5
        let relaunched = PlaybackSettings(defaults: defaults)
        #expect(relaunched.episodeSpeed == 1.5)
        #expect(relaunched.rate(for: "spotify:episode:512ojhOuo1ktJprKbVcKyQ") == 1.5)
        #expect(relaunched.rate(for: "spotify:track:4uLU6hMCjMI75M1A2tKUQC") == 1)

        relaunched.episodeSpeed = 3
        #expect(relaunched.episodeSpeed == 2)
        relaunched.episodeSpeed = 0.5
        #expect(relaunched.episodeSpeed == 0.8)
        relaunched.episodeSpeed = .nan
        #expect(relaunched.episodeSpeed == 1)
    }

    @Test func choicesSurviveARelaunch() {
        let settings = PlaybackSettings(defaults: defaults)
        settings.volume = 0.5
        settings.loudness = .loud
        settings.normalises = false
        settings.outputDeviceUID = "interface-uid"
        settings.bitrate = .kbps96
        settings.audioCacheLimitBytes = 5 << 30
        settings.autoplay = false

        let relaunched = PlaybackSettings(defaults: defaults)

        #expect(relaunched.volume == 0.5)
        #expect(relaunched.playerVolume == UInt16.max / 2 + 1)
        #expect(relaunched.loudness == .loud)
        #expect(relaunched.normalisation == nil)
        #expect(relaunched.outputDeviceUID == "interface-uid")
        #expect(relaunched.bitrate == .kbps96)
        #expect(relaunched.audioCacheLimitBytes == 5 << 30)
        #expect(!relaunched.autoplay)
    }

    @Test func choosingSystemDefaultAgainIsRemembered() {
        let settings = PlaybackSettings(defaults: defaults)
        settings.outputDeviceUID = "interface-uid"
        settings.outputDeviceUID = nil

        #expect(PlaybackSettings(defaults: defaults).outputDeviceUID == nil)
    }

    @Test func volumeIsClampedToTheSliderRange() {
        let settings = PlaybackSettings(defaults: defaults)

        settings.volume = 1.5
        #expect(settings.volume == 1)
        settings.volume = -1
        #expect(settings.volume == 0)
        #expect(PlaybackSettings(defaults: defaults).volume == 0)
    }

    @Test func outOfRangeStoredVolumeIsClamped() {
        defaults.set(7.0, forKey: "playback.volume")

        #expect(PlaybackSettings(defaults: defaults).playerVolume == .max)
    }

    @Test func nanVolumeFallsBackToFull() {
        let settings = PlaybackSettings(defaults: defaults)
        settings.volume = .nan
        #expect(settings.playerVolume == .max)

        defaults.set(Double.nan, forKey: "playback.volume")
        #expect(PlaybackSettings(defaults: defaults).playerVolume == .max)
    }

    @Test func unknownStoredLoudnessFallsBackToNormal() {
        defaults.set("deafening", forKey: "playback.loudness")

        #expect(PlaybackSettings(defaults: defaults).loudness == .normal)
    }

    @Test func unknownStoredQualityAndCacheLimitFallBackToDefaults() {
        defaults.set("9000", forKey: "playback.bitrate")
        defaults.set("-1", forKey: "playback.audioCacheLimit")
        let settings = PlaybackSettings(defaults: defaults)

        #expect(settings.bitrate == .kbps320)
        #expect(settings.audioCacheLimitBytes == PlaybackSettings.defaultAudioCacheLimitBytes)
    }
}
