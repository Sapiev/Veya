import SpotCoreKit
import SwiftUI

/// Transport, scrubber, volume and what is playing, pinned to the bottom of the main window.
struct NowPlayingBar: View {
    let player: PlayerModel
    let library: LibraryModel
    let history: NavigationHistory
    @Binding var queueVisible: Bool
    @State private var expanded = false
    @State private var showsDevices = false

    var body: some View {
        HStack(spacing: 16) {
            track
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                transport
                Scrubber(player: player)
            }
            .frame(width: 420)
            .disabled(player.nowPlaying == nil)
            accessories
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .sheet(isPresented: $expanded) {
            NowPlayingView(player: player, history: history)
        }
    }

    @ViewBuilder private var track: some View {
        if let nowPlaying = player.nowPlaying {
            HStack(spacing: 10) {
                Button { expanded = true } label: {
                    ArtworkView(artwork: nowPlaying.artwork, side: 48)
                        .clipShape(.rect(cornerRadius: 4))
                }
                .accessibilityLabel("Show Now Playing")
                .help("Show Now Playing")
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.title)
                        .fontWeight(.medium)
                    ArtistLinks(artists: nowPlaying.artists) { history.navigate(to: .artist(uri: $0)) }
                        .font(.callout)
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
                    .foregroundStyle(saved ? Color.accentColor : .secondary)
                    .help(saved ? "Remove from Liked Songs" : "Save to Liked Songs")
                }
            }
        } else {
            Text("Not Playing")
                .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button("Shuffle", systemImage: "shuffle") { player.setShuffle(!player.shuffle) }
                .foregroundStyle(player.shuffle ? Color.accentColor : .secondary)
                .accessibilityValue(player.shuffle ? "On" : "Off")
                .help("Shuffle")
            Button("Previous", systemImage: "backward.fill", action: player.previous)
                .help("Previous")
            Button(
                player.isPlaying ? "Pause" : "Play",
                systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                action: player.togglePlayPause
            )
            .font(.title)
            .help(player.isPlaying ? "Pause" : "Play")
            Button("Next", systemImage: "forward.fill", action: player.next)
                .help("Next")
            Button("Repeat", systemImage: player.repeatMode == .track ? "repeat.1" : "repeat", action: player.cycleRepeat)
                .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
                .accessibilityValue(repeatDescription)
                .help("Repeat")
        }
    }

    private var repeatDescription: String {
        switch player.repeatMode {
        case .off: String(localized: "Off")
        case .context: String(localized: "All")
        case .track: String(localized: "One")
        }
    }

    private var accessories: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $queueVisible) {
                Label("Queue", systemImage: "list.bullet")
            }
            .toggleStyle(.button)
            .help("Queue")
            Button("Output Device", systemImage: "hifispeaker") { showsDevices.toggle() }
                .help("Output Device")
                .popover(isPresented: $showsDevices, arrowEdge: .top) {
                    DevicePicker(player: player)
                }
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { player.volume }, set: { player.volume = $0 }), in: 0 ... 1) {
                Text("Volume")
            }
            .labelsHidden()
            .frame(width: 100)
        }
    }
}

/// Elapsed and remaining time around a slider that seeks only when released.
private struct Scrubber: View {
    let player: PlayerModel
    @State private var dragged: Double?

    var body: some View {
        let duration = Double(player.nowPlaying?.durationMs ?? 0)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || dragged != nil)) { context in
            let position = min(dragged ?? Double(player.position(at: context.date)), duration)
            HStack(spacing: 8) {
                Text(Self.format(position))
                    .accessibilityIdentifier("elapsed")
                Slider(
                    value: Binding(get: { position }, set: { dragged = $0 }),
                    in: 0 ... max(duration, 1)
                ) {
                    Text("Playback Position")
                } onEditingChanged: { editing in
                    if !editing, let dragged {
                        player.seek(to: UInt32(dragged))
                        self.dragged = nil
                    }
                }
                .labelsHidden()
                Text("-" + Self.format(duration - position))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
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

private struct DevicePicker: View {
    let player: PlayerModel
    @State private var devices = OutputDevices()

    var body: some View {
        Picker("Output Device", selection: Binding(get: { player.outputDeviceUID }, set: { player.outputDeviceUID = $0 })) {
            Text("System Default").tag(String?.none)
            ForEach(devices.list) { device in
                Text(device.name).tag(String?.some(device.uid))
            }
        }
        .pickerStyle(.radioGroup)
        .padding()
    }
}

/// Large artwork and a lyrics tab, shown from the bar's artwork.
private struct NowPlayingView: View {
    let player: PlayerModel
    let history: NavigationHistory
    @State private var tab = Tab.nowPlaying
    @Environment(\.dismiss) private var dismiss

    private enum Tab {
        case nowPlaying, lyrics
    }

    var body: some View {
        VStack(spacing: 20) {
            Picker("View", selection: $tab) {
                Text("Now Playing").tag(Tab.nowPlaying)
                Text("Lyrics").tag(Tab.lyrics)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Group {
                switch tab {
                case .nowPlaying:
                    if let nowPlaying = player.nowPlaying {
                        VStack(spacing: 12) {
                            ArtworkView(artwork: nowPlaying.artwork, side: 320)
                                .clipShape(.rect(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                            Text(nowPlaying.title)
                                .font(.title2)
                            ArtistLinks(artists: nowPlaying.artists) { uri in
                                dismiss()
                                history.navigate(to: .artist(uri: uri))
                            }
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView("Not Playing", systemImage: "music.note")
                    }
                case .lyrics:
                    ContentUnavailableView(
                        "No Lyrics",
                        systemImage: "quote.bubble",
                        description: Text("Lyrics aren't available yet.")
                    )
                }
            }
            .frame(width: 400, height: 420)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
    }
}
