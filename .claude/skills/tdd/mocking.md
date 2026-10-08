# When to Mock

Mock at **system boundaries** only:

- External APIs (Spotify's Accounts/Web API, the librespot connection to Spotify's backend)
- Time and randomness
- File system (sometimes — on-disk caches, downloaded artwork)
- Local persistence (rarely, and only once it is genuinely slow: see below)

Do not mock:

- Your own modules
- Internal collaborators
- Anything you control

## Prefer a real boundary to a mock

When the real boundary runs locally and fast, run it. A mock of something you could have run is a second implementation you now have to keep honest, and it will drift.

**The Rust core is the example.** Logic that lives in `core/spotcore` — track metadata parsing, queue state, session configuration, anything wrapping librespot — should be exercised by calling the real Rust function in a `cargo test`, not by mocking what the Rust layer would return in a Swift-level test. That means the real parsing, validation and state logic runs on every test, a refactor inside the Rust core does not touch a single Swift test, and the UniFFI-generated bindings stay a thin, boring seam instead of something tests route around. Do not introduce a Swift-side fake that reimplements Rust-core behavior just to avoid calling the real crate.

If Veya grows a local on-disk cache (library metadata, downloaded artwork, playback history), prefer running tests against a real temporary SQLite database or a real temp directory over mocking the persistence layer, for the same reason: schema, constraints and on-disk layout get exercised for free, and a storage refactor does not touch the tests.

Spotify's network API is the opposite case and is correctly faked: it is a real external system, so tests inject a fake client that returns canned responses, and assertions run against those canned responses rather than against the network.

## Neither language has a mocking framework — write the fake by hand

There is no `jest.mock`, `vi.fn`, `sinon`, or MSW equivalent in Swift or Rust. Mocking here means defining a small interface for the boundary — a Swift `protocol`, a Rust `trait` — and writing one plain type per test scenario that implements it. That is strictly more code than `jest.mock("./client")`, and that is the point: the fake is visible, typed, and reviewable instead of generated magic that can silently drift from the real interface.

### Swift: protocol-based fakes

```swift
protocol SpotifySessionClient {
    func refreshAccessToken() async throws -> AccessToken
}

struct FakeSessionClient: SpotifySessionClient {
    var tokenToReturn: AccessToken = .fixture()
    func refreshAccessToken() async throws -> AccessToken { tokenToReturn }
}

struct FailingSessionClient: SpotifySessionClient {
    func refreshAccessToken() async throws -> AccessToken { throw AuthError.expired }
}
```

Inject the protocol, not the concrete client, so a test can substitute `FakeSessionClient` or `FailingSessionClient` without touching the real network stack.

### Rust: trait-based fakes

```rust
trait TokenProvider {
    fn refresh_access_token(&self) -> Result<AccessToken, AuthError>;
}

struct FakeTokenProvider(AccessToken);

impl TokenProvider for FakeTokenProvider {
    fn refresh_access_token(&self) -> Result<AccessToken, AuthError> {
        Ok(self.0.clone())
    }
}
```

Same idea: the function under test takes `&dyn TokenProvider` (or a generic `impl TokenProvider`), and the test passes a `FakeTokenProvider` instead of the real `SpotifyAuthClient`.

### Intercepting HTTP specifically

- **Swift**: don't fake at the `URLSession` call-site; subclass `URLProtocol`, register it on a `URLSessionConfiguration`, and intercept requests at the transport layer so the real `URLSession` and request-building code still run. Reach for this when code talks to `URLSession` directly; prefer the protocol-based fake above for anything already behind your own client type.
- **Rust**: define a trait for the HTTP client (for example `SpotifyHttpClient` with a `get`/`post` method) and inject it wherever the core talks to Spotify's Web API, so tests supply a fake implementation that returns canned JSON or protobuf instead of making a real request.

## Designing for Mockability

At system boundaries, design interfaces that are easy to fake.

**1. Use dependency injection**

Pass external dependencies in rather than constructing them internally:

```swift
// Easy to fake: the collaborator is injected
func startPlayback(trackID: String, sessionClient: SpotifySessionClient) async throws {
    let token = try await sessionClient.refreshAccessToken()
    // ...
}

// Hard to fake: the collaborator is constructed inside the function
func startPlayback(trackID: String) async throws {
    let sessionClient = SpotifyAccountsClient(clientID: Config.clientID)
    let token = try await sessionClient.refreshAccessToken()
    // ...
}
```

```rust
// Easy to fake: behavior lives behind a trait, passed in
fn start_playback(track_id: &str, tokens: &dyn TokenProvider) -> Result<(), PlaybackError> {
    let token = tokens.refresh_access_token()?;
    // ...
}

// Hard to fake: the dependency is constructed inside the function
fn start_playback(track_id: &str) -> Result<(), PlaybackError> {
    let tokens = SpotifyAuthClient::new(CLIENT_ID);
    let token = tokens.refresh_access_token()?;
    // ...
}
```

**2. Prefer SDK-style interfaces over generic fetchers**

Create a specific method for each external operation instead of one generic method with conditional logic:

```swift
// GOOD: each method is independently fakeable
protocol SpotifyCatalogClient {
    func fetchTrack(id: String) async throws -> Track
    func fetchAlbum(id: String) async throws -> Album
    func fetchArtist(id: String) async throws -> Artist
}

// BAD: faking requires conditional logic inside the fake
protocol SpotifyCatalogClient {
    func fetch(resource: String, id: String) async throws -> Any
}
```

The SDK approach means:

- Each fake returns one specific shape
- No conditional logic in test setup
- Easier to see which external calls a test exercises
- Type safety per operation (Swift) / per function (Rust)
