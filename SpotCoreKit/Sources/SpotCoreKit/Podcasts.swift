import Foundation
import Observation

/// Resume points and played state for episodes.
public protocol EpisodeProgressProvider: Sendable {
    func progress(uris: [String]) async throws -> [EpisodeProgress]
}

/// Reads progress from the Web API with a token from `accessToken`, which
/// needs the `user-read-playback-position` scope.
public struct WebAPIEpisodeProgress: EpisodeProgressProvider {
    private let accessToken: @Sendable () async throws -> String

    public init(accessToken: @escaping @Sendable () async throws -> String) {
        self.accessToken = accessToken
    }

    public func progress(uris: [String]) async throws -> [EpisodeProgress] {
        try await episodeProgress(accessToken: accessToken(), uris: uris)
    }
}

public typealias PodcastLog = @MainActor (LogLevel, String) -> Void

/// One show page: the show, its episodes in server order and their progress.
/// Followed shows are `LibraryModel`'s `.shows` kind.
///
/// Episodes show even when progress cannot be read; progress is then empty.
/// A page is published only while its show is still the latest one loaded.
@MainActor
@Observable
public final class PodcastModel {
    public private(set) var show: ShowMetadata?
    public private(set) var episodes: [MetadataItem] = []
    /// Keyed by episode URI; absent until read, or when reading failed.
    public private(set) var progress: [String: EpisodeProgress] = [:]
    public private(set) var state: LibraryLoadState?

    @ObservationIgnored private let metadata: any MetadataServiceProtocol
    @ObservationIgnored private let progressProvider: any EpisodeProgressProvider
    @ObservationIgnored private let log: PodcastLog
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Bumped by every `load`; a page from an older one is dropped.
    @ObservationIgnored private var generation = 0

    public init(
        metadata: any MetadataServiceProtocol,
        progress: any EpisodeProgressProvider,
        log: @escaping PodcastLog = { logMessage(level: $0, category: "podcasts", message: $1) }
    ) {
        self.metadata = metadata
        progressProvider = progress
        self.log = log
    }

    /// Loads the show at `uri`, replacing the current page.
    @discardableResult
    public func load(_ uri: String) -> Task<Void, Never> {
        generation += 1
        let mine = generation
        running?.cancel()
        show = nil
        episodes = []
        progress = [:]
        state = .loading
        let task = Task { [metadata, progressProvider] in
            do {
                guard case let .show(show) = try await metadata.items(uris: [uri]).first else {
                    throw PodcastLoadError.notAShow
                }
                // Progress is fetched alongside the episodes' metadata, not after it.
                let progressLookup = Task { try await progressProvider.progress(uris: show.episodes) }
                defer { progressLookup.cancel() }
                let episodes = try await metadata.items(uris: show.episodes)
                guard mine == generation else { return }
                self.show = show
                self.episodes = episodes
                state = .loaded
                do {
                    let found = try await progressLookup.value
                    guard mine == generation else { return }
                    progress = Dictionary(found.map { ($0.uri, $0) }) { first, _ in first }
                } catch {
                    log(.warn, "Couldn't read episode progress: \(Self.summary(error))")
                }
            } catch {
                guard mine == generation else { return }
                log(.warn, "Couldn't load the show: \(Self.summary(error))")
                state = .failed
            }
        }
        running = task
        return task
    }

    /// Where `SpotPlayer.load` should start `episodeURI`: its resume point,
    /// or the beginning once fully played or when progress is unknown.
    public func startPosition(for episodeURI: String) -> UInt32 {
        guard let point = progress[episodeURI], !point.fullyPlayed else { return 0 }
        return point.resumePositionMs
    }

    private enum PodcastLoadError: Error {
        case notAShow
    }

    /// Error case names only: messages may carry server text.
    private static func summary(_ error: any Error) -> String {
        switch error {
        case PodcastError.InvalidUri: "InvalidUri"
        case PodcastError.MissingScope: "MissingScope"
        case PodcastError.Network: "Network"
        case PodcastError.Request: "Request"
        case PodcastError.Malformed: "Malformed"
        case PodcastLoadError.notAShow: "NotAShow"
        default: String(describing: type(of: error))
        }
    }
}
