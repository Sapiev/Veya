import SpotCoreKit
import SwiftUI

/// Transport, scrubber, volume and what is playing, pinned to the bottom of the main window.
struct NowPlayingBar: View {
    let player: PlayerModel
    let library: LibraryModel
    let history: NavigationHistory
    @Binding var queueVisible: Bool
    /// The full Now Playing view's tab; nil while it is closed.
    @Binding var expanded: NowPlayingView.Tab?
    /// The level to restore when unmuting.
    @State private var unmutedVolume: Double?

    var body: some View {
        GeometryReader { proxy in
            let gap = Theme.s4
            let center = max(320, (proxy.size.width - 2 * gap) * 1.4 / 3.4)
            let side = max(0, (proxy.size.width - 2 * gap - center) / 2)
            HStack(spacing: gap) {
                track
                    .frame(width: side, alignment: .leading)
                VStack(spacing: 2) {
                    transport
                    Scrubber(player: player)
                }
                .frame(width: center)
                .disabled(player.nowPlaying == nil)
                accessories
                    .frame(width: side, alignment: .trailing)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, Theme.s3)
        .padding(.trailing, Theme.s4)
        .frame(height: Theme.playerHeight)
        .glassPanel(cornerRadius: Theme.playerRadius, strong: true)
        .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var track: some View {
        if let nowPlaying = player.nowPlaying {
            HStack(spacing: Theme.s3) {
                Button { expanded = .queue } label: {
                    ExpandableArtwork(artwork: nowPlaying.artwork)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Now Playing")
                .help("Show Now Playing")
                VStack(alignment: .leading, spacing: 0) {
                    Text(nowPlaying.title)
                        .font(.system(size: 14, weight: .semibold))
                    ArtistLinks(artists: nowPlaying.artists) { history.navigate(to: .artist(uri: $0)) }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                if nowPlaying.uri.hasPrefix("spotify:track:") {
                    let saved = library.isSaved(nowPlaying.uri)
                    Button(
                        saved ? "Remove from Liked Songs" : "Save to Liked Songs",
                        systemImage: saved ? "heart.fill" : "heart"
                    ) {
                        library.setSaved(nowPlaying.uri, !saved)
                    }
                    .buttonStyle(TransportButtonStyle(on: saved))
                    .help(saved ? "Remove from Liked Songs" : "Save to Liked Songs")
                }
            }
        } else {
            Text("Not Playing")
                .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: Theme.s3) {
            TransportControls(player: player)
        }
    }

    /// Lyrics, queue, mute, volume and full-window Now Playing (`.p-right`); the output device is in Settings.
    private var accessories: some View {
        HStack(spacing: 2) {
            Button("Lyrics", systemImage: "text.bubble") { expanded = .lyrics }
                .buttonStyle(TransportButtonStyle())
                .disabled(player.nowPlaying == nil)
                .help("Lyrics")
            Toggle(isOn: $queueVisible) {
                Label("Queue", systemImage: "list.bullet")
            }
            .toggleStyle(.button)
            .buttonStyle(TransportButtonStyle(on: queueVisible))
            .help("Queue")
            let muted = player.volume == 0
            Button(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                if muted {
                    player.volume = unmutedVolume ?? 0.5
                } else {
                    unmutedVolume = player.volume
                    player.volume = 0
                }
            }
            .buttonStyle(TransportButtonStyle())
            .help(muted ? "Unmute" : "Mute")
            ThinSlider(
                value: Binding(get: { player.volume }, set: { player.volume = $0 }),
                in: 0 ... 1,
                label: Text("Volume")
            )
            .frame(width: 96)
            Button("Full-Window Now Playing", systemImage: "arrow.up.left.and.arrow.down.right") { expanded = .queue }
                .buttonStyle(TransportButtonStyle())
                .disabled(player.nowPlaying == nil)
                .help("Full-Window Now Playing")
        }
    }
}

/// Shuffle, previous, play/pause, next and repeat; `large` is Now Playing's white-on-artwork set.
struct TransportControls: View {
    let player: PlayerModel
    var large = false

    var body: some View {
        let side: CGFloat = large ? 44 : 36
        Button("Shuffle", systemImage: "shuffle") { player.setShuffle(!player.shuffle) }
            .buttonStyle(TransportButtonStyle(on: player.shuffle, side: side, onArtwork: large))
            .accessibilityValue(player.shuffle ? "On" : "Off")
            .help("Shuffle")
        Button("Previous", systemImage: "backward.end.fill", action: player.previous)
            .buttonStyle(TransportButtonStyle(side: side, onArtwork: large))
            .font(large ? .title2 : nil)
            .help("Previous")
        Button(action: player.togglePlayPause) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: large ? 26 : 17, weight: .semibold))
                .foregroundStyle(large ? Color(white: 0.07) : Color(nsColor: .windowBackgroundColor))
                .frame(width: large ? 64 : 40, height: large ? 64 : 40)
                .background(large ? AnyShapeStyle(.white) : AnyShapeStyle(.primary), in: .circle)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        .help(player.isPlaying ? "Pause" : "Play")
        Button("Next", systemImage: "forward.end.fill", action: player.next)
            .buttonStyle(TransportButtonStyle(side: side, onArtwork: large))
            .font(large ? .title2 : nil)
            .help("Next")
        Button("Repeat", systemImage: player.repeatMode == .track ? "repeat.1" : "repeat", action: player.cycleRepeat)
            .buttonStyle(TransportButtonStyle(on: player.repeatMode != .off, side: side, onArtwork: large))
            .accessibilityValue(repeatDescription)
            .help("Repeat")
    }

    private var repeatDescription: String {
        switch player.repeatMode {
        case .off: String(localized: "Off")
        case .context: String(localized: "All")
        case .track: String(localized: "One")
        }
    }
}

/// A round icon button (`.tp-btn`): secondary at rest, filled on hover, tinted with a dot under the icon when on.
struct TransportButtonStyle: ButtonStyle {
    var on = false
    var side: CGFloat = 36
    var onArtwork = false

    func makeBody(configuration: Configuration) -> some View {
        TransportButton(configuration: configuration, on: on, side: side, onArtwork: onArtwork)
    }
}

private struct TransportButton: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    let side: CGFloat
    let onArtwork: Bool
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let color: Color = if onArtwork {
            .white.opacity(on || hovering ? 1 : 0.78)
        } else if on {
            Color(palette.tintText)
        } else {
            hovering ? .primary : .secondary
        }
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(color)
            .frame(width: side, height: side)
            .background(hovering ? (onArtwork ? .white.opacity(0.12) : .fill) : .clear, in: .circle)
            .overlay(alignment: .bottom) {
                if on {
                    Circle().fill(color).frame(width: 4, height: 4).padding(.bottom, 3)
                }
            }
            .contentShape(.circle)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .onHover { hovering = $0 }
    }
}

