import Foundation
import os
import SpotCoreKit
import Testing

/// Answers from `results` (pages from key `query#offset`), or throws `error`;
/// held requests wait for `release`.
final class FakeSearch: SearchServiceProtocol {
    private struct Box {
        var results: [String: [SearchGroup]] = [:]
        var error: (any Error)?
        var hold = false
        var queries: [String] = []
        var pages: [(kind: SearchKind, offset: UInt32)] = []
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    init(_ results: [String: [SearchGroup]] = [:], error: (any Error)? = nil) {
        box.withLock {
            $0.results = results
            $0.error = error
        }
    }

    var queries: [String] {
        box.withLock { $0.queries }
    }

    var pages: [(kind: SearchKind, offset: UInt32)] {
        box.withLock { $0.pages }
    }

    var heldCount: Int {
        box.withLock { $0.held.count }
    }

    func hold() {
        box.withLock { $0.hold = true }
    }

    /// Resumes held requests in arrival order.
    func release(_ index: Int) {
        box.withLock { $0.held[index] }.resume()
    }

    func search(query: String, limit _: UInt32) async throws -> [SearchGroup] {
        try await answer(query)
    }

    func page(query: String, kind: SearchKind, offset: UInt32, limit _: UInt32) async throws -> SearchGroup {
        box.withLock { $0.pages.append((kind, offset)) }
        let groups = try await answer("\(query)#\(offset)")
        let hits = groups.first { $0.kind == kind }?.hits ?? []
        return SearchGroup(kind: kind, total: groups.first?.total ?? 0, offset: offset, hits: hits)
    }

    private func answer(_ query: String) async throws -> [SearchGroup] {
        let held = box.withLock {
            $0.queries.append(query)
            return $0.hold
        }
        if held {
            await withCheckedContinuation { waiter in box.withLock { $0.held.append(waiter) } }
        }
        let (results, error) = box.withLock { ($0.results[query] ?? [], $0.error) }
        if let error {
            throw error
        }
        return results
    }
}

private func hit(_ name: String) -> SearchHit {
    SearchHit(uri: "spotify:track:\(name)", name: name, subtitle: "", artwork: [], explicit: false)
}

private func tracks(_ names: String..., total: UInt32) -> [SearchGroup] {
    [SearchGroup(kind: .track, total: total, offset: 0, hits: names.map(hit))]
}

private let refused = SearchError.Request(message: "refused")

@MainActor
struct SearchModelTests {
    @Test func typingIsDebouncedIntoOneRequest() async {
        let service = FakeSearch(["abc": tracks("x", total: 1)])
        let model = SearchModel(service: service, debounce: .milliseconds(20))

        model.search("a")
        model.search("ab")
        await model.search("abc").value

        #expect(service.queries == ["abc"])
        #expect(model.groups == tracks("x", total: 1))
        #expect(model.state == .loaded)
    }

    @Test func aStaleResponseIsDropped() async throws {
        let service = FakeSearch(["old": tracks("old", total: 1), "new": tracks("new", total: 1)])
        service.hold()
        let model = SearchModel(service: service, debounce: .zero)

        let old = model.search("old")
        try await waitUntil { service.heldCount == 1 }
        let new = model.search("new")
        try await waitUntil { service.heldCount == 2 }
        service.release(1)
        await new.value
        service.release(0)
        await old.value

        #expect(model.groups == tracks("new", total: 1))
    }

    @Test func aBlankQueryClearsWithoutARequest() async {
        let service = FakeSearch(["a": tracks("x", total: 1)])
        let model = SearchModel(service: service, debounce: .zero)
        await model.search("a").value

        await model.search("  ").value

        #expect(model.groups.isEmpty)
        #expect(model.state == .idle)
        #expect(service.queries == ["a"])
    }

