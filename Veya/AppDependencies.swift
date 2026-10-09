import Foundation
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
            connector: SpotSessionConnector(),
            browser: WebAuthenticationBrowser(),
            startFlow: SignInModel.startLoginFlow
        )
    }
}
