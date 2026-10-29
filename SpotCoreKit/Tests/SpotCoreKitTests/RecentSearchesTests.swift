import Foundation
@testable import SpotCoreKit
import Testing

@MainActor
struct RecentSearchesTests {
    private let defaults: UserDefaults

    init() {
        let suite = "RecentSearchesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func newestQueryComesFirst() {
        let recent = RecentSearches(defaults: defaults)
        recent.add("daft punk")
        recent.add("  bonobo ")

        #expect(recent.queries == ["bonobo", "daft punk"])
    }

    @Test func repeatingAQueryMovesItToTheFrontOnce() {
        let recent = RecentSearches(defaults: defaults)
        recent.add("Daft Punk")
        recent.add("bonobo")
        recent.add("daft punk")

        #expect(recent.queries == ["daft punk", "bonobo"])
    }

    @Test func pastedLinksLoseTheirQueryStringAndLongTextIsCut() {
        let recent = RecentSearches(defaults: defaults)
        recent.add("https://open.spotify.com/track/abc?si=secret123")
        recent.add(String(repeating: "x", count: 500))

        #expect(recent.queries == [String(repeating: "x", count: RecentSearches.maxLength), "https://open.spotify.com/track/abc"])
        defaults.set(["https://a.b/c?si=old", String(repeating: "y", count: 300)], forKey: "recentSearches")
        #expect(RecentSearches(defaults: defaults).queries == ["https://a.b/c", String(repeating: "y", count: 100)])
    }

    @Test func blankQueriesAreIgnored() {
        let recent = RecentSearches(defaults: defaults)
        recent.add("   ")

        #expect(recent.queries.isEmpty)
    }

    @Test func keepsOnlyTheNewestSix() {
        let recent = RecentSearches(defaults: defaults)
        for n in 1 ... 8 {
            recent.add("query \(n)")
        }

        #expect(recent.queries == (3 ... 8).reversed().map { "query \($0)" })
    }

    @Test func removingOneQueryKeepsTheRestAndPersists() {
        let recent = RecentSearches(defaults: defaults)
        recent.add("bonobo")
        recent.add("Daft Punk")

        recent.remove("Daft Punk")

        #expect(recent.queries == ["bonobo"])
        #expect(RecentSearches(defaults: defaults).queries == ["bonobo"])
    }

    @Test func persistsAcrossLaunchesUntilCleared() {
        RecentSearches(defaults: defaults).add("bonobo")
        #expect(RecentSearches(defaults: defaults).queries == ["bonobo"])

        RecentSearches(defaults: defaults).clear()
        #expect(RecentSearches(defaults: defaults).queries.isEmpty)
    }
}
