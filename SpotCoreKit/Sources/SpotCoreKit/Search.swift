import Foundation
import Observation

public enum SearchState: Equatable, Sendable {
    case idle
    case searching
    case loaded
    /// Both the internal endpoint and the fallback, if any, failed.
    case failed
}

public typealias SearchLog = @MainActor (LogLevel, String) -> Void

/// Search results for the latest query, grouped by kind.
///
/// Typing is debounced, and a response is published only while its query is
/// still the latest one, so a slow reply never overwrites a newer search.
@MainActor
@Observable
public final class SearchModel {
    public private(set) var query = ""
    public private(set) var groups: [SearchGroup] = []
    public private(set) var state = SearchState.idle
    /// Why the internal endpoint failed for the current query; set even when
    /// the fallback provider answered instead.
    public private(set) var failure: SearchError?

    @ObservationIgnored private let primary: any SearchServiceProtocol
    @ObservationIgnored private let fallback: (any SearchServiceProtocol)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let limit: UInt32
    @ObservationIgnored private let log: SearchLog
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var pages: [SearchKind: Task<Void, Never>] = [:]
    /// Bumped by every `search`; a response from an older one is dropped.
    @ObservationIgnored private var generation = 0

    /// `fallback` is the optional Web API provider, used only when the
    /// internal endpoint fails.
    public init(
        service: any SearchServiceProtocol,
        fallback: (any SearchServiceProtocol)? = nil,
        debounce: Duration = .milliseconds(250),
        limit: UInt32 = 20,
        log: @escaping SearchLog = { logMessage(level: $0, category: "search", message: $1) }
    ) {
        primary = service
        self.fallback = fallback
        self.debounce = debounce
        self.limit = limit
        self.log = log
    }

    /// Searches for `query` once typing pauses; cancels any earlier search.
    @discardableResult
    public func search(_ query: String) -> Task<Void, Never> {
        self.query = query
        generation += 1
        let mine = generation
        running?.cancel()
        pages.values.forEach { $0.cancel() }
        pages = [:]
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            groups = []
            failure = nil
            state = .idle
            running = nil
            return Task {}
        }
        state = .searching
        let task = Task { [debounce, limit] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            let (result, failure) = await fetch { try await $0.search(query: query, limit: limit) }
            guard mine == generation else { return }
            self.failure = failure
            if let result {
                groups = result
                state = .loaded
            } else {
                groups = []
                state = .failed
            }
        }
        running = task
        return task
    }

    /// Whether "See all" can load more of `kind`.
    public func hasMore(_ kind: SearchKind) -> Bool {
        guard let group = groups.first(where: { $0.kind == kind }) else { return false }
        return group.offset + UInt32(group.hits.count) < group.total
    }

    /// Appends the next page of `kind`; a no-op while one is already loading.
    @discardableResult
    public func loadMore(_ kind: SearchKind) -> Task<Void, Never>? {
        if let loading = pages[kind] {
            return loading
        }
        guard hasMore(kind), let group = groups.first(where: { $0.kind == kind }) else { return nil }
        let query = query
        let mine = generation
        let offset = group.offset + UInt32(group.hits.count)
        let task = Task { [limit] in
            defer {
                if mine == generation {
                    pages[kind] = nil
                }
            }
            let (page, _) = await fetch {
                try await $0.page(query: query, kind: kind, offset: offset, limit: limit)
            }
            guard mine == generation, let page,
                  let index = groups.firstIndex(where: { $0.kind == kind }),
                  groups[index].offset + UInt32(groups[index].hits.count) == offset
            else { return }
            groups[index].hits += page.hits
            // An empty page means the server's total overcounted.
            groups[index].total = page.hits.isEmpty ? offset : max(page.total, offset + UInt32(page.hits.count))
        }
        pages[kind] = task
        return task
    }

    /// Asks the internal endpoint, then the fallback; returns the result and
    /// the internal endpoint's error, if it failed.
    private func fetch<T: Sendable>(
        _ request: @Sendable (any SearchServiceProtocol) async throws -> T
    ) async -> (T?, SearchError?) {
        let primaryError: SearchError
        do {
            return try await (request(primary), nil)
        } catch let error as SearchError {
            primaryError = error
        } catch {
            primaryError = .Request(message: String(describing: type(of: error)))
        }
        log(.warn, "Search failed: \(Self.summary(primaryError))")
        guard let fallback, !Task.isCancelled else { return (nil, primaryError) }
        do {
            return try await (request(fallback), primaryError)
        } catch {
            log(.warn, "Fallback search failed: \(String(describing: type(of: error)))")
            return (nil, primaryError)
        }
    }

    /// Error case names only: messages may carry server text.
    private static func summary(_ error: SearchError) -> String {
        switch error {
        case .Request: "Request"
        case .Malformed: "Malformed"
        }
    }
}
