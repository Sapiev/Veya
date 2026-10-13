@testable import SpotCoreKit
import Testing

struct SpotifyLinkTests {
    @Test(arguments: [
        ("spotify:album:4aawyAB9vmqN3uQ7FjRGTy", SpotifyLink.page(.album(uri: "spotify:album:4aawyAB9vmqN3uQ7FjRGTy"))),
        ("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc", .page(.playlist(uri: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"))),
        ("https://open.spotify.com/intl-de/artist/0OdUWJ0sBjDrqHygGUXeCF", .page(.artist(uri: "spotify:artist:0OdUWJ0sBjDrqHygGUXeCF"))),
        ("  http://open.spotify.com/show/abc123/\n", .page(.show(uri: "spotify:show:abc123"))),
        ("veya://track/11dFghVXANMlKmJXsNCbNl", .play(uri: "spotify:track:11dFghVXANMlKmJXsNCbNl")),
        ("spotify:episode:512ojhOuo1ktJprKbVcKyQ", .play(uri: "spotify:episode:512ojhOuo1ktJprKbVcKyQ")),
    ])
    func parsesSupportedLinks(text: String, link: SpotifyLink) {
        #expect(SpotifyLink(text) == link)
    }

    @Test(arguments: [
        "",
        "spotify:",
        "spotify:album:",
        "spotify:user:me",
        "spotify:album:abc:extra",
        "spotify:album:ab%2Fc",
        "https://example.com/album/abc",
        "https://open.spotify.com/album",
        "https://open.spotify.com/album/abc/def",
        "veya://album",
        "file:///album/abc",
        "Test Track",
    ])
    func rejectsAnythingElse(text: String) {
        #expect(SpotifyLink(text) == nil)
    }
}
