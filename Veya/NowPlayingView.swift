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
    @AppStorage(Self.showsPanesKey) private var showsPanes = true
    @AppStorage(Self.panesBackgroundKey) private var panesBackground = true
    @State private var controlsShown = true
    @State private var controlsHovered = false
    @State private var controlsIdle = IdleTimer()
    @State private var keyMonitor: Any?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// Read by the General settings tab; on by default.
    static let showsPanesKey = "nowPlayingShowsPanes"
    static let panesBackgroundKey = "nowPlaying.panesBackground"

    enum Tab {
        case queue, lyrics
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 1100
            Group {
                if !showsPanes {
                    playing(side: min(560, proxy.size.width - 2 * Theme.s12, proxy.size.height - 380))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 72)
                        .padding([.horizontal, .bottom], Theme.s12)
                } else if wide {
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
        .onContinuousHover { phase in
            if case .active = phase {
                revealControls()
            }
        }
        .onAppear(perform: revealControls)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Theme.s2) {
                let toggle: LocalizedStringKey = showsPanes ? "Hide Queue and Lyrics" : "Show Queue and Lyrics"
                Button(toggle, systemImage: "sidebar.right") { showsPanes.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(TransportButtonStyle(side: 32, onArtwork: true))
                    .background(.white.opacity(showsPanes ? 0.14 : 0.06), in: .circle)
                    .help(toggle)
                Button("Close Now Playing", systemImage: "chevron.down", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(TransportButtonStyle(side: 32, onArtwork: true))
                    .background(.white.opacity(0.14), in: .circle)
                    .keyboardShortcut(.cancelAction)
                    .help("Close Now Playing")
            }
            .onHover { controlsHovered = $0 }
            .fades(visible: controlsVisible, reduceMotion: reduceMotion)
            .padding(.top, Theme.s3)
            .padding(.trailing, Theme.s4)
        }
        // Keyboard users move focus onto the controls, so they must not stay invisible.
        // A monitor, since Tab moves focus through AppKit and never reaches `onKeyPress`.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                revealControls()
                return event
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
        .background(WindowButtonsFade(visible: controlsVisible, animated: !reduceMotion))
        // Asking for lyrics brings the panes back even when they were hidden last time.
        .onAppear {
            if tab == .lyrics {
                showsPanes = true
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// Blurred at thumbnail size, then scaled to cover: the blur scales with it, so no hard edges show.
    private func backdrop(_ size: CGSize) -> some View {
        Color(palette.ambient)
            .overlay {
                ArtworkView(artwork: player.nowPlaying?.artwork ?? [], side: 48)
                    .crossDissolve(on: player.nowPlaying?.uri)
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
                    .crossDissolve(on: nowPlaying.uri)
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 30)
                    .scaleEffect(player.isPlaying || reduceMotion ? 1 : 0.92)
                    .animation(
                        reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4),
                        value: player.isPlaying
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text(trackTitle: nowPlaying.title)
                        .scaledFont(size: 22, weight: .bold)
                    ArtistLinks(artists: nowPlaying.artists) { uri in
                        close()
                        history.navigate(to: .artist(uri: uri))
                    }
                    .scaledFont(size: 15)
                    .foregroundStyle(.white.opacity(contrast.opacity(0.74)))
                }
                .lineLimit(1)
                .frame(width: side, alignment: .leading)
                .dissolvesContent(on: nowPlaying.uri)
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
            .onHover { controlsHovered = $0 }
            .fades(visible: controlsVisible, reduceMotion: reduceMotion)
            switch tab {
            case .queue:
                queue
                    .padding(Theme.s2)
                    .glassPanel(cornerRadius: Theme.panelRadius, shown: panesBackground)
            case .lyrics:
                LyricsPane(player: player, metadata: metadata, background: panesBackground)
            }
        }
    }

    /// VoiceOver users cannot see the pointer reveal, so the controls stay for them.
    private var controlsVisible: Bool {
        controlsShown || controlsHovered || voiceOver
    }

    private func revealControls() {
        if !controlsShown {
            controlsShown = true
        }
        controlsIdle.restart { controlsShown = false }
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Upcoming Songs")
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

/// Not observed: restarting on every pointer move must not redraw the view.
@MainActor private final class IdleTimer {
    private var task: Task<Void, Never>?

    func restart(after delay: Duration = .seconds(2.5), _ fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled {
                fire()
            }
        }
    }
}

private extension View {
    /// Stays hit-testable: a click needs a pointer move, which reveals it, and keyboard shortcuts must keep working.
    func fades(visible: Bool, reduceMotion: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: visible)
    }
}

/// Fades the window's close, minimize and zoom buttons with the view's own controls; leaving restores them.
private struct WindowButtonsFade: NSViewRepresentable {
    let visible: Bool
    let animated: Bool

    func makeNSView(context _: Context) -> NSView {
        Anchor()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        let alpha: CGFloat = visible ? 1 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.3 : 0
            for button in Self.buttons(of: view.window) where button.alphaValue != alpha {
                button.animator().alphaValue = alpha
            }
        }
    }

    /// Restores while the window is still reachable; by dismantle time it may be gone.
    private final class Anchor: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                WindowButtonsFade.buttons(of: window).forEach { $0.alphaValue = 1 }
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    fileprivate static func buttons(of window: NSWindow?) -> [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }
}
