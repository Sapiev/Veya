# Good and Bad Tests

Primitives, by layer:

- **Swift Testing** (the modern default for new code — Swift 6 / Xcode 16+, Apple's replacement for XCTest): `import Testing`, `@Test`, `#expect(...)`, `#require(...)`, and traits like `.disabled("reason")`.
- **XCTest** (still a reasonable choice, especially for UI tests or anything needing `measure {}`): `import XCTest`, `XCTestCase` subclasses, `XCTAssertEqual`/`XCTAssertTrue`/`XCTAssertThrowsError`, `XCTSkip`.
- **Rust**: `#[test]` functions, usually inside a `#[cfg(test)] mod tests` block next to the code they cover; `assert!`, `assert_eq!`, `assert_ne!`, `#[should_panic]`; run with `cargo test`.

Pick one Swift framework per target and stay consistent. Swift Testing and XCTest can coexist in the same scheme, but mixing them inside a single test file is not worth the confusion.

## Good Tests

**Integration-style**: test through real interfaces, not mocks of internal parts.

```swift
import Testing

// GOOD: tests observable behavior through the view model, not the view
@Test("queuing a track makes it playable next")
func queueingAddsTrackToUpNext() async throws {
    let viewModel = PlayerViewModel(client: FakeSpotifyClient())
    try await viewModel.enqueue(trackID: "abc123")
    #expect(viewModel.upNext.map(\.id) == ["abc123"])
}
```

```rust
// GOOD: tests observable behavior through the public API
#[test]
fn resuming_after_pause_keeps_the_playback_position() {
    let mut player = Player::new(FakeAudioBackend::default());
    player.seek(Duration::from_secs(30));

    player.pause();
    player.resume();

    assert_eq!(player.position(), Duration::from_secs(30));
}
```

Characteristics:

- Tests behavior callers care about
- Uses the public API only
- Survives internal refactors
- Describes WHAT, not HOW
- One logical assertion per test

## Bad Tests

**Implementation-detail tests**: coupled to internal structure.

```swift
import XCTest

// BAD: tests implementation details
func test_enqueue_callsQueueAppend() {
    let queue = SpyPlaybackQueue()
    let viewModel = PlayerViewModel(queue: queue)
    viewModel.enqueue(trackID: "abc123")
    XCTAssertEqual(queue.appendCallCount, 1)
}
```

```rust
// BAD: tests implementation details
#[test]
fn enqueue_calls_queue_push() {
    let queue = SpyQueue::default();
    let mut player = Player::with_queue(&queue);
    player.enqueue(&[track_a()]);
    assert_eq!(queue.push_call_count(), 1);
}
```

Red flags:

- Mocking or spying on internal collaborators
- Testing private methods or functions
- Asserting on call counts or call order
- Test breaks when refactoring without behavior change
- Test name describes HOW, not WHAT

## Verifying through the interface, and the one exception

**Default: verify through the interface.** Reaching into a private field or internal store to confirm something the public interface already reports couples the test to internal layout for no gain.

```rust
// BAD: reaches past the interface to check a private field
#[test]
fn enqueue_adds_to_internal_storage() {
    let mut player = Player::new(FakeAudioBackend::default());
    player.enqueue(&[track_a()]);
    assert_eq!(player.queue.len(), 1); // `queue` is a private field
}

// GOOD: verifies through the interface
#[test]
fn enqueue_makes_the_track_playable_next() {
    let mut player = Player::new(FakeAudioBackend::default());
    player.enqueue(&[track_a()]);
    assert_eq!(player.up_next().first().map(|t| t.id.clone()), Some(track_a().id));
}
```

**The qualification, and it matters here.** Assert on raw serialized bytes only when those bytes are themselves the published contract that an external party will re-derive. In that case the encoded value is not an implementation detail: it is the artifact under test, and checking it through a friendlier read path would be checking the wrong thing.

That is exactly the situation for anything crossing the wire in librespot's protocol, or anything written to a cache or file format that another process (or a future version of this app) will read back independently: a serialized Mercury/protobuf request, an encrypted frame, a cache key derived from a track URI. Spotify's servers (or your own future code) reconstruct these from the raw bytes and nothing else. A test that only round-trips through your own encoder and decoder would pass even if the wire format had drifted from what the other side actually expects.

```rust
// GOOD, and deliberately not a round-trip through your own decoder: the
// encoded bytes ARE the contract the other side parses. Check them against
// a frozen vector captured from a real exchange, not your own encoder's output.
#[test]
fn encodes_the_login_request_the_server_expects() {
    let request = build_login_request(&VECTOR_CREDENTIALS);
    assert_eq!(request.encode_to_vec(), LOGIN_REQUEST_VECTOR_BYTES);
}
```

The test for whether an assertion on encoded or stored bytes is legitimate: **would an external party re-derive this exact byte sequence independently?** Yes means the bytes are the contract, assert on them. No means you are inspecting internal layout, so go through the interface instead.

The two rules compose rather than conflict. Even when asserting on encoded bytes, the expected value still may not come from the implementation: rebuild it from a frozen vector or an independently constructed message, never by calling the same function the code under test uses to build it.

## Tautological tests

The expected value restates the implementation, so the test passes by construction.

```rust
// BAD: expected value is recomputed the way the code computes it
#[test]
fn cache_key_hashes_the_track_uri() {
    let expected = sha256(format!("track:{TRACK_URI}"));
    assert_eq!(cache_key(TRACK_URI), expected);
}

// GOOD: expected value is an independent, frozen literal
#[test]
fn cache_key_hashes_the_track_uri() {
    assert_eq!(cache_key(TRACK_URI), "9f86d081884c7d659a2feaa0c55ad015"); // frozen vector
}
```

Frozen vectors are checked in once, reviewed as data, and never regenerated by the code under test. If a vector changes, that is a deliberate, reviewed protocol change, not a test fix.

## Property-based tests for parsing and protocol logic

Hand-written examples are not enough coverage for anything that parses untrusted or wire-format input — track and album metadata, Mercury/protobuf frames, anything coming off the network before it is validated. For that code, add `proptest` alongside the example-based tests in `core/spotcore`:

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn parsing_never_panics_on_arbitrary_bytes(bytes in proptest::collection::vec(any::<u8>(), 0..256)) {
        let _ = parse_track_metadata(&bytes); // should return a Result, never panic
    }
}
```

Property-based tests complement, not replace, the frozen-vector tests above: the frozen vectors pin exact expected output for known-good input, while `proptest` searches for inputs that break an invariant (no panics, round-trips survive, lengths stay bounded) across a far larger input space than anyone would write by hand.
