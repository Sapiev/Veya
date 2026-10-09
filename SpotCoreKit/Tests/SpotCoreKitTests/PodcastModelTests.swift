import Foundation
import os
@testable import SpotCoreKit
import Testing

/// Answers from `items`, unknown URIs as not found; a request for `held` waits for `release`.
final class StubMetadata: MetadataServiceProtocol {
    private struct Box {
        var held: String?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let items: [String: MetadataItem]
    private let box = OSAllocatedUnfairLock(initialState: Box())

    init(_ items: [MetadataItem]) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.uri, $0) })
    }

    func hold(_ uri: String) {
        box.withLock { $0.held = uri }
    }

    var waiting: Int {
        box.withLock { $0.waiters.count }
    }

    func release() {
        box.withLock { box in
            defer { box.waiters = [] }
            return box.waiters
        }.forEach { $0.resume() }
    }

    func items(uris: [String]) async throws -> [MetadataItem] {
        if box.withLock({ uris.contains($0.held ?? "") }) {
            await withCheckedContinuation { continuation in
                box.withLock { $0.waiters.append(continuation) }
            }
        }
        return uris.map { items[$0] ?? .unavailable(uri: $0, error: .notFound) }
    }
}

final class StubProgress: EpisodeProgressProvider {
    private let result: Result<[EpisodeProgress], PodcastError>
    private let requests = OSAllocatedUnfairLock<[[String]]>(initialState: [])

    init(_ result: Result<[EpisodeProgress], PodcastError>) {
        self.result = result
    }

    var requested: [[String]] {
        requests.withLock { $0 }
    }

    func progress(uris: [String]) async throws -> [EpisodeProgress] {
        requests.withLock { $0.append(uris) }
        return try result.get()
    }
}

private extension MetadataItem {
    var uri: String {
        switch self {
        case let .track(track): track.uri
        case let .album(album): album.uri
        case let .artist(artist): artist.uri
        case let .episode(episode): episode.uri
        case let .show(show): show.uri
        case let .unavailable(uri, _): uri
        }
    }
}

private let showURI = "spotify:show:4rOoJ6Egrf8K2IrywzwOMk"
private let otherShowURI = "spotify:show:5rOoJ6Egrf8K2IrywzwOMk"
private let first = "spotify:episode:512ojhOuo1ktJprKbVcKyQ"
private let second = "spotify:episode:612ojhOuo1ktJprKbVcKyQ"

private func show(_ uri: String, episodes: [String]) -> MetadataItem {
    .show(show: ShowMetadata(
        uri: uri, name: uri, publisher: "Studio", description: "About", artwork: [], episodes: episodes
    ))
}

private func episode(_ uri: String) -> MetadataItem {
    .episode(episode: EpisodeMetadata(
        uri: uri, title: uri, showName: "Show", description: "Notes", durationMs: 60000,
        explicit: false, playability: .playable, artwork: [], publishedAt: nil
    ))
}

private func catalog() -> StubMetadata {
    StubMetadata([show(showURI, episodes: [second, first]), show(otherShowURI, episodes: [first])]
        + [episode(first), episode(second)])
}

private let inProgress = EpisodeProgress(uri: first, resumePositionMs: 90000, fullyPlayed: false)
private let played = EpisodeProgress(uri: second, resumePositionMs: 3000, fullyPlayed: true)

@MainActor
struct PodcastModelTests {
    @Test func loadsShowThenEpisodesInServerOrderThenProgress() async {
        let progress = StubProgress(.success([inProgress, played]))
        let model = PodcastModel(metadata: catalog(), progress: progress, log: { _, _ in })

        await model.load(showURI).value

        #expect(model.state == .loaded)
        #expect(model.show?.uri == showURI)
        #expect(model.episodes == [episode(second), episode(first)])
        #expect(progress.requested == [[second, first]])
        #expect(model.progress[first]?.resumePositionMs == 90000)
        #expect(model.progress[second]?.fullyPlayed == true)
    }

    @Test func progressFailureKeepsTheEpisodes() async {
        var logged: [String] = []
        let progress = StubProgress(.failure(.MissingScope))
        let model = PodcastModel(metadata: catalog(), progress: progress) { logged.append($1) }

        await model.load(showURI).value

        #expect(model.state == .loaded)
        #expect(model.episodes.count == 2)
        #expect(model.progress.isEmpty)
        #expect(logged == ["Couldn't read episode progress: MissingScope"])
    }

    @Test func nonShowFails() async {
        let model = PodcastModel(metadata: catalog(), progress: StubProgress(.success([])), log: { _, _ in })

        await model.load("spotify:show:0000000000000000000000").value

        #expect(model.state == .failed)
        #expect(model.show == nil)
        #expect(model.episodes.isEmpty)
    }

    @Test func startPositionResumesUnlessFullyPlayedOrUnknown() async {
        let progress = StubProgress(.success([inProgress, played]))
        let model = PodcastModel(metadata: catalog(), progress: progress, log: { _, _ in })
        await model.load(showURI).value

        #expect(model.startPosition(for: first) == 90000)
        #expect(model.startPosition(for: second) == 0)
        #expect(model.startPosition(for: "spotify:episode:unknown") == 0)
    }

    @Test func aSlowEarlierShowNeverReplacesTheLatest() async {
        let metadata = catalog()
        metadata.hold(showURI)
        let model = PodcastModel(metadata: metadata, progress: StubProgress(.success([])), log: { _, _ in })

        let slow = model.load(showURI)
        while metadata.waiting == 0 {
            await Task.yield()
        }
        await model.load(otherShowURI).value
        metadata.release()
        await slow.value

        #expect(model.show?.uri == otherShowURI)
        #expect(model.episodes == [episode(first)])
    }
}
