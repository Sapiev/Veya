import Foundation
import Observation

/// Committed search queries, newest first, kept on this Mac only.
@MainActor
@Observable
public final class RecentSearches {
    public private(set) var queries: [String]

    public static let limit = 6
    public static let maxLength = 100

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "recentSearches"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        queries = (defaults.stringArray(forKey: Self.key) ?? []).compactMap(Self.normalised).prefix(Self.limit).map(\.self)
    }

    /// A pasted link keeps no query string (it can carry a `si=` share id); long text is cut.
    static func normalised(_ query: String) -> String? {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://"), let mark = text.firstIndex(of: "?") {
            text = String(text[..<mark])
        }
        text = String(text.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Moves `query` to the front, matching earlier entries case-insensitively.
    public func add(_ query: String) {
        guard let trimmed = Self.normalised(query) else { return }
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
