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
        ("SPOTIFY:track:11dFghVXANMlKmJXsNCbNl", .play(uri: "spotify:track:11dFghVXANMlKmJXsNCbNl")),
        ("https://open.spotify.com/intl-pt-br/track/11dFghVXANMlKmJXsNCbNl", .play(uri: "spotify:track:11dFghVXANMlKmJXsNCbNl")),
        ("https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl?si=abc&x=1", .play(uri: "spotify:track:11dFghVXANMlKmJXsNCbNl")),
        ("spotify:user:me", .page(.profile(username: "me"))),
        ("https://open.spotify.com/user/first.last_1-2?si=x", .page(.profile(username: "first.last_1-2"))),
    ])
    func parsesSupportedLinks(text: String, link: SpotifyLink) {
        #expect(SpotifyLink(text) == link)
    }

    @Test(arguments: [
        "",
        "spotify:",
        "spotify:album:",
        "spotify:user:a%2Fb",
        "spotify:album:a.b",
        "spotify:album:abc:extra",
        "spotify:album:ab%2Fc",
        "https://example.com/album/abc",
        "https://open.spotify.com/album",
        "https://open.spotify.com/album/abc/def",
        "veya://album",
        "file:///album/abc",
        "Test Track",
        "spotify:user:.",
        "spotify:user:..",
        "spotify:track:\(String(repeating: "a", count: 23))",
        "spotify:user:\(String(repeating: "a", count: 600))",
        "https://open.spotify.com/intl-evil/track/abc",
        "https://open.spotify.com/intl-/track/abc",
        "https://open.spotify.com.evil.com/track/abc",
        "https://open.spotify.com@evil.com/track/abc",
        "https://user:pw@open.spotify.com/track/abc",
        "https://open.spotify.com:8443/track/abc",
        "https://evil.com/?u=https://open.spotify.com/track/abc"
    ])
    func rejectsAnythingElse(text: String) {
        #expect(SpotifyLink(text) == nil)
    }
}
