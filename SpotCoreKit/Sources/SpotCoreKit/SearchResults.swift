import Foundation

/// The Search page's filter chips; podcasts and episodes show only under All.
public enum SearchFilter: CaseIterable, Hashable, Sendable {
    case all, songs, artists, albums, playlists

    public var kind: SearchKind? {
        switch self {
        case .all: nil
        case .songs: .track
        case .artists: .artist
        case .albums: .album
        case .playlists: .playlist
        }
    }
}

public struct SearchTop: Equatable, Sendable {
    public let kind: SearchKind
    public let hit: SearchHit
}

/// Search groups arranged as the design's `viewSearch` draws them: songs
/// whose title matches the query first, the other kinds in page order, and
/// one top result.
public struct SearchResults: Equatable, Sendable {
    /// Songs, artists, albums, playlists, podcasts, episodes; empty groups dropped.
    public let groups: [SearchGroup]
    public let top: SearchTop?

    private static let order: [SearchKind] = [.track, .artist, .album, .playlist, .show, .episode]

    public init(groups: [SearchGroup], query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = { (hit: SearchHit) in
            hit.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let arranged = Self.order.compactMap { kind -> SearchGroup? in
            guard var group = groups.first(where: { $0.kind == kind && !$0.hits.isEmpty }) else { return nil }
            if kind == .track {
                // Stable: title matches keep their order, then the rest keep theirs.
                group.hits = group.hits.filter(matches) + group.hits.filter { !matches($0) }
            }
            return group
        }
        self.groups = arranged

        func hits(_ kind: SearchKind) -> [SearchHit] {
            arranged.first { $0.kind == kind }?.hits ?? []
        }
        let artists = hits(.artist), albums = hits(.album), playlists = hits(.playlist)
        let artist = artists.first(where: matches)
        let album = albums.first(where: matches)
        let song = hits(.track).first(where: matches)
        // The design's rule: a matching artist, then a matching album, then a
        // matching song; with no match, the first artist, album or playlist.
        if let hit = artist ?? (album == nil && song == nil && playlists.isEmpty ? artists.first : nil) {
            top = SearchTop(kind: .artist, hit: hit)
        } else if let hit = album ?? (song == nil && playlists.isEmpty ? albums.first : nil) {
            top = SearchTop(kind: .album, hit: hit)
        } else if let song {
            top = SearchTop(kind: .track, hit: song)
        } else if let hit = playlists.first {
            top = SearchTop(kind: .playlist, hit: hit)
        } else {
            top = arranged.first.map { SearchTop(kind: $0.kind, hit: $0.hits[0]) }
        }
    }

    public var isEmpty: Bool {
        groups.isEmpty
    }

    public func hits(_ kind: SearchKind) -> [SearchHit] {
        groups.first { $0.kind == kind }?.hits ?? []
    }

    /// Every match on the server, not only the loaded ones.
    public func count(_ kind: SearchKind) -> Int {
        groups.first { $0.kind == kind }.map { Int($0.total) } ?? 0
    }

    /// The filter actually shown: one whose kind has no results falls back to All.
    public func shown(_ filter: SearchFilter) -> SearchFilter {
        guard let kind = filter.kind, count(kind) > 0 else { return .all }
        return filter
    }
}
