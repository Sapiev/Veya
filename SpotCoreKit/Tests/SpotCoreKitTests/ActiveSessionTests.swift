import Foundation
import SpotCoreKit
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ActiveSessionTests {
    private let connector = FakeConnector()
    private let defaults = UserDefaults(suiteName: "ActiveSessionTests")!
    private let made = Counter()

    private func model() -> SessionModel {
        SessionModel(store: FakeStore(blob: storedBlob), refreshTokenStore: FakeStore(), connector: connector) { _, _ in }
    }

    private func active(_ session: SessionModel) -> ActiveSession {
        let settings = PlaybackSettings(defaults: defaults)
        return ActiveSession(session: session, controls: MediaControls(artworkLoader: nil, commands: nil) { _, _ in }) { [made] in
            made.value += 1
            return SessionScope(
                handle: $0,
                metadataStore: nil,
                settings: settings,
                accessToken: { "" },
                episodeProgress: WebAPIEpisodeProgress { "" }
            ) { _ in false }
        }
    }

    private func connect(_ session: SessionModel, to handle: FakeSession, call: Int) async throws {
        let task = session.restore()
        try await waitUntil { connector.pending == call + 1 }
        connector.resolve(call, with: .success(handle))
        await task.value
    }

    @Test func noScopeUntilASessionIsReady() {
        let session = model()
        let active = active(session)

        #expect(active.scope == nil)
        #expect(active.current == nil)
        #expect(made.value == 0)
    }

    @Test func readySessionGetsOneScopeForItsHandle() async throws {
        let session = model()
        let active = active(session)
        let handle = FakeSession()

        try await connect(session, to: handle, call: 0)
        try await waitUntil { active.current != nil }

        #expect(active.current?.handle === handle)
        #expect(made.value == 1)
    }

    @Test func signOutDropsTheScope() async throws {
        let session = model()
        let active = active(session)
        try await connect(session, to: FakeSession(), call: 0)
        try await waitUntil { active.current != nil }

        try session.signOut()

        #expect(active.current == nil)
        try await waitUntil { active.scope == nil }
        #expect(made.value == 1)
    }

    @Test func aNewSessionReplacesTheScope() async throws {
        let session = model()
        let active = active(session)
        try await connect(session, to: FakeSession(), call: 0)
        try await waitUntil { active.current != nil }
        let first = active.current

        let second = FakeSession()
        try await connect(session, to: second, call: 1)
        try await waitUntil { active.current?.handle === second }

        #expect(active.current !== first)
        #expect(made.value == 2)
    }

    @Test func signOutReportsAFailureOnTheNextTurn() async throws {
        let store = FakeStore(blob: storedBlob)
        store.failDeletes(with: CacheError.Io(message: "locked"))
        let session = SessionModel(store: store, refreshTokenStore: FakeStore(), connector: connector) { _, _ in }
        let failed = Counter()

        session.signOut { failed.value += 1 }

        #expect(failed.value == 0)
        try await waitUntil { failed.value == 1 }
        #expect(session.state == .signedOut)
    }

    @Test func cleanSignOutReportsNothing() async throws {
        let session = model()
        let failed = Counter()

        session.signOut { failed.value += 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(failed.value == 0)
        #expect(session.state == .signedOut)
    }
}

@MainActor
private final class Counter {
    var value = 0
}
