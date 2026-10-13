import AppIntents
import SpotCoreKit

/// PBI-604: Shortcuts, Siri and Spotlight actions, run in the app through `ShortcutActions`.
struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the music in Veya.")
    @Dependency private var actions: ShortcutActions

    func perform() async throws -> some IntentResult {
        try await actions.perform(.togglePlayPause)
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next track in Veya.")
    @Dependency private var actions: ShortcutActions

    func perform() async throws -> some IntentResult {
        try await actions.perform(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Goes back to the previous track in Veya.")
    @Dependency private var actions: ShortcutActions

    func perform() async throws -> some IntentResult {
        try await actions.perform(.previous)
        return .result()
    }
}

struct LikeCurrentTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Like Current Track"
    static let description = IntentDescription("Saves the playing track to Liked Songs.")
    @Dependency private var actions: ShortcutActions

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await actions.likeCurrentTrack()
        return .result(dialog: "Saved to Liked Songs.")
    }
}

struct GetCurrentTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Track"
    static let description = IntentDescription("Returns the title and artist of the playing track.")
    @Dependency private var actions: ShortcutActions

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let track = try await actions.currentTrack()
        let summary = "\(track.title) - \(track.artist)"
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct PlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays one of your playlists in Veya.")
    @Parameter(title: "Playlist") var playlist: PlaylistEntity
    @Dependency private var actions: ShortcutActions

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)")
    }

    func perform() async throws -> some IntentResult {
        try await actions.playPlaylist(playlist.id)
        return .result()
    }
}

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistQuery()
    /// The playlist URI.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PlaylistQuery: EntityStringQuery {
    @Dependency private var actions: ShortcutActions

    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        try await playlists().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        try await playlists(matching: string)
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await playlists()
    }

    private func playlists(matching query: String? = nil) async throws -> [PlaylistEntity] {
        try await actions.playlists(matching: query).map { PlaylistEntity(id: $0.id, name: $0.name) }
    }
}

struct VeyaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: ["Play or pause \(.applicationName)", "Pause \(.applicationName)"],
            shortTitle: "Play or Pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Next track in \(.applicationName)", "Skip song in \(.applicationName)"],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: ["Previous track in \(.applicationName)"],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: ["Play \(\.$playlist) in \(.applicationName)", "Play a playlist in \(.applicationName)"],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: LikeCurrentTrackIntent(),
            phrases: ["Like this song in \(.applicationName)"],
            shortTitle: "Like Current Track",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: GetCurrentTrackIntent(),
            phrases: ["What's playing in \(.applicationName)"],
            shortTitle: "Current Track",
            systemImageName: "music.note"
        )
    }
}

extension ShortcutActions.Failure: @retroactive CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Veya isn't signed in or couldn't start playback."
        case .nothingPlaying: "Nothing is playing in Veya."
        }
    }
}
