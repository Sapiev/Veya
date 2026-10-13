import SpotCoreKit
import SwiftUI

/// Lyrics of the playing track: synced lines follow playback and seek when clicked; unsynced ones are static text.
struct LyricsPane: View {
    let player: PlayerModel
    let metadata: any MetadataServiceProtocol
    @State private var loaded: (uri: String, phase: Phase)?

    private enum Phase {
        case lyrics(Lyrics), none, failed
    }

    var body: some View {
        let uri = player.nowPlaying?.uri
        Group {
            if let uri, uri.hasPrefix("spotify:track:") {
                if let loaded, loaded.uri == uri {
                    content(loaded.phase)
                } else {
                    ProgressView()
                }
            } else {
                content(.none)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: uri) { await load(uri) }
    }

    private func load(_ uri: String?) async {
        guard let uri, uri.hasPrefix("spotify:track:") else { return }
        let phase: Phase
        do {
            phase = try await metadata.lyrics(trackUri: uri).map(Phase.lyrics) ?? .none
        } catch {
            // Type name only: messages may carry server text.
            logMessage(level: .warn, category: "lyrics", message: "Lyrics failed: \(type(of: error))")
            phase = .failed
        }
        guard !Task.isCancelled else { return }
        loaded = (uri, phase)
    }

    @ViewBuilder private func content(_ phase: Phase) -> some View {
        switch phase {
        case let .lyrics(lyrics):
            TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { context in
                LyricsLines(lyrics: lyrics, active: lyrics.activeLine(at: player.position(at: context.date))) {
                    player.seek(to: $0)
                }
            }
            .padding(Theme.s2)
            .glassPanel(cornerRadius: Theme.panelRadius)
        case .none:
            ContentUnavailableView("No Lyrics", systemImage: "quote.bubble", description: Text("This track has no lyrics."))
        case .failed:
            ContentUnavailableView(
                "Lyrics Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Lyrics couldn't be loaded.")
            )
        }
    }
}

private struct LyricsLines: View {
    let lyrics: Lyrics
    let active: Int?
    let seek: (UInt32) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    ForEach(lyrics.lines.indices, id: \.self) { index in
                        line(index).id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.s4)
            }
            .arrowKeyList(lyrics.synced ? Array(lyrics.lines.indices) : [], focus: $focused) {
                seek(lyrics.lines[$0].startMs)
            }
            .onChange(of: active, initial: true) { _, active in
                guard let active else { return }
                withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(active, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func line(_ index: Int) -> some View {
        let line = lyrics.lines[index]
        // Spotify sends instrumental breaks as empty lines.
        let text = Text(line.words.isEmpty ? "♪" : line.words)
            .scaledFont(size: 24, weight: .bold)
            .multilineTextAlignment(.leading)
        if lyrics.synced {
            Button { seek(line.startMs) } label: { text }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(index == active ? 1 : contrast.opacity(0.45)))
                .focusRing($focused, equals: index)
                .accessibilityAddTraits(index == active ? .isSelected : [])
                .accessibilityHint("Plays from this line")
        } else {
            text
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
        }
    }
}
