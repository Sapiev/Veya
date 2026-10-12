import SpotCoreKit
import SwiftUI

/// One signed-in session's player and Liked Songs, kept outside the window so
/// playback and the media keys carry on with it closed.
@Observable
final class SessionScope {
    let handle: any SessionHandle
    let metadata: any MetadataServiceProtocol
    let library: LibraryModel
    private(set) var player: PlayerModel?
    @ObservationIgnored private let settings: PlaybackSettings
    /// Hands the started player to the session owner, which stops it on sign out; false drops it.
    @ObservationIgnored private let attach: (PlayerModel) -> Bool

    init(
        handle: any SessionHandle,
        metadataStore: MetadataStore?,
        settings: PlaybackSettings,
        attach: @escaping (PlayerModel) -> Bool
    ) {
        self.handle = handle
        self.settings = settings
        self.attach = attach
        metadata = handle.makeMetadata(store: metadataStore)
        library = LibraryModel(library: handle.makeLibrary(store: metadataStore), metadata: metadata)
    }

    /// Starts the player and follows the library until cancelled.
    func run() async {
        async let started: Void = startPlayer()
        library.load(.tracks)
        await library.watch()
        await started
    }

    private func startPlayer() async {
        do {
            let started = try await PlayerModel.start(session: handle, metadata: metadata, settings: settings)
            if attach(started) { player = started }
        } catch {
            // Type name only: messages may carry server text.
            logMessage(level: .error, category: "player", message: "Player unavailable: \(type(of: error))")
        }
    }
}

/// Keeps the current session's scope for the app's lifetime and points the
/// media controls at its player.
@Observable
final class ActiveSession {
    private(set) var scope: SessionScope?
    @ObservationIgnored private let session: SessionModel
    @ObservationIgnored private let controls: MediaControls
    @ObservationIgnored private let make: (any SessionHandle) -> SessionScope
    @ObservationIgnored private var running: Task<Void, Never>?

    init(session: SessionModel, controls: MediaControls, make: @escaping (any SessionHandle) -> SessionScope) {
        self.session = session
        self.controls = controls
        self.make = make
        follow()
    }

    private func follow() {
        withObservationTracking {
            let handle = session.session
            if scope?.handle !== handle {
                running?.cancel()
                scope = handle.map(make)
                running = scope.map { scope in Task { await scope.run() } }
            }
            controls.bind(player: scope?.player, library: scope?.library)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }
}
