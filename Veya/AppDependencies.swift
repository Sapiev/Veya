import Foundation
import os
import SpotCoreKit

/// Everything the app talks to outside its own process.
struct AppDependencies {
    var store: any CredentialStore
    /// The Web API refresh token of the user's own client ID.
    var refreshTokenStore: any CredentialStore
    var connector: any SessionConnector
    var browser: any SignInBrowser
    var startFlow: SignInFlowStarter
    var webAPIStartFlow: WebAPIFlowStarter = { try await LoginFlow.start(config: $0) }
    var tokenRefresher: any TokenRefresher = SpotTokenRefresher()
    var artworkLoader: ArtworkLoader?
    var metadataStore: MetadataStore?
    var defaults: UserDefaults = .standard
    /// `nil` reads episode progress from the Web API with the session's tokens.
    var episodeProgress: (any EpisodeProgressProvider)?

    static func make() -> AppDependencies {
        #if DEBUG
            if let scenario = UITestScenario.current() {
                return scenario.dependencies
            }
        #endif
        let metadataStore = openMetadataStore()
        deleteSharedClientRefreshToken()
        return AppDependencies(
            store: KeychainCredentialStore(
                service: Bundle.main.bundleIdentifier ?? "Veya",
                account: "spotcore-credentials"
            ),
            refreshTokenStore: KeychainCredentialStore(
                service: Bundle.main.bundleIdentifier ?? "Veya",
                account: "web-api-refresh-token"
            ),
            connector: SpotSessionConnector(audioCache: openAudioCache(), metadataStore: metadataStore),
            browser: WebAuthenticationBrowser(),
            startFlow: SignInModel.startLoginFlow,
            artworkLoader: ArtworkLoader(directory: cachesDirectory.appending(path: "Artwork")),
            metadataStore: metadataStore
        )
    }

    /// Builds before PBI-309 kept the shared client ID's refresh token for the
    /// Web API, which is rate limited there. Deleting a missing item succeeds,
    /// so this runs at every launch until it once gets through.
    private static func deleteSharedClientRefreshToken() {
        let legacy = KeychainCredentialStore(service: Bundle.main.bundleIdentifier ?? "Veya", account: "spotify-refresh-token")
        do {
            try legacy.delete()
        } catch {
            Logger(subsystem: "veya", category: "session").error("stale refresh token not deleted: \(error)")
        }
    }

    /// Playback works without a cache, so a failure to open one is only logged.
    @MainActor private static func openAudioCache() -> AudioCache? {
        let directory = cachesDirectory.appending(path: "Audio")
        do {
            return try AudioCache(
                directory: directory.path(percentEncoded: false),
                limitBytes: PlaybackSettings().audioCacheLimitBytes
            )
        } catch {
            Logger(subsystem: "veya", category: "cache").error("audio cache unavailable: \(error)")
            return nil
        }
    }

    /// Library and metadata load from the network without a store, so a
    /// failure to open one is only logged.
    private static func openMetadataStore() -> MetadataStore? {
        let path = cachesDirectory.appending(path: "Metadata.sqlite")
        do {
            return try MetadataStore.open(path: path.path(percentEncoded: false))
        } catch {
            Logger(subsystem: "veya", category: "cache").error("metadata store unavailable: \(error)")
            return nil
        }
    }

    private static var cachesDirectory: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Veya")
    }
}