/// The main play button's hover grow and press shrink (`.tp-main`).
private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressScale(configuration: configuration)
    }
}

private struct PressScale: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.95 : hovering ? 1.06 : 1)
            .animation(Theme.fast, value: hovering)
            .animation(Theme.fast, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// The bar's artwork with the design's expand overlay on hover.
private struct ExpandableArtwork: View {
    let artwork: [Artwork]
    @State private var hovering = false

    var body: some View {
        ArtworkView(artwork: artwork, side: 52)
            .overlay {
                Color.black.opacity(0.45)
                    .overlay {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .opacity(hovering ? 1 : 0)
            }
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
            .onHover { hovering = $0 }
            .animation(Theme.fast, value: hovering)
    }
}

/// Elapsed and remaining time around a slider that seeks only when released; `large` stacks the times under it.
struct Scrubber: View {
    let player: PlayerModel
    var large = false
    @State private var dragged: Double?

    var body: some View {
        let duration = Double(player.nowPlaying?.durationMs ?? 0)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || dragged != nil)) { context in
            let position = min(dragged ?? Double(player.position(at: context.date)), duration)
            let elapsed = Text(Self.format(position)).accessibilityIdentifier("elapsed")
            let slider = ThinSlider(
                value: Binding(get: { position }, set: { dragged = $0 }),
                in: 0 ... max(duration, 1),
                label: Text("Playback Position"),
                onArtwork: large
            ) { editing in
                if !editing, let dragged {
                    player.seek(to: UInt32(dragged))
                    self.dragged = nil
                }
            }
            if large {
                VStack(spacing: 2) {
                    slider
                    HStack {
                        elapsed
                        Spacer()
                        Text("-" + Self.format(duration - position))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                }
                .monospacedDigit()
            } else {
                HStack(spacing: Theme.s2) {
                    elapsed.frame(width: 40, alignment: .trailing)
                    slider
                    Text(Self.format(duration)).frame(width: 40, alignment: .leading)
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    static func format(_ milliseconds: Double) -> String {
        Duration.milliseconds(max(0, milliseconds)).formatted(.time(pattern: .minuteSecond))
    }
}

/// Comma-separated artist names; each opens the artist unless it has no URI (an episode's show).
struct ArtistLinks: View {
    let artists: [ItemRef]
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if index > 0 { Text(", ") }
                if artist.uri.isEmpty {
                    Text(artist.name)
                } else {
                    Button(artist.name) { open(artist.uri) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

/// The design's slider (`.slider`): a 3 pt capsule filled to the value, which turns tinted
/// and shows its thumb only on hover or drag; accessibility sees a standard slider.
struct ThinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: Text
    var onArtwork = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        label: Text,
        onArtwork: Bool = false,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.range = range
        self.label = label
        self.onArtwork = onArtwork
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        GeometryReader { proxy in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let filled = proxy.size.width * fraction
            let active = isEnabled && (hovering || dragging)
            ZStack(alignment: .leading) {
                // Each capsule takes its own height: a stack frame doesn't bind the taller thumb's siblings.
                Capsule().fill(onArtwork ? Color.white.opacity(0.22) : .fillStrong)
                    .frame(height: 3)
                Capsule()
                    .fill(onArtwork ? Color.white : active ? Color(palette.tintText) : .primary)
                    .frame(width: filled, height: 3)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .frame(width: 10, height: 10)
                    .offset(x: filled - 5)
                    .opacity(active ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        let x = min(max(drag.location.x / max(proxy.size.width, 1), 0), 1)
                        value = range.lowerBound + span * x
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 20)
        .onHover { hovering = $0 }
        .animation(Theme.fast, value: hovering || dragging)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, label: { label }, onEditingChanged: onEditingChanged)
        }
    }
}
