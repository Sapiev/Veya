import AppKit
import SpotCoreKit
import SwiftUI

/// PBI-602 preferences. Observable rather than `@AppStorage`: the status item writes
/// its own visibility to defaults, which would re-fire `@AppStorage` in a loop.
@Observable
final class MenuBarSettings {
    var shown: Bool {
        didSet {
            defaults.set(shown, forKey: Key.shown)
            // Without the menu bar item a Dock-less app could not be reached again.
            if !shown {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    var showsTitle: Bool {
        didSet { defaults.set(showsTitle, forKey: Key.showsTitle) }
    }

    /// Takes effect when the main window next closes.
    var hidesDockIcon: Bool {
        didSet { defaults.set(hidesDockIcon, forKey: Key.hidesDockIcon) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Defaults to the item shown with an icon, and the Dock icon kept.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        shown = defaults.object(forKey: Key.shown) as? Bool ?? true
        showsTitle = defaults.bool(forKey: Key.showsTitle)
        hidesDockIcon = defaults.bool(forKey: Key.hidesDockIcon)
    }

    /// Called as the main window closes.
    func windowClosed() {
        if shown, hidesDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private enum Key {
        static let shown = "menuBar.shown"
        static let showsTitle = "menuBar.showsTitle"
        static let hidesDockIcon = "menuBar.hidesDockIcon"
    }
}

/// The mini-player that drops down from the menu bar.
struct MenuBarPlayer: View {
    let activeSession: ActiveSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: Theme.s3) {
            if let player = activeSession.scope?.player, let library = activeSession.scope?.library {
                MenuBarNowPlaying(player: player, library: library)
            } else {
                Text("Not Playing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            Divider()
            Button("Open Veya") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate()
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.s4)
        .frame(width: 300)
    }
}

private struct MenuBarNowPlaying: View {
    let player: PlayerModel
    let library: LibraryModel

    var body: some View {
        VStack(spacing: Theme.s3) {
            if let nowPlaying = player.nowPlaying {
                HStack(spacing: Theme.s3) {
                    ArtworkView(artwork: nowPlaying.artwork, side: 52)
                        .clipShape(.rect(cornerRadius: Theme.cardRadius))
                        .crossDissolve(on: nowPlaying.uri)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(nowPlaying.title)
                            .scaledFont(size: 13, weight: .semibold)
                        Text(nowPlaying.artists.map(\.name).formatted(.list(type: .and)))
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .dissolvesContent(on: nowPlaying.uri)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    LikeButton(uri: nowPlaying.uri, library: library)
                }
            } else {
                Text("Not Playing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Theme.s2) {
                TransportControls(player: player)
            }
            Scrubber(player: player)
                .disabled(player.nowPlaying == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// The menu bar item: an icon, or the playing title scrolling through a fixed width.
struct MenuBarLabel: View {
    let activeSession: ActiveSession
    let showsTitle: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    var body: some View {
        if showsTitle, let title = activeSession.scope?.player?.nowPlaying?.title {
            Group {
                if reduceMotion || title.count <= Self.width {
                    Text(Self.truncated(title))
                } else {
                    // A sleeping task, not a TimelineView: the status item rebuilds its label on
                    // every change, which restarts a TimelineView and refires it without pause.
                    Text(Self.marquee(title, step: step))
                        .task(id: title) {
                            while await (try? Task.sleep(for: .milliseconds(300))) != nil {
                                step += 1
                            }
                        }
                }
            }
            .accessibilityLabel(title)
        } else {
            Image(systemName: "music.note")
                .accessibilityLabel("Veya")
        }
    }

    static let width = 24

    /// `width` characters of `title` starting `step` places in, wrapping with a gap; short titles stay put.
    static func marquee(_ title: String, step: Int) -> String {
        let characters = Array(title)
        guard characters.count > width else { return title }
        let loop = characters + Array("   ·   ")
        let start = step % loop.count
        return String((0 ..< width).map { loop[(start + $0) % loop.count] })
    }

    static func truncated(_ title: String) -> String {
        title.count > width ? title.prefix(width - 1) + "…" : title
    }
}
