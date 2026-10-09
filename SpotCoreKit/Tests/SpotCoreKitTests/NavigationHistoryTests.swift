@testable import SpotCoreKit
import Testing

@MainActor
struct NavigationHistoryTests {
    @Test func startsAtHomeWithNoHistory() {
        let history = NavigationHistory()
        #expect(history.current == .home)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func backAndForwardWalkTheVisitedRoutes() {
        let history = NavigationHistory()
        history.navigate(to: .likedSongs)
        history.navigate(to: .albums)

        history.back()
        #expect(history.current == .likedSongs)
        history.back()
        #expect(history.current == .home)
        #expect(!history.canGoBack)

        history.forward()
        history.forward()
        #expect(history.current == .albums)
        #expect(!history.canGoForward)
    }

    @Test func navigatingDropsForwardHistory() {
        let history = NavigationHistory()
        history.navigate(to: .likedSongs)
        history.back()
        history.navigate(to: .artists)

        #expect(!history.canGoForward)
        history.back()
        #expect(history.current == .home)
    }

    @Test func navigatingToTheCurrentRouteAddsNoEntry() {
        let history = NavigationHistory()
        history.navigate(to: .playlist(uri: "spotify:playlist:a"))
        history.navigate(to: .playlist(uri: "spotify:playlist:a"))

        history.back()
        #expect(history.current == .home)
    }

    @Test func backAndForwardAtTheEndsDoNothing() {
        let history = NavigationHistory()
        history.back()
        history.forward()
        #expect(history.current == .home)
    }
}

@MainActor
struct PlaylistModelTests {
    private let mine = RootlistEntry.playlist(uri: "spotify:playlist:a", name: "Mine", owner: "me", trackCount: 3, parent: nil)
    private let cached = RootlistEntry.playlist(uri: "spotify:playlist:b", name: "Old", owner: "me", trackCount: 1, parent: nil)

    @Test func showsTheCachedListThenTheServerList() async {
        let model = PlaylistModel(playlists: StubPlaylists(rootlist: .success([mine]), pages: [], cached: [cached]))

        let task = model.load()
        #expect(model.rootlist == [cached])
        #expect(model.state == .loaded)

        await task.value
        #expect(model.rootlist == [mine])
    }

    @Test func failsOnlyWhenNothingIsCached() async {
        let failing = PlaylistModel(playlists: StubPlaylists(rootlist: .failure(.Request(message: "x")), pages: []), log: { _, _ in })
        await failing.load().value
        #expect(failing.state == .failed)

        let stale = PlaylistModel(
            playlists: StubPlaylists(rootlist: .failure(.Request(message: "x")), pages: [], cached: [cached]),
            log: { _, _ in }
        )
        await stale.load().value
        #expect(stale.state == .loaded)
        #expect(stale.rootlist == [cached])
    }
}
