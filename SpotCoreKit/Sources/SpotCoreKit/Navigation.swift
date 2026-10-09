import Observation

/// A screen in the main window. Detail routes carry the Spotify URI they show.
public enum Route: Hashable, Sendable {
    case home
    case search
    case likedSongs
    case albums
    case artists
    case podcasts
    case playlist(uri: String)
    case album(uri: String)
    case artist(uri: String)
    case show(uri: String)
}

/// Browser-style back and forward history for the main window.
@MainActor
@Observable
public final class NavigationHistory {
    public private(set) var current: Route
    private var backStack: [Route] = []
    private var forwardStack: [Route] = []

    public init(start: Route = .home) {
        current = start
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Opening a new route drops the forward history, as in a browser.
    public func navigate(to route: Route) {
        guard route != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = route
    }

    public func back() {
        guard let route = backStack.popLast() else { return }
        forwardStack.append(current)
        current = route
    }

    public func forward() {
        guard let route = forwardStack.popLast() else { return }
        backStack.append(current)
        current = route
    }
}
