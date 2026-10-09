import Foundation
import Observation

extension LibraryKind {
    init?(uri: String) {
        switch uri.split(separator: ":").dropFirst().first {
        case "track": self = .tracks
        case "album": self = .albums
        case "artist": self = .artists
        case "show": self = .shows
        default: return nil
        }
    }
}

public enum LibraryLoadState: Equatable, Sendable {
    /// Nothing to show yet; the first sync is running.
    case loading
    case loaded
    /// The sync failed and there was nothing cached.
    case failed
}

/// A save or unsave the server refused; the list is back as it was.
public struct LibrarySaveFailure: Equatable, Sendable {
    public let uri: String
    public let saved: Bool
}

public typealias LibraryLog = @MainActor (LogLevel, String) -> Void

/// The user's saved tracks, albums and artists, newest first.
///
/// Writes are optimistic. Toggles of one URI made while its write is in
/// flight coalesce into the next write, and syncs never override a URI with
/// a write pending, so the list always shows the user's latest intent.
@MainActor
@Observable
public final class LibraryModel {
    public private(set) var items: [LibraryKind: [LibraryItem]] = [:]
    public private(set) var loadState: [LibraryKind: LibraryLoadState] = [:]
    public private(set) var metadata: [String: MetadataItem] = [:]
    /// URIs whose last lookup failed; `resolve` tries them again.
    public private(set) var unresolved: Set<String> = []
    public var saveFailure: LibrarySaveFailure?
    private var saved: Set<String> = []

    private struct PendingWrite {
        /// The item as the server last confirmed it; nil when not saved.
        var confirmed: LibraryItem?
        var task: Task<Void, Never>?
    }

    @ObservationIgnored private let library: any LibraryServiceProtocol
    @ObservationIgnored private let metadataService: any MetadataServiceProtocol
    @ObservationIgnored private let log: LibraryLog
    @ObservationIgnored private var resolving: Set<String> = []
    @ObservationIgnored private var writes: [String: PendingWrite] = [:]
    @ObservationIgnored private var refreshes: [LibraryKind: Int] = [:]
    /// Bumped when a write lands; a sync that overlapped one may predate it.
    @ObservationIgnored private var landedWrites: [LibraryKind: Int] = [:]

    public init(
        library: any LibraryServiceProtocol,
        metadata: any MetadataServiceProtocol,
        log: @escaping LibraryLog = { logMessage(level: $0, category: "library", message: $1) }
    ) {
        self.library = library
        metadataService = metadata
        self.log = log
    }

    /// Shows the cached list at once, then syncs with the server.
    @discardableResult
    public func load(_ kind: LibraryKind) -> Task<Void, Never> {
        if loadState[kind] == nil {
            let cached = library.cached(kind: kind)
            publish(cached, for: kind)
            loadState[kind] = cached.isEmpty ? .loading : .loaded
        }
        return Task { await refresh(kind) }
    }

    /// Refreshes every loaded kind whenever the library changes elsewhere; runs until cancelled.
    public func watch() async {
        while !Task.isCancelled {
            await library.waitForChange()
            guard !Task.isCancelled else { return }
            for kind in [LibraryKind.tracks, .albums, .artists, .shows] where loadState[kind] != nil {
                await refresh(kind)
            }
        }
    }

    public func isSaved(_ uri: String) -> Bool {
        saved.contains(uri)
    }

    @discardableResult
    public func setSaved(_ uri: String, _ saved: Bool) -> Task<Void, Never>? {
        guard let kind = LibraryKind(uri: uri) else {
            log(.warn, "Can't save an unsupported URI")
            return nil
        }
        guard isSaved(uri) != saved else { return writes[uri]?.task }
        let before = item(uri, in: kind)
        var list = items[kind] ?? []
        list.removeAll { $0.uri == uri }
        if saved {
            list.insert(LibraryItem(uri: uri, addedAt: Int64(Date.now.timeIntervalSince1970)), at: 0)
        }
        publish(list, for: kind)
        if let running = writes[uri]?.task { return running }
        writes[uri] = PendingWrite(confirmed: before)
        let task = Task { await flush(uri, kind) }
        writes[uri]?.task = task
        return task
    }

    /// Fetches metadata for URIs neither known nor already requested.
    @discardableResult
    public func resolve(_ uris: [String]) -> Task<Void, Never>? {
        var missing: [String] = []
        for uri in uris where metadata[uri] == nil && !resolving.contains(uri) {
            resolving.insert(uri)
            missing.append(uri)
        }
        guard !missing.isEmpty else { return nil }
        let service = metadataService
        return Task {
            defer { resolving.subtract(missing) }
            do {
                let found = try await service.items(uris: missing)
                for (uri, item) in zip(missing, found) {
                    metadata[uri] = item
                }
                unresolved.subtract(missing)
            } catch {
                unresolved.formUnion(missing)
                log(.warn, "Couldn't load metadata for \(missing.count) items: \(Self.summary(error))")
            }
        }
    }

    /// Writes until the server matches the latest toggle; on failure restores what it last confirmed.
    private func flush(_ uri: String, _ kind: LibraryKind) async {
        while let write = writes[uri] {
            let wanted = item(uri, in: kind)
            guard (wanted != nil) != (write.confirmed != nil) else { break }
            do {
                try await library.setSaved(uri: uri, saved: wanted != nil)
                writes[uri]?.confirmed = wanted
                landedWrites[kind, default: 0] += 1
            } catch {
                log(.warn, "Couldn't update the library: \(Self.summary(error))")
                var list = items[kind] ?? []
                list.removeAll { $0.uri == uri }
                if let confirmed = write.confirmed {
                    list.insert(confirmed, at: list.firstIndex { $0.addedAt < confirmed.addedAt } ?? list.endIndex)
                }
                publish(list, for: kind)
                saveFailure = LibrarySaveFailure(uri: uri, saved: wanted != nil)
                break
            }
        }
        writes[uri] = nil
    }

    private func refresh(_ kind: LibraryKind) async {
        refreshes[kind, default: 0] += 1
        let mine = refreshes[kind]
        do {
            var fresh: [LibraryItem]
            var landed: Int?
            repeat {
                landed = landedWrites[kind]
                fresh = try await library.refresh(kind: kind)
            } while landed != landedWrites[kind]
            guard mine == refreshes[kind] else { return }
            let pending = (items[kind] ?? []).filter { writes[$0.uri] != nil }
            fresh.removeAll { writes[$0.uri] != nil }
            for item in pending {
                fresh.insert(item, at: fresh.firstIndex { $0.addedAt < item.addedAt } ?? fresh.endIndex)
            }
            publish(fresh, for: kind)
            loadState[kind] = .loaded
        } catch {
            log(.warn, "Couldn't sync the library: \(Self.summary(error))")
            guard mine == refreshes[kind], loadState[kind] == .loading else { return }
            loadState[kind] = .failed
        }
    }

    private func item(_ uri: String, in kind: LibraryKind) -> LibraryItem? {
        items[kind]?.first { $0.uri == uri }
    }

    private func publish(_ list: [LibraryItem], for kind: LibraryKind) {
        saved.subtract(items[kind]?.map(\.uri) ?? [])
        saved.formUnion(list.map(\.uri))
        items[kind] = list
    }

    /// Error case names only: messages may carry server text.
    private static func summary(_ error: any Error) -> String {
        switch error {
        case LibraryError.UnsupportedUri: "UnsupportedUri"
        case LibraryError.Request: "Request"
        default: String(describing: type(of: error))
        }
    }
}
