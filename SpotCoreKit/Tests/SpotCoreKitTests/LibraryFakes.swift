import Foundation
import os
import SpotCoreKit

/// Writes, held refreshes and change waits block until the test releases them.
final class FakeLibrary: LibraryServiceProtocol {
    private struct Box {
        var cached: [LibraryKind: [LibraryItem]] = [:]
        var server: [LibraryKind: [LibraryItem]] = [:]
        var refreshError: (any Error)?
        var holdRefreshes = false
        var refreshes: [LibraryKind] = []
        var heldRefreshes: [CheckedContinuation<Void, Never>] = []
        var writes: [(uri: String, saved: Bool)] = []
        var heldWrites: [CheckedContinuation<Void, any Error>] = []
        var changeWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    init(cached: [LibraryKind: [LibraryItem]] = [:], server: [LibraryKind: [LibraryItem]] = [:]) {
        box.withLock {
            $0.cached = cached
            $0.server = server
        }
    }

    func setServer(_ items: [LibraryItem], for kind: LibraryKind) {
        box.withLock { $0.server[kind] = items }
    }

    func failRefreshes(with error: (any Error)?) {
        box.withLock { $0.refreshError = error }
    }

    func holdRefreshes() {
        box.withLock { $0.holdRefreshes = true }
    }

    var refreshes: [LibraryKind] {
        box.withLock { $0.refreshes }
    }

    var heldRefreshCount: Int {
        box.withLock { $0.heldRefreshes.count }
    }

    func releaseRefreshes() {
        let held = box.withLock { box in
            defer { box.heldRefreshes = []; box.holdRefreshes = false }
            return box.heldRefreshes
        }
        held.forEach { $0.resume() }
    }

    var writes: [(uri: String, saved: Bool)] {
        box.withLock { $0.writes }
    }

    func finishWrite(_ index: Int, error: (any Error)? = nil) {
        let waiter = box.withLock { $0.heldWrites[index] }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    var changeWaiters: Int {
        box.withLock { $0.changeWaiters.count }
    }

    func pushChange() {
        let waiters = box.withLock { box in
            defer { box.changeWaiters = [] }
            return box.changeWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func cached(kind: LibraryKind) -> [LibraryItem] {
        box.withLock { $0.cached[kind] ?? [] }
    }

    /// Answers with the server state as of the call, as a request in flight would.
    func refresh(kind: LibraryKind) async throws -> [LibraryItem] {
        var answer: Result<[LibraryItem], any Error> = .success([])
        await withCheckedContinuation { continuation in
            let (hold, result) = box.withLock { box in
                box.refreshes.append(kind)
                if box.holdRefreshes { box.heldRefreshes.append(continuation) }
                let result: Result<[LibraryItem], any Error> =
                    box.refreshError.map { .failure($0) } ?? .success(box.server[kind] ?? [])
                return (box.holdRefreshes, result)
            }
            answer = result
            if !hold { continuation.resume() }
        }
        return try answer.get()
    }

    func setSaved(uri: String, saved: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            box.withLock { box in
                box.writes.append((uri, saved))
                box.heldWrites.append(continuation)
            }
        }
    }

    func waitForChange() async {
        await withCheckedContinuation { continuation in
            box.withLock { $0.changeWaiters.append(continuation) }
        }
    }
}

final class FakeMetadata: MetadataServiceProtocol {
    private let requests = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    private let held = OSAllocatedUnfairLock<[CheckedContinuation<Void, Never>]>(initialState: [])

    var requested: [[String]] {
        requests.withLock { $0 }
    }

    var pending: Int {
        held.withLock { $0.count }
    }

    func release() {
        let waiters = held.withLock { waiters in
            defer { waiters = [] }
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func items(uris: [String]) async throws -> [MetadataItem] {
        await withCheckedContinuation { continuation in
            requests.withLock { $0.append(uris) }
            held.withLock { $0.append(continuation) }
        }
        return uris.map { .unavailable(uri: $0, error: .notFound) }
    }
}
