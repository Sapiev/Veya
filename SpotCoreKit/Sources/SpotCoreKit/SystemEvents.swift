import AppKit
import Network

/// Reports reachability changes only: not the first reading, not repeats.
struct ReachabilityTransitions {
    private var last: Bool?

    mutating func update(_ available: Bool) -> Bool? {
        defer { last = available }
        guard let last, last != available else { return nil }
        return available
    }
}

/// Forwards system wake and network reachability changes to the session.
@MainActor
public final class SystemEvents {
    private let monitor = NWPathMonitor()
    private var transitions = ReachabilityTransitions()
    private var wakeObserver: (any NSObjectProtocol)?

    public init(
        onWake: @escaping @MainActor () -> Void,
        onNetworkChange: @escaping @MainActor (Bool) -> Void
    ) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWake() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            MainActor.assumeIsolated {
                guard let self, let changed = self.transitions.update(available) else { return }
                onNetworkChange(changed)
            }
        }
        monitor.start(queue: .main)
    }

    isolated deinit {
        monitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
