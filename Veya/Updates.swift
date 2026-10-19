import Combine
import Foundation
import Sparkle
import SwiftUI

/// PBI-902: Sparkle checks the appcast on GitHub Pages; Include beta versions adds its "beta" channel.
@MainActor @Observable final class Updates: NSObject, SPUUpdaterDelegate {
    /// Off by default; read on every check.
    nonisolated static let betaKey = "updates.beta"

    /// Debug builds and UI tests never replace themselves with a release, and
    /// a build without the signing key (from source) cannot verify one.
    private static var isConfigured: Bool {
        #if DEBUG
            false
        #else
            !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
        #endif
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    private(set) var canCheck = false
    var checksAutomatically = false {
        didSet {
            guard checksAutomatically != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        guard Self.isConfigured else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        // Sparkle also sets automatic checks itself, when it asks on the second launch.
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.checksAutomatically = $0 }
            .store(in: &observations)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &observations)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sparkle calls its delegate on the main thread.
    /// Sparkle ends the app with a plain terminate, which the delegate refuses unless a quit was requested.
    nonisolated func updaterWillRelaunchApplication(_: SPUUpdater) {
        MainActor.assumeIsolated { AppDelegate.quitRequested = true }
    }

    nonisolated func allowedChannels(for _: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { defaults.bool(forKey: Self.betaKey) } ? ["beta"] : []
    }
}

struct UpdateCommands: Commands {
    let updates: Updates

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
        }
    }
}

/// Settings › Advanced.
struct UpdatesSection: View {
    @Bindable var updates: Updates
    @AppStorage(Updates.betaKey) private var includesBetas = false

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                .accessibilityLabel("Check for updates automatically")
            Toggle(isOn: $includesBetas) {
                Text("Include beta versions")
                Text("Beta versions get new features first and may be less stable.")
            }
            .accessibilityLabel("Include beta versions")
        }
    }
}
