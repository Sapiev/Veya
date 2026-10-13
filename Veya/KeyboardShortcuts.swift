import SpotCoreKit
import SwiftUI

/// PBI-606: Music's Controls menu. It drives the player directly, so it works with the window closed.
struct PlaybackCommands: Commands {
    let activeSession: ActiveSession
    static let volumeStep = 0.1

    var body: some Commands {
        let player = activeSession.current?.player
        CommandMenu("Controls") {
            Group {
                Button(player?.isPlaying == true ? "Pause" : "Play") { player?.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Next") { player?.next() }
                    .keyboardShortcut(.rightArrow)
                Button("Previous") { player?.previous() }
                    .keyboardShortcut(.leftArrow)
                Divider()
                Button("Volume Up") { player.map { $0.volume = min($0.volume + Self.volumeStep, 1) } }
                    .keyboardShortcut(.upArrow)
                Button("Volume Down") { player.map { $0.volume = max($0.volume - Self.volumeStep, 0) } }
                    .keyboardShortcut(.downArrow)
                Divider()
                Toggle("Shuffle", isOn: Binding(get: { player?.shuffle == true }, set: { player?.setShuffle($0) }))
                    .keyboardShortcut("s")
                Button(Self.repeatTitle(player?.repeatMode ?? .off)) { player?.cycleRepeat() }
                    .keyboardShortcut("r")
            }
            .disabled(player == nil)
        }
    }

    private static func repeatTitle(_ mode: RepeatMode) -> LocalizedStringKey {
        switch mode {
        case .off: "Repeat: Off"
        case .context: "Repeat: All"
        case .track: "Repeat: One"
        }
    }
}

/// Help menu: the shortcut list and the diagnostics export.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsView.windowID) }
            Button("Export Diagnostics…") {
                Task { await Diagnostics.export() }
            }
        }
    }
}

/// Every shortcut Veya adds, as the Help menu lists them.
struct KeyboardShortcutsView: View {
    static let windowID = "shortcuts"

    private static let sections: [(title: LocalizedStringKey, rows: [(keys: String, action: LocalizedStringKey)])] = [
        ("Playback", [
            (String(localized: "Space", comment: "Space bar key"), "Play or Pause"),
            ("⌘→", "Next"),
            ("⌘←", "Previous"),
            ("⌘↑", "Volume Up"),
            ("⌘↓", "Volume Down"),
            ("⌘S", "Shuffle"),
            ("⌘R", "Repeat"),
        ]),
        ("Navigation", [
            ("⌘L", "Search"),
            ("⌘F", "Search"),
            ("⌘[", "Back"),
            ("⌘]", "Forward"),
            ("⌃⌘S", "Show or Hide Sidebar"),
            ("⌥⌘I", "Show or Hide Queue"),
            ("⌘0", "Main Window"),
        ]),
        ("Library", [
            ("⌘N", "New Playlist"),
            ("⌘O", "Open Link"),
            ("⌘Z", "Undo"),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(Self.sections.indices, id: \.self) { section in
                Section(Self.sections[section].title) {
                    ForEach(Self.sections[section].rows.indices, id: \.self) { row in
                        let shortcut = Self.sections[section].rows[row]
                        LabeledContent {
                            Text(verbatim: shortcut.keys)
                                .monospaced()
                        } label: {
                            Text(shortcut.action)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}
