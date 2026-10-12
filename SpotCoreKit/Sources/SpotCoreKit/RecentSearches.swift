import Foundation
import Observation

/// Committed search queries, newest first, kept on this Mac only.
@MainActor
@Observable
public final class RecentSearches {
    public private(set) var queries: [String]

    public static let limit = 6

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "recentSearches"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        queries = defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Moves `query` to the front, matching earlier entries case-insensitively.
    public func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        queries.insert(trimmed, at: 0)
        queries = Array(queries.prefix(Self.limit))
        defaults.set(queries, forKey: Self.key)
    }

    public func remove(_ query: String) {
        queries.removeAll { $0 == query }
        defaults.set(queries, forKey: Self.key)
    }

    public func clear() {
        queries = []
        defaults.removeObject(forKey: Self.key)
    }
}
