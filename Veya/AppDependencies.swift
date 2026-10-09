import Foundation
import os
import SpotCoreKit

/// Everything the app talks to outside its own process.
struct AppDependencies {
    var store: any CredentialStore
    var connector: any SessionConnector
    var browser: any SignInBrowser
    var startFlow: SignInFlowStarter

    static func make() -> AppDependencies {
        #if DEBUG
            if let scenario = UITestScenario.current() {
                return scenario.dependencies
            }
        #endif
        return AppDependencies(
            store: KeychainCredentialStore(
                service: Bundle.main.bundleIdentifier ?? "Veya",
                account: "spotcore-credentials"
            ),
            connector: SpotSessionConnector(audioCache: openAudioCache()),
            browser: WebAuthenticationBrowser(),
            startFlow: SignInModel.startLoginFlow
        )
    }

    /// Playback works without a cache, so a failure to open one is only logged.
    @MainActor private static func openAudioCache() -> AudioCache? {
        let directory = URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "Veya")
            .appending(path: "Audio")
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
}
