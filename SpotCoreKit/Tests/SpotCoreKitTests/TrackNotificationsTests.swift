import CoreGraphics
@testable import SpotCoreKit
import Testing

@MainActor
struct TrackNotificationsTests {
    private final class Posted {
        var all: [(info: MediaControls.Info, image: CGImage?)] = []
        var enabled = true
    }

    private let posted = Posted()
    private let notifications: TrackNotifications

    init() {
        let posted = posted
        notifications = TrackNotifications(settle: .milliseconds(20), isEnabled: { posted.enabled }) {
            posted.all.append(($0, $1))
        }
    }

    private static func info(_ title: String, playing: Bool = true, elapsedMs: UInt32 = 0) -> MediaControls.Info {
        MediaControls.Info(
            title: title, artist: "Artist", album: "Album", durationMs: 200_000,
            elapsedMs: elapsedMs, rate: playing ? 1 : 0, isPlaying: playing, saved: false
        )
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    @Test func postsOncePerTrackWithTheLatestArtwork() async throws {
        let image = try #require(Self.image())
        notifications.update(Self.info("One"), nil)
        notifications.update(Self.info("One", elapsedMs: 1000), image)
        try await settle()
        notifications.update(Self.info("One", elapsedMs: 2000), image)
        try await settle()

        #expect(posted.all.map(\.info.title) == ["One"])
        #expect(posted.all.first?.image != nil)
    }

    @Test func rapidSkipsPostOnlyTheTrackThatStays() async throws {
        notifications.update(Self.info("One"), nil)
        notifications.update(Self.info("Two"), nil)
        notifications.update(Self.info("Three"), nil)
        try await settle()

        #expect(posted.all.map(\.info.title) == ["Three"])
    }

    @Test func pausedOrDisabledPostsNothing() async throws {
        notifications.update(Self.info("One", playing: false), nil)
        try await settle()
        posted.enabled = false
        notifications.update(Self.info("Two"), nil)
        try await settle()

        #expect(posted.all.isEmpty)
    }

    @Test func theSameTrackPostsAgainAfterPlaybackStops() async throws {
        notifications.update(Self.info("One"), nil)
        try await settle()
        notifications.update(nil, nil)
        notifications.update(Self.info("One"), nil)
        try await settle()

        #expect(posted.all.map(\.info.title) == ["One", "One"])
    }

    private static func image() -> CGImage? {
        CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
}
