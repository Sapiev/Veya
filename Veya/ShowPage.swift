import SpotCoreKit
import SwiftUI

/// Show header and its episodes with release date, length and listening
/// progress. The selected episode shows its notes; playing one resumes it.
struct ShowPage: View {
    let uri: String
    let podcast: PodcastModel
    let player: PlayerModel?
    @State private var selection: String?

    /// Another show's page stays published until this one's load starts.
    private var stale: Bool {
        podcast.show.map { $0.uri != uri } ?? false
    }

    private var episodes: [EpisodeMetadata] {
        guard !stale else { return [] }
        return podcast.episodes.compactMap { item -> EpisodeMetadata? in
            if case let .episode(episode) = item {
                episode
            } else {
                nil
            }
        }
    }

    var body: some View {
        let show = stale ? nil : podcast.show
        let rows = episodes
        VStack(alignment: .leading, spacing: 0) {
            if let show {
                header(show)
            }
            LoadStateView(
                state: stale ? .loading : podcast.state,
                isEmpty: rows.isEmpty,
                empty: EmptyState(title: "No Episodes", systemImage: "mic", message: "Episodes of this podcast appear here."),
                failureTitle: "Couldn't Load Podcast",
                retry: { podcast.load(uri) }
            ) {
                List(rows, id: \.uri, selection: $selection) { episode in
                    EpisodeRow(
                        episode: episode,
                        progress: podcast.progress[episode.uri],
                        isSelected: selection == episode.uri,
                        isCurrent: player?.nowPlaying?.uri == episode.uri,
                        canPlay: player != nil && episode.playability == .playable
                    ) { play(episode.uri) }
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { uris in
                    if let episode = uris.first {
                        Button("Play") { play(episode) }
                            .disabled(player == nil || !isPlayable(episode))
                    }
                } primaryAction: { uris in
                    if let episode = uris.first {
                        play(episode)
                    }
                }
            }
        }
        .navigationTitle(show?.name ?? String(localized: "Podcast"))
        .task(id: uri) {
            selection = nil
            podcast.load(uri)
        }
    }

    private func header(_ show: ShowMetadata) -> some View {
        PageHero(kind: "Podcast", title: show.name, artwork: show.artwork, description: show.description) {
            Text(show.publisher)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
    }

    private func play(_ episode: String) {
        guard isPlayable(episode) else { return }
        player?.play(episode, startingAt: podcast.startPosition(for: episode))
    }

    private func isPlayable(_ episode: String) -> Bool {
        episodes.first { $0.uri == episode }?.playability == .playable
    }
}

private struct EpisodeRow: View {
    let episode: EpisodeMetadata
    let progress: EpisodeProgress?
    let isSelected: Bool
    let isCurrent: Bool
    let canPlay: Bool
    let play: () -> Void
    @Environment(\.palette) private var palette

    private var played: Bool {
        progress?.fullyPlayed == true
    }

    /// Where playback picks up; zero once played or never started.
    private var resumeAt: UInt32 {
        guard let progress, !progress.fullyPlayed else { return 0 }
        return min(progress.resumePositionMs, episode.durationMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let published = episode.publishedAt {
                Text(Date(timeIntervalSince1970: TimeInterval(published)).formatted(date: .abbreviated, time: .omitted))
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            Text(episode.title)
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color(palette.tintText)) : played ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(isSelected ? nil : 2)
            status
            if isSelected {
                if !episode.description.isEmpty {
                    Text(episode.description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(resumeAt > 0 ? "Resume" : "Play", systemImage: "play.fill", action: play)
                    .disabled(!canPlay)
                    // The now-playing bar has its own Play button.
                    .accessibilityIdentifier("episodePlay")
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .opacity(episode.playability == .playable ? 1 : 0.45)
        .unavailableValue(episode.playability != .playable)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if played {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityHidden(true)
                Text("Played")
            } else if resumeAt > 0 {
                ProgressView(value: Double(resumeAt), total: Double(max(episode.durationMs, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 48)
                    .accessibilityHidden(true)
                Text("\(Self.length(episode.durationMs - resumeAt)) left")
            } else {
                Text(Self.length(episode.durationMs))
            }
        }
        .scaledFont(size: 12)
        .foregroundStyle(.secondary)
    }

    /// "1 hr, 5 min" or "35 min".
    private static func length(_ milliseconds: UInt32) -> String {
        Duration.milliseconds(Int(milliseconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
