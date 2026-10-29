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
        #expect(settings.crossfadeSeconds == 0)
    }

    /// PBI-208: the crossfade length survives a relaunch and stays within 0...12 s.
    @Test func crossfadeIsKeptAndClamped() {
        let settings = PlaybackSettings(defaults: defaults)
        settings.crossfadeSeconds = 7
        #expect(PlaybackSettings(defaults: defaults).crossfadeSeconds == 7)

        settings.crossfadeSeconds = 30
        #expect(settings.crossfadeSeconds == 12)
        defaults.set(99, forKey: "playback.crossfadeSeconds")
        #expect(PlaybackSettings(defaults: defaults).crossfadeSeconds == 12)
        defaults.set(-3, forKey: "playback.crossfadeSeconds")
        #expect(PlaybackSettings(defaults: defaults).crossfadeSeconds == 0)
    }

    /// PBI-501: the Connect device is named after the Mac and stays off the LAN until asked.
    @Test func freshInstallNamesTheConnectDeviceAfterTheMacWithZeroconfOff() {
        let settings = PlaybackSettings(defaults: defaults, macName: "Studio Mac")

        #expect(settings.connectDeviceName == "Studio Mac")
        #expect(!settings.zeroconf)
        #expect(PlaybackSettings(defaults: defaults, macName: nil).connectDeviceName == "Veya")
    }

    @Test func connectDeviceNameIsTrimmedPersistedAndBlankFallsBackToTheMacName() {
        let settings = PlaybackSettings(defaults: defaults, macName: "Studio Mac")
        settings.connectDeviceName = "  Kitchen  "
        settings.zeroconf = true

        let relaunched = PlaybackSettings(defaults: defaults, macName: "Studio Mac")
        #expect(relaunched.connectDeviceName == "Kitchen")
        #expect(relaunched.zeroconf)

        relaunched.connectDeviceName = " "
        #expect(relaunched.connectDeviceName == "Studio Mac")
        #expect(PlaybackSettings(defaults: defaults, macName: "Renamed Mac").connectDeviceName == "Renamed Mac")
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

    /// PBI-703: chosen folders survive relaunch through their bookmarks, once each.
    @Test func localFoldersPersistAsBookmarksWithoutDuplicates() throws {
        let music = try temporaryFolder("Music")
        let mixes = try temporaryFolder("Mixes")
        let settings = PlaybackSettings(defaults: defaults)

        settings.addLocalFolders([music, mixes, music.appending(path: "x/..")])

        #expect(settings.localFolderPaths == [music.path, mixes.path])
        let relaunched = PlaybackSettings(defaults: defaults)
        #expect(relaunched.localFolderPaths == [music.path, mixes.path])
        relaunched.addLocalFolders([mixes])
        #expect(relaunched.localFolderPaths == [music.path, mixes.path])
    }

    @Test func removedLocalFolderIsForgotten() throws {
        let music = try temporaryFolder("Music")
        let mixes = try temporaryFolder("Mixes")
        let settings = PlaybackSettings(defaults: defaults)
        settings.addLocalFolders([music, mixes])

        settings.removeLocalFolder(settings.localFolders[0])
        settings.removeLocalFolder(music)

        #expect(settings.localFolderPaths == [mixes.path])
        #expect(PlaybackSettings(defaults: defaults).localFolderPaths == [mixes.path])
    }

    /// A moved folder is still found; a missing one is hidden but its bookmark survives for a remount.
    @Test func movedLocalFolderFollowsAndMissingOneIsHiddenNotForgotten() throws {
        let music = try temporaryFolder("Music")
        let mixes = try temporaryFolder("Mixes")
        PlaybackSettings(defaults: defaults).addLocalFolders([music, mixes])
        let moved = music.deletingLastPathComponent().appending(path: "Moved \(UUID().uuidString)")
        try FileManager.default.moveItem(at: music, to: moved)
        try FileManager.default.removeItem(at: mixes)

        #expect(PlaybackSettings(defaults: defaults).localFolderPaths == [moved.path])
        #expect((defaults.array(forKey: "playback.localFolders") as? [Data])?.count == 2)
        #expect(PlaybackSettings(defaults: defaults).localFolderPaths == [moved.path])
        #expect((defaults.array(forKey: "playback.localFolders") as? [Data])?.count == 2)
    }

    @Test func hostileSavedPlaybackIsRejectedOrClamped() {
        func store(_ saved: [String: Any]) {
            defaults.set(saved, forKey: "playback.last")
        }
        store(["track": "javascript:alert(1)", "positionMs": 10, "savedAtMs": Int64(1)])
        #expect(PlaybackSettings(defaults: defaults).lastPlayback == nil)
        store(["track": "spotify:track:" + String(repeating: "a", count: 5000), "positionMs": 10, "savedAtMs": Int64(1)])
        #expect(PlaybackSettings(defaults: defaults).lastPlayback == nil)
        store(["track": "spotify:track:a", "positionMs": 10])
        #expect(PlaybackSettings(defaults: defaults).lastPlayback == nil)
        store(["track": "spotify:track:a", "positionMs": -5, "savedAtMs": Int64(1), "context": "https://evil"])
        let clamped = PlaybackSettings(defaults: defaults).lastPlayback
        #expect(clamped?.positionMs == 0)
        #expect(clamped?.contextUri == nil)
        store(["track": "spotify:track:a", "positionMs": Int.max, "savedAtMs": Int64(1)])
        #expect(PlaybackSettings(defaults: defaults).lastPlayback?.positionMs == UInt32.max)
        defaults.set("not a dictionary", forKey: "playback.last")
        #expect(PlaybackSettings(defaults: defaults).lastPlayback == nil)
    }

    private func temporaryFolder(_ name: String) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "PlaybackSettingsTests-\(UUID().uuidString)/\(name)").standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
}
