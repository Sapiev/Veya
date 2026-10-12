import AppKit
import SpotCoreKit

/// PBI-603: the Dock icon's menu, built fresh each time it opens.
enum DockMenu {
    @MainActor
    static func make(_ controls: MediaControls) -> NSMenu {
        let menu = NSMenu()
        guard let info = controls.current else {
            menu.addItem(withTitle: String(localized: "Not Playing"), action: nil, keyEquivalent: "")
            return menu
        }
        menu.addItem(.sectionHeader(title: String(localized: "Now Playing")))
        menu.addItem(withTitle: info.title, action: nil, keyEquivalent: "")
        menu.addItem(withTitle: info.artist, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(CommandItem(info.isPlaying ? String(localized: "Pause") : String(localized: "Play"), .togglePlayPause, controls))
        menu.addItem(CommandItem(String(localized: "Next"), .next, controls))
        menu.addItem(CommandItem(String(localized: "Previous"), .previous, controls))
        menu.addItem(CommandItem(
            info.saved ? String(localized: "Remove from Liked Songs") : String(localized: "Save to Liked Songs"),
            .like,
            controls
        ))
        return menu
    }
}

// Nonisolated to match NSMenuItem's initializers; the action still runs on the main actor.
nonisolated private final class CommandItem: NSMenuItem {
    private let command: MediaControls.Command
    private let controls: MediaControls

    init(_ title: String, _ command: MediaControls.Command, _ controls: MediaControls) {
        self.command = command
        self.controls = controls
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor @objc private func run() {
        controls.perform(command)
    }
}
