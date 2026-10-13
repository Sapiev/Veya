import Foundation

/// PBI-606: a link opened with Veya: a `spotify:` URI, an `open.spotify.com`
/// link, or Veya's own `veya://<type>/<id>`. Pages open; tracks and episodes play.
public enum SpotifyLink: Equatable, Sendable {
    case page(Route)
    case play(uri: String)

    /// Text from outside the app, such as a pasted or opened link; nil unless it names a Spotify item.
    public init?(_ text: String) {
        guard let parts = Self.typeAndID(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.count == 2,
              !parts[1].isEmpty,
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let uri = "spotify:\(parts[0]):\(parts[1])"
        switch parts[0] {
        case "track", "episode": self = .play(uri: uri)
        case "album": self = .page(.album(uri: uri))
        case "artist": self = .page(.artist(uri: uri))
        case "playlist": self = .page(.playlist(uri: uri))
        case "show": self = .page(.show(uri: uri))
        default: return nil
        }
    }

    private static func typeAndID(_ text: String) -> [String]? {
        if text.hasPrefix("spotify:") {
            return text.split(separator: ":", omittingEmptySubsequences: false).dropFirst().map(String.init)
        }
        guard let url = URL(string: text) else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch url.scheme?.lowercased() {
        case "veya":
            return url.host.map { [$0] + path }
        case "https", "http":
            guard url.host?.lowercased() == "open.spotify.com" else { return nil }
            // Shared links may carry a locale segment, as in /intl-de/track/ID.
            return path.first?.hasPrefix("intl-") == true ? Array(path.dropFirst()) : path
        default:
            return nil
        }
    }
}
