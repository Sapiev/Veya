import Foundation
import os
import SpotCoreKit

let storedBlob = Data("stored-SECRET-blob".utf8)
let refreshedBlob = Data("refreshed-SECRET-blob".utf8)
final class FakeStore: CredentialStore {
    struct Box {
        var blob: Data?
        var loadError: (any Error)?
        var saveError: (any Error)?
        var saves = 0
        var deletes = 0
    }

    private let box: OSAllocatedUnfairLock<Box>

    init(blob: Data? = nil, loadError: (any Error)? = nil, saveError: (any Error)? = nil) {
        box = OSAllocatedUnfairLock(initialState: Box(blob: blob, loadError: loadError, saveError: saveError))
    }

    var blob: Data? {
        box.withLock { $0.blob }
    }

    var saves: Int {
        box.withLock { $0.saves }
    }

    var deletes: Int {
        box.withLock { $0.deletes }
    }

    /// Simulates another writer.
    func replace(with blob: Data?) {
        box.withLock { $0.blob = blob }
    }

    func load() throws -> Data? {
        try box.withLock { box in
            if let error = box.loadError {
                throw error
            }
            return box.blob
        }
    }

    func save(_ blob: Data) throws {
        try box.withLock { box in
            box.saves += 1
            if let error = box.saveError {
                throw error
            }
            box.blob = blob
        }
    }

    func delete() throws {
        box.withLock { box in
            box.deletes += 1
            box.blob = nil
        }
    }
}

final class FakeSession: SessionHandle {
    private let shutdowns = OSAllocatedUnfairLock(initialState: 0)
    let blob: Data

    init(blob: Data = refreshedBlob) {
        self.blob = blob
    }

    var shutdownCount: Int {
        shutdowns.withLock { $0 }
    }

    func storedCredentials() throws -> Data {
        blob
    }

    func shutdown() {
        shutdowns.withLock { $0 += 1 }
    }
}

enum Credential: Equatable {
    case token(String)
    case stored(Data)
}

/// Each connect waits until the test resolves it, in call order.
final class FakeConnector: SessionConnector {
    private struct Box {
        var calls: [Credential] = []
        var waiters: [CheckedContinuation<any SessionHandle, any Error>] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var calls: [Credential] {
        box.withLock { $0.calls }
    }

    var pending: Int {
        box.withLock { $0.waiters.count }
    }

    func connect(accessToken: String) async throws -> any SessionHandle {
        try await wait(.token(accessToken))
    }

    func connect(storedCredentials: Data) async throws -> any SessionHandle {
        try await wait(.stored(storedCredentials))
    }

    private func wait(_ credential: Credential) async throws -> any SessionHandle {
        try await withCheckedThrowingContinuation { continuation in
            box.withLock { box in
                box.calls.append(credential)
                box.waiters.append(continuation)
            }
        }
    }

    func resolve(_ index: Int, with result: Result<any SessionHandle, any Error>) {
        let waiter = box.withLock { $0.waiters[index] }
        waiter.resume(with: result)
    }
}
