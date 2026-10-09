import Foundation
import os
import SpotCoreKit
import Testing

let storedBlob = Data("stored-SECRET-blob".utf8)
let refreshedBlob = Data("refreshed-SECRET-blob".utf8)
final class FakeStore: CredentialStore {
    struct Box {
        var blob: Data?
        var loadError: (any Error)?
        var saveError: (any Error)?
        var deleteError: (any Error)?
        var saves = 0
        var deletes = 0
    }

    private let box: OSAllocatedUnfairLock<Box>

    init(blob: Data? = nil, loadError: (any Error)? = nil, saveError: (any Error)? = nil) {
        box = OSAllocatedUnfairLock(initialState: Box(blob: blob, loadError: loadError, saveError: saveError))
    }

    func failDeletes(with error: (any Error)?) {
        box.withLock { $0.deleteError = error }
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
        try box.withLock { box in
            box.deletes += 1
            if let error = box.deleteError {
                throw error
            }
            box.blob = nil
        }
    }
}

final class FakeSession: SessionHandle {
    private struct Box {
        var blob: Data
        var shutdowns = 0
        var wakes = 0
        var reconnects = 0
        var network: [Bool] = []
        var observer: (any ConnectionObserver)?
    }

    private let box: OSAllocatedUnfairLock<Box>
    private let initial: ConnectionState?

    /// `initial` mimics spotcore delivering the current state on subscribe.
    init(blob: Data = refreshedBlob, initial: ConnectionState? = nil) {
        box = OSAllocatedUnfairLock(initialState: Box(blob: blob))
        self.initial = initial
    }

    var blob: Data {
        get { box.withLock { $0.blob } }
        set { box.withLock { $0.blob = newValue } }
    }

    var shutdownCount: Int {
        box.withLock { $0.shutdowns }
    }

    var wakes: Int {
        box.withLock { $0.wakes }
    }

    var network: [Bool] {
        box.withLock { $0.network }
    }

    var reconnects: Int {
        box.withLock { $0.reconnects }
    }

    func push(_ state: ConnectionState) {
        box.withLock { $0.observer }?.onStateChanged(state: state)
    }

    func storedCredentials() throws -> Data {
        blob
    }

    func shutdown() {
        box.withLock { $0.shutdowns += 1 }
    }

    func setObserver(observer: any ConnectionObserver) {
        box.withLock { $0.observer = observer }
        if let initial {
            observer.onStateChanged(state: initial)
        }
    }

    func systemDidWake() {
        box.withLock { $0.wakes += 1 }
    }

    func networkChanged(available: Bool) {
        box.withLock { $0.network.append(available) }
    }

    func reconnect() {
        box.withLock { $0.reconnects += 1 }
    }

    func makeLibrary(store _: MetadataStore?) -> any LibraryServiceProtocol {
        FakeLibrary()
    }

    func makeMetadata(store _: MetadataStore?) -> any MetadataServiceProtocol {
        FakeMetadata()
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
        var cacheLimits: [UInt64] = []
        var cacheLimitError: (any Error)?
        var metadataClears = 0
        var metadataClearError: (any Error)?
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())
    private let premium = OSAllocatedUnfairLock<Result<Bool, any Error>>(initialState: .success(true))

    /// Answered at once; the default lets every account through.
    func setPremium(_ result: Result<Bool, any Error>) {
        premium.withLock { $0 = result }
    }

    func isPremium(accessToken _: String) async throws -> Bool {
        try premium.withLock { $0 }.get()
    }

    var calls: [Credential] {
        box.withLock { $0.calls }
    }

    var pending: Int {
        box.withLock { $0.waiters.count }
    }

    var cacheLimits: [UInt64] {
        box.withLock { $0.cacheLimits }
    }

    func failCacheLimit(with error: any Error) {
        box.withLock { $0.cacheLimitError = error }
    }

    func setAudioCacheLimit(bytes: UInt64) throws {
        try box.withLock { box in
            if let error = box.cacheLimitError {
                throw error
            }
            box.cacheLimits.append(bytes)
        }
    }

    var metadataClears: Int {
        box.withLock { $0.metadataClears }
    }

    func failMetadataClear(with error: any Error) {
        box.withLock { $0.metadataClearError = error }
    }

    func clearMetadataCache() throws {
        try box.withLock { box in
            box.metadataClears += 1
            if let error = box.metadataClearError {
                throw error
            }
        }
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

let tokens = OAuthTokens(
    accessToken: "access-SECRET-1234",
    refreshToken: "refresh-SECRET-5678",
    expiresInSecs: 3600,
    scopes: ["streaming"]
)

@MainActor
final class LogSpy {
    var entries: [(LogLevel, String)] = []
    var log: SessionLog {
        { [self] in entries.append(($0, $1)) }
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 2000 where !condition() {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition())
}