    @Test func aFailureIsTypedAndUsesTheFallback() async {
        let fallback = FakeSearch(["a": tracks("web", total: 1)])
        let logs = LogSpy()
        let model = SearchModel(
            service: FakeSearch(error: refused), fallback: fallback, debounce: .zero, log: logs.log
        )

        await model.search("a").value

        #expect(model.failure == refused)
        #expect(model.groups == tracks("web", total: 1))
        #expect(model.state == .loaded)
        #expect(logs.entries.allSatisfy { !$0.1.contains("refused") }, "server text stays out of logs")
    }

    @Test(arguments: [CancellationError() as any Error, URLError(.cancelled)])
    func aCancelledRequestIsNotAFailure(error: any Error) async {
        let fallback = FakeSearch(["a": tracks("web", total: 1)])
        let logs = LogSpy()
        let model = SearchModel(service: FakeSearch(error: error), fallback: fallback, debounce: .zero, log: logs.log)

        await model.search("a").value

        #expect(model.failure == nil)
        #expect(fallback.queries.isEmpty)
        #expect(logs.entries.isEmpty)
    }

    @Test func aFailureWithoutAFallbackFails() async {
        let model = SearchModel(service: FakeSearch(error: refused), debounce: .zero, log: LogSpy().log)

        await model.search("a").value

        #expect(model.failure == refused)
        #expect(model.state == .failed)
        #expect(model.groups.isEmpty)
    }

    @Test(arguments: [WebAPITokenError.notAvailable, .rejected])
    func aMissingWebAPITokenIsNotConnectedAndSkipsTheFallback(error: WebAPITokenError) async {
        let fallback = FakeSearch(["a": tracks("web", total: 1)])
        let model = SearchModel(service: FakeSearch(error: error), fallback: fallback, debounce: .zero, log: LogSpy().log)

        await model.search("a").value

        #expect(model.state == .notConnected)
        #expect(model.failure == nil)
        #expect(model.groups.isEmpty)
        #expect(fallback.queries.isEmpty)
    }

    @Test func rateLimitIsKeptAsTheFailure() async {
        let model = SearchModel(service: FakeSearch(error: SearchError.RateLimited), debounce: .zero, log: LogSpy().log)

        await model.search("a").value

        #expect(model.state == .failed)
        #expect(model.failure == .RateLimited)
    }

    @Test func seeAllAppendsTheNextPageUntilTheTotal() async throws {
        let pages = ["a#1": tracks("2", total: 3), "a#2": tracks("3", total: 3)]
        let service = FakeSearch(pages.merging(["a": tracks("1", total: 3)]) { $1 })
        let model = SearchModel(service: service, debounce: .zero)
        await model.search("a").value
        #expect(model.hasMore(.track))

        let page = try #require(model.loadMore(.track))
        #expect(model.loadMore(.track) == page, "a second tap joins the running page")
        await page.value
        await model.loadMore(.track)?.value

        #expect(service.pages.map(\.offset) == [1, 2])
        #expect(model.groups[0].hits.map(\.name) == ["1", "2", "3"])
        #expect(!model.hasMore(.track))
        #expect(model.loadMore(.track) == nil)
    }

    @Test func anEmptyPageEndsSeeAll() async {
        let service = FakeSearch(["a": tracks("1", total: 50)])
        let model = SearchModel(service: service, debounce: .zero)
        await model.search("a").value

        await model.loadMore(.track)?.value

        #expect(model.groups[0].hits.count == 1)
        #expect(!model.hasMore(.track))
    }

    @Test func aPageForAnOldQueryIsDropped() async throws {
        let service = FakeSearch(["a": tracks("1", total: 3), "a#1": tracks("2", total: 3)])
        let model = SearchModel(service: service, debounce: .zero)
        await model.search("a").value
        service.hold()
        let page = try #require(model.loadMore(.track))
        try await waitUntil { service.heldCount == 1 }

        let next = model.search("b")
        try await waitUntil { service.heldCount == 2 }
        service.release(0)
        await page.value
        service.release(1)
        await next.value

        #expect(model.groups.isEmpty)
        #expect(model.state == .loaded)
    }
}
