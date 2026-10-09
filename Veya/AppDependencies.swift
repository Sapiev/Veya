import Foundation
import os
import SpotCoreKit

/// Everything the app talks to outside its own process.
struct AppDependencies {
    var store: any CredentialStore
    var refreshTokenStore: any CredentialStore
    var connector: any SessionConnector
    var browser: any SignInBrowser
    var startFlow: SignInFlowStarter
    var artworkLoader: ArtworkLoader?
    var metadataStore: MetadataStore?
    var defaults: UserDefaults = .standard

    static func make() -> AppDependencies {
        #if DEBUG
            if let scenario = UITestScenario.current() {
                return scenario.dependencies
            }
        #endif
        let metadataStore = openMetadataStore()
        return AppDependencies(
            store: KeychainCredentialStore(
                service: Bundle.main.bundleIdentifier ?? "Veya",
                account: "spotcore-credentials"
            ),
            refreshTokenStore: KeychainCredentialStore(
                service: Bundle.main.bundleIdentifier ?? "Veya",
                account: "spotify-refresh-token"
            ),
            connector: SpotSessionConnector(audioCache: openAudioCache(), metadataStore: metadataStore),
            browser: WebAuthenticationBrowser(),
            startFlow: SignInModel.startLoginFlow,
            artworkLoader: ArtworkLoader(directory: cachesDirectory.appending(path: "Artwork")),
            metadataStore: metadataStore
        )
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
