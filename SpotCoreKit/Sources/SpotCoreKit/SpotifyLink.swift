import Foundation

/// PBI-606: a link opened with Veya: a `spotify:` URI, an `open.spotify.com`
/// link, or Veya's own `veya://<type>/<id>`. Pages open; tracks and episodes play.
public enum SpotifyLink: Equatable, Sendable {
    case page(Route)
    case play(uri: String)

    /// Text from outside the app, such as a pasted or opened link; nil unless it names a Spotify item.
    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Self.maxLength,
              let parts = Self.typeAndID(text),
              parts.count == 2,
              !parts[1].isEmpty,
              // Item ids are at most 22 base-62 characters.
              parts[1].utf8.count <= (parts[0] == "user" ? Self.maxLength : 22),
              // `.` and `..` are path segments, not usernames.
              !(parts[1] == "." || parts[1] == ".."),
              // Usernames also carry `.`, `_` and `-`; the core checks them again before they reach a path.
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || (parts[0] == "user" && "._-".contains($0))) })
        else { return nil }
        let uri = "spotify:\(parts[0]):\(parts[1])"
        switch parts[0] {
        case "user": self = .page(.profile(username: parts[1]))
        case "track", "episode": self = .play(uri: uri)
        case "album": self = .page(.album(uri: uri))
        case "artist": self = .page(.artist(uri: uri))
        case "playlist": self = .page(.playlist(uri: uri))
        case "show": self = .page(.show(uri: uri))
        default: return nil
        }
    }

    /// A track, episode or local file URI that may join the queue; nil for anything else.
    public static func queueableURI(_ text: String) -> String? {
        if text.hasPrefix("spotify:local:") {
            return text
        }
        guard case let .play(uri)? = SpotifyLink(text) else { return nil }
        return uri
    }

    /// `intl-de`, `intl-pt-br`: language and optional region.
    private static func isLocaleSegment(_ segment: String) -> Bool {
        segment.wholeMatch(of: /intl-[a-z]{2,3}(-[A-Za-z]{2,4})?/) != nil
    }

    private static let maxLength = 512

    private static func typeAndID(_ text: String) -> [String]? {
        if text.lowercased().hasPrefix("spotify:") {
            return text.split(separator: ":", omittingEmptySubsequences: false).dropFirst().map(String.init)
        }
        guard let url = URL(string: text) else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch url.scheme?.lowercased() {
        case "veya":
            return url.host.map { [$0] + path }
        case "https", "http":
            guard url.host?.lowercased() == "open.spotify.com", url.user == nil, url.port == nil else { return nil }
            // Shared links may carry a locale segment, as in /intl-de/track/ID.
            return path.first.map(isLocaleSegment) == true ? Array(path.dropFirst()) : path
        default:
            return nil
        }
    }
}
