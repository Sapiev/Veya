import SpotCoreKit
import SwiftUI

/// The full Now Playing view: large artwork and transport over a blurred wash of the artwork, beside the queue or lyrics.
struct NowPlayingView: View {
    let player: PlayerModel
    let library: LibraryModel
    let metadata: any MetadataServiceProtocol
    let history: NavigationHistory
    @State var tab: Tab
    let close: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab {
        case queue, lyrics
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 1100
            Group {
                if wide {
                    HStack(spacing: Theme.s12) {
                        playing(side: min(440, (proxy.size.width - 3 * Theme.s12) / 2, proxy.size.height - 380))
                            .frame(maxWidth: .infinity)
                        panes
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.top, 72)
                    .padding([.horizontal, .bottom], Theme.s12)
                } else {
                    ScrollView {
                        VStack(spacing: Theme.s6) {
                            playing(side: min(440, proxy.size.width - 2 * Theme.s12))
                            panes
                                .frame(height: 420)
                        }
                        .padding(.top, 72)
                        .padding([.horizontal, .bottom], Theme.s12)
                    }
                }
            }
            .background { backdrop(proxy.size) }
        }
        .overlay(alignment: .topTrailing) {
            Button("Close Now Playing", systemImage: "chevron.down", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(TransportButtonStyle(side: 32, onArtwork: true))
                .background(.white.opacity(0.14), in: .circle)
                .keyboardShortcut(.cancelAction)
                .help("Close Now Playing")
                .padding(.top, Theme.s3)
                .padding(.trailing, Theme.s4)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// Blurred at thumbnail size, then scaled to cover: the blur scales with it, so no hard edges show.
    private func backdrop(_ size: CGSize) -> some View {
        Color(palette.ambient)
            .overlay {
                ArtworkView(artwork: player.nowPlaying?.artwork ?? [], side: 48)
                    .saturation(1.6)
                    .blur(radius: 6)
                    .scaleEffect(max(size.width, size.height) / 48 * 1.3)
                    .brightness(-0.25)
            }
            .overlay(Color(palette.ambient).opacity(0.45))
            .frame(width: size.width, height: size.height)
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder private func playing(side: CGFloat) -> some View {
        let side = max(160, side)
        if let nowPlaying = player.nowPlaying {
            VStack(spacing: Theme.s6) {
                ArtworkView(artwork: nowPlaying.artwork, side: side)
                    .clipShape(.rect(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 30)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(
                        reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4),
                        value: player.isPlaying
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text(nowPlaying.title)
                        .font(.system(size: 22, weight: .bold))
                    ArtistLinks(artists: nowPlaying.artists) { uri in
                        close()
                        history.navigate(to: .artist(uri: uri))
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.74))
                }
                .lineLimit(1)
                .frame(width: side, alignment: .leading)
                Scrubber(player: player, large: true)
                    .frame(width: side)
                HStack(spacing: Theme.s5) {
                    TransportControls(player: player, large: true)
                }
            }
        } else {
            ContentUnavailableView("Not Playing", systemImage: "music.note")
        }
    }

    private var panes: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Picker("View", selection: $tab) {
                Text("Queue").tag(Tab.queue)
                Text("Lyrics").tag(Tab.lyrics)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch tab {
            case .queue:
                queue
                    .padding(Theme.s2)
                    .glassPanel(cornerRadius: Theme.panelRadius)
            case .lyrics:
                LyricsPane(player: player, metadata: metadata)
            }
        }
    }

    private var queue: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let current = player.nowPlaying {
                    label("Now Playing")
                    QueueRow(uri: current.uri, library: library, current: true, onArtwork: true)
                        .task(id: current.uri) { library.resolve([current.uri]) }
                }
                if !player.upNext.isEmpty {
                    label("Next in Queue")
                    rows(player.upNext, ids: { $0 })
                }
                if !player.nextFromContext.isEmpty {
                    label("Next Up")
                    rows(player.nextFromContext, ids: { -1 - $0 })
                }
            }
        }
        .accessibilityIdentifier("nowPlayingQueue")
    }

    private func label(_ title: LocalizedStringKey) -> some View {
        QueueLabel(title: Text(title))
            .padding(.horizontal, Theme.s2)
            .padding(.top, Theme.s3)
            .padding(.bottom, Theme.s1)
    }

    /// Both sections share one lazy stack, so `ids` keeps their row ids disjoint; equal ids drop rows.
    private func rows(_ uris: [String], ids: (Int) -> Int) -> some View {
        ForEach(uris.indices.map { (id: ids($0), offset: $0) }, id: \.id) { row in
            let offset = row.offset
            let uri = uris[offset]
            QueueRow(uri: uri, library: library, onArtwork: true)
                .task(id: uri) { QueuePanel.resolve(uris, from: offset, in: library) }
        }
    }
}
