import Foundation
import Observation

public enum SearchState: Equatable, Sendable {
    case idle
    case searching
    case loaded
    /// Both the service and the fallback, if any, failed.
    case failed
    /// No Web API token: the user's own client ID is not connected.
    case notConnected
}

/// Fetches a fresh access token for every request, since the provider caches it.
public final class WebAPISearch: SearchServiceProtocol {
    private let accessToken: @Sendable () async throws -> String

    public init(accessToken: @escaping @Sendable () async throws -> String) {
        self.accessToken = accessToken
    }

    public func search(query: String, limit: UInt32) async throws -> [SearchGroup] {
        try await SearchService(accessToken: accessToken()).search(query: query, limit: limit)
    }

    public func page(query: String, kind: SearchKind, offset: UInt32, limit: UInt32) async throws -> SearchGroup {
        try await SearchService(accessToken: accessToken()).page(query: query, kind: kind, offset: offset, limit: limit)
    }
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
    /// Why the service failed for the current query; set even when the
    /// fallback provider answered instead.
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

    /// `fallback`, if any, is used only when `service` fails.
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
            self.failure = failure.flatMap { $0 as? SearchError }
            if let result {
                groups = result
                state = .loaded
            } else {
                groups = []
                state = failure is WebAPITokenError ? .notConnected : .failed
            }
        }
        running = task
        return task
    }

    /// Whether "See all" can load more of `kind`.
    public func hasMore(_ kind: SearchKind) -> Bool {
        guard let group = groups.first(where: { $0.kind == kind }) else { return false }
        return group.resumeOffset < group.total
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
        let offset = group.resumeOffset
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
                  groups[index].resumeOffset == offset
            else { return }
            groups[index].hits += page.hits
            groups[index].nextOffset = page.nextOffset
            // An empty page means the server's total overcounted.
            groups[index].total = page.hits.isEmpty ? offset : max(page.total, page.nextOffset != 0 ? page.nextOffset : offset + UInt32(page.hits.count))
        }
        pages[kind] = task
        return task
    }

    /// Asks the service, then the fallback; returns the result and the
    /// service's error, if it failed. A missing token is not worth a fallback.
    private func fetch<T: Sendable>(
        _ request: @Sendable (any SearchServiceProtocol) async throws -> T
    ) async -> (T?, (any Error)?) {
        let primaryError: SearchError
        do {
            return try await (request(primary), nil)
        } catch let error as WebAPITokenError {
            log(.info, "Search needs a Web API connection: \(error)")
            return (nil, error)
        } catch let error as SearchError {
            primaryError = error
        } catch {
            if Self.isCancellation(error) {
                return (nil, error)
            }
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

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Error case names only: messages may carry server text.
    private static func summary(_ error: SearchError) -> String {
        switch error {
        case .Unauthorized: "Unauthorized"
        case .Forbidden: "Forbidden"
        case .RateLimited: "RateLimited"
        case .Request: "Request"
        case .Malformed: "Malformed"
        }
    }
}

private extension SearchGroup {
    /// The server's next offset when the core reports one (it skips unparseable hits), else after the hits we hold.
    var resumeOffset: UInt32 {
        nextOffset != 0 ? nextOffset : offset + UInt32(hits.count)
    }
}
