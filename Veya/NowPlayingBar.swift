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
    /// Five 36 pt buttons, the 96 pt volume slider and 2 pt between each.
    private static let fullAccessoriesWidth: CGFloat = 5 * 36 + 96 + 5 * 2

    var body: some View {
        GeometryReader { proxy in
            let gap = Theme.s4
            // The center gives way first, so the sides keep every accessory; below its minimum the accessories drop the volume.
            let room = proxy.size.width - 2 * gap
            let center = max(Theme.minPlayerCenter, min(room * 1.4 / 3.4, room - 2 * Self.fullAccessoriesWidth))
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
                        .crossDissolve(on: nowPlaying.uri)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Now Playing")
                .help("Show Now Playing")
                VStack(alignment: .leading, spacing: 0) {
                    Text(nowPlaying.title)
                        .scaledFont(size: 14, weight: .semibold)
                    ArtistLinks(artists: nowPlaying.artists) { history.navigate(to: .artist(uri: $0)) }
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                    playingOn
                }
                .lineLimit(1)
                LikeButton(uri: nowPlaying.uri, library: library)
            }
            .dissolvesContent(on: nowPlaying.uri)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Not Playing")
                    .foregroundStyle(.secondary)
                playingOn
            }
        }
    }

    /// PBI-503: the controls command this device while another one plays.
    @ViewBuilder private var playingOn: some View {
        if let device = player.playingOn {
            Label("Playing on \(device)", systemImage: "hifispeaker.2")
                .labelStyle(.titleAndIcon)
                .scaledFont(size: 11, weight: .medium)
                .accentForeground()
                .lineLimit(1)
        }
    }

    private var transport: some View {
        HStack(spacing: Theme.s3) {
            TransportControls(player: player)
        }
    }

    /// Lyrics, queue, devices, mute, volume and full-window Now Playing (`.p-right`); the output device is in Settings.
    /// A narrow bar raises the volume slider above the mute button on hover, then drops full-window, which the artwork also opens.
    private var accessories: some View {
        ViewThatFits(in: .horizontal) {
            accessoryButtons(inlineSlider: true, fullWindow: true)
            accessoryButtons(inlineSlider: false, fullWindow: true)
            accessoryButtons(inlineSlider: false, fullWindow: false)
        }
    }

    private func accessoryButtons(inlineSlider: Bool, fullWindow: Bool) -> some View {
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
            DevicesButton(player: player)
            if inlineSlider {
                muteButton
                volumeSlider
                    .frame(width: 96)
            } else {
                PopUpVolume { muteButton } slider: { volumeSlider }
                    // VoiceOver and Full Keyboard Access never hover, so the button adjusts the volume itself.
                    .accessibilityValue(volumeDescription)
                    .accessibilityAdjustableAction { direction in
                        let step = direction == .increment ? PlaybackCommands.volumeStep : -PlaybackCommands.volumeStep
                        player.volume = min(max(player.volume + step, 0), 1)
                    }
            }
            if fullWindow {
                Button("Full-Window Now Playing", systemImage: "arrow.up.left.and.arrow.down.right") { expanded = .queue }
                    .buttonStyle(TransportButtonStyle())
                    .disabled(player.nowPlaying == nil)
                    .help("Full-Window Now Playing")
            }
        }
        .fixedSize()
    }

    private var muteButton: some View {
        let muted = player.volume == 0
        return Button(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
            if muted {
                player.volume = unmutedVolume ?? 0.5
            } else {
                unmutedVolume = player.volume
                player.volume = 0
            }
        }
        .buttonStyle(TransportButtonStyle())
        .help(muted ? "Unmute" : "Mute")
    }

    private var volumeDescription: String {
        player.volume.formatted(.percent.precision(.fractionLength(0)))
    }

    private var volumeSlider: some View {
        ThinSlider(
            value: Binding(get: { player.volume }, set: { player.volume = $0 }),
            in: 0 ... 1,
            label: Text("Volume"),
            valueDescription: volumeDescription
        )
    }
}

/// The mute button with the volume slider standing upright above it while the pointer is over either.
private struct PopUpVolume<Button: View, Slider: View>: View {
    @ViewBuilder let button: Button
    @ViewBuilder let slider: Slider
    @State private var overButton = false
    @State private var overSlider = false
    @State private var shown = false

    var body: some View {
        button
            .onHover { overButton = $0 }
            // A popover, not an overlay: SwiftUI never hovers what is drawn outside the bar's bounds.
            .popover(isPresented: $shown, arrowEdge: .top) {
                slider
                    .frame(width: 96)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 20, height: 96)
                    .padding(Theme.s3)
                    .onHover { overSlider = $0 }
            }
            .task(id: overButton || overSlider) {
                if overButton || overSlider {
                    shown = true
                } else if (try? await Task.sleep(for: .milliseconds(300))) != nil {
                    // The grace period lets the pointer cross from the button to the popover.
                    shown = false
                }
            }
    }
}

struct LikeButton: View {
    let uri: String
    let library: LibraryModel

