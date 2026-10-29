import Network
import os

/// Whether macOS lets the app reach the local network, which Connect needs to find nearby devices.
/// macOS has no API to read the permission, so a Bonjour browse for Connect devices probes it.
public enum LocalNetworkAccess {
    /// Yields `false` while access is denied and `true` once browsing works; asks the first time.
    public static func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let last = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            let browser = NWBrowser(for: .bonjour(type: "_spotify-connect._tcp", domain: nil), using: .tcp)
            browser.stateUpdateHandler = { state in
                // The browser re-reports a denial while it waits; only changes are news.
                if let allowed = allowed(in: state), last.withLock({ previous in
                    defer { previous = allowed }
                    return previous != allowed
                }) {
                    continuation.yield(allowed)
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .main)
        }
    }

    /// Nil while the state says nothing about the permission.
    static func allowed(in state: NWBrowser.State) -> Bool? {
        switch state {
        case .ready: true
        case let .waiting(error), let .failed(error): error == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)) ? false : nil
        default: nil
        }
    }
}
