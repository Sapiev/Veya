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

    @Test func blankQueriesAreIgnored() {
        let recent = RecentSearches(defaults: defaults)
        recent.add("   ")

        #expect(recent.queries.isEmpty)
    }

    @Test func keepsOnlyTheNewestTen() {
        let recent = RecentSearches(defaults: defaults)
        for n in 1 ... 12 {
            recent.add("query \(n)")
        }

        #expect(recent.queries.count == RecentSearches.limit)
        #expect(recent.queries.first == "query 12")
        #expect(recent.queries.last == "query 3")
    }

    @Test func persistsAcrossLaunchesUntilCleared() {
        RecentSearches(defaults: defaults).add("bonobo")
        #expect(RecentSearches(defaults: defaults).queries == ["bonobo"])

        RecentSearches(defaults: defaults).clear()
        #expect(RecentSearches(defaults: defaults).queries.isEmpty)
    }
}