    var body: some View {
        if uri.hasPrefix("spotify:track:") {
            let saved = library.isSaved(uri)
            Button(
                saved ? "Remove from Liked Songs" : "Save to Liked Songs",
                systemImage: saved ? "heart.fill" : "heart"
            ) {
                library.setSaved(uri, !saved)
            }
            .buttonStyle(TransportButtonStyle(on: saved))
            .help(saved ? "Remove from Liked Songs" : "Save to Liked Songs")
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
            .accessibilityHint("Plays the queue in random order")
            .help("Shuffle")
        Button("Previous", systemImage: "backward.end.fill", action: player.previous)
            .buttonStyle(TransportButtonStyle(side: side, onArtwork: large))
            .scaledFont(size: large ? 17 : 13)
            .help("Previous")
        Button(action: player.togglePlayPause) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .scaledFont(size: large ? 26 : 17, weight: .semibold)
                .foregroundStyle(large ? Color(white: 0.07) : Color(nsColor: .windowBackgroundColor))
                .frame(width: large ? 64 : 40, height: large ? 64 : 40)
                .background(large ? AnyShapeStyle(.white) : AnyShapeStyle(.primary), in: .circle)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        .help(player.isPlaying ? "Pause" : "Play")
        Button("Next", systemImage: "forward.end.fill", action: player.next)
            .buttonStyle(TransportButtonStyle(side: side, onArtwork: large))
            .scaledFont(size: large ? 17 : 13)
            .help("Next")
        Button("Repeat", systemImage: player.repeatMode == .track ? "repeat.1" : "repeat", action: player.cycleRepeat)
            .buttonStyle(TransportButtonStyle(on: player.repeatMode != .off, side: side, onArtwork: large))
            .accessibilityValue(repeatDescription)
            .accessibilityHint("Switches between off, repeat all and repeat one")
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
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        let color: Color = if onArtwork {
            .white.opacity(on || hovering ? 1 : contrast.opacity(0.78))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        ArtworkView(artwork: artwork, side: 52)
            .overlay {
                Color.black.opacity(0.45)
                    .overlay {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .opacity(hovering ? 1 : 0)
            }
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : Theme.fast, value: hovering)
    }
}

/// Elapsed and remaining time around a slider that seeks only when released; `large` stacks the times under it.
struct Scrubber: View {
    let player: PlayerModel
    var large = false
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var dragged: Double?
    @State private var now = Date.now

    var body: some View {
        let duration = Double(player.nowPlaying?.durationMs ?? 0)
        Group {
            let position = min(dragged ?? Double(player.position(at: now)), duration)
            let elapsed = Text(Self.format(position)).accessibilityIdentifier("elapsed")
            let slider = ThinSlider(
                value: Binding(get: { position }, set: { dragged = $0 }),
                in: 0 ... max(duration, 1),
                label: Text("Playback Position"),
                valueDescription: String(localized: "\(Self.spoken(position)) of \(Self.spoken(duration))"),
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
                    .scaledFont(size: 12)
                    .foregroundStyle(.white.opacity(contrast.opacity(0.7)))
                }
                .monospacedDigit()
            } else {
                HStack(spacing: Theme.s2) {
                    elapsed.frame(width: 40, alignment: .trailing)
                    slider
                    Text(Self.format(duration)).frame(width: 40, alignment: .leading)
                }
                .scaledFont(size: 11)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
        // A sleeping task, not a TimelineView: a running TimelineView keeps the display link
        // firing every frame whatever its schedule, ~9 % CPU during playback (PBI-803).
        // Each tick relays out the window, so it wakes once a second, when the elapsed time turns over.
        .task(id: player.isPlaying && dragged == nil) {
            guard player.isPlaying, dragged == nil else { return }
            repeat {
                now = .now
            } while await (try? Task.sleep(for: .milliseconds(1000 - player.position(at: now) % 1000))) != nil
        }
    }

    static func format(_ milliseconds: Double) -> String {
        Duration.milliseconds(max(0, milliseconds)).formatted(.time(pattern: .minuteSecond))
    }

    /// VoiceOver's form of a time, e.g. "3 minutes, 12 seconds".
    static func spoken(_ milliseconds: Double) -> String {
        Duration.milliseconds(max(0, milliseconds)).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
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
    /// What VoiceOver reads as the value, e.g. "50%".
    let valueDescription: String
    var onArtwork = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var hovering = false
    @State private var dragging = false
    @State private var accessibilityEditing = false
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        label: Text,
        valueDescription: String,
        onArtwork: Bool = false,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.range = range
        self.label = label
        self.valueDescription = valueDescription
        self.onArtwork = onArtwork
        self.onEditingChanged = onEditingChanged
    }

    private var accessibleValue: Binding<Double> {
        Binding(get: { value }, set: { new in
            AssistiveSlider.set(
                new, editing: accessibilityEditing,
                apply: { value = $0 }, onEditingChanged: onEditingChanged
            )
        })
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
        .animation(reduceMotion ? nil : Theme.fast, value: hovering || dragging)
        .accessibilityRepresentation {
            Slider(value: accessibleValue, in: range, label: { label }) { editing in
                accessibilityEditing = editing
                onEditingChanged(editing)
            }
            .accessibilityValue(valueDescription)
        }
    }
}
