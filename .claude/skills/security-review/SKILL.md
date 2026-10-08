---
name: security-review
description: Use this skill when implementing the Spotify OAuth (PKCE) flow, storing or refreshing credentials/tokens, touching the Rust (spotcore) <-> Swift FFI boundary, making network calls to Spotify's API, parsing untrusted API/protocol data, or changing sandboxing/entitlements/code-signing. Provides a security checklist and patterns for a native macOS app.
---

# Security Review Skill

This skill ensures all code follows security best practices and identifies potential vulnerabilities, specifically for a native macOS Spotify client (Swift/SwiftUI app + Rust `core/spotcore` crate exposed via UniFFI).

## When to Activate

- Implementing or modifying the Spotify OAuth (PKCE) flow
- Storing, reading, or refreshing Spotify access/refresh tokens
- Adding or changing code at the Rust (`spotcore`) <-> Swift FFI boundary
- Parsing responses from Spotify's Web API or librespot-style protocol data
- Making network requests to Spotify or any other external service
- Changing App Sandbox entitlements, Hardened Runtime settings, code signing, or notarization
- Adding inter-process communication (XPC) between the UI and an audio engine process
- Adding or updating dependencies (Swift Package Manager or Cargo)

## Security Checklist

### 1. Secrets & Credential Management

#### FAIL: NEVER Do This
```swift
// FAIL: Spotify client secret embedded in shipped code
let clientSecret = "abc123supersecret"
```
```rust
// FAIL: secret baked into the Rust binary
const SPOTIFY_CLIENT_SECRET: &str = "abc123supersecret";
```

#### PASS: ALWAYS Do This
```swift
// PASS: Authorization Code + PKCE needs no client secret at all.
// The client ID is public and safe to ship; there is no secret to protect.
let clientId = "your-spotify-client-id"
```

#### Verification Steps
- [ ] No Spotify client secret embedded in shipped Swift or Rust code — PKCE does not require one, so its presence is a signal the wrong OAuth grant type was used
- [ ] No secrets in git history (check with `git log -p`, `gitleaks`, or `trufflehog`)
- [ ] No tokens, codes, or secrets ever written to debug or release logs
- [ ] Client ID and redirect URI may be public/committed; anything that actually needs to stay secret does not belong in the shipped app at all

### 2. Token Storage (macOS Keychain)

#### FAIL: NEVER Do This
```swift
// FAIL: tokens in UserDefaults — readable via plist, backups, iCloud sync
UserDefaults.standard.set(accessToken, forKey: "spotify_access_token")
```
```swift
// FAIL: tokens written to a plist or plain file on disk
try tokenData.write(to: tokensFileURL)
```

#### PASS: ALWAYS Do This
```swift
import Security

func storeToken(_ token: String, account: String) throws {
    let data = Data(token.utf8)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.veya.spotify",
        kSecAttrAccount as String: account,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
    ]
    SecItemDelete(query as CFDictionary)
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError.unableToStore(status) }
}
```

#### Verification Steps
- [ ] Access and refresh tokens stored only in the macOS Keychain (`Security`/Keychain Services, or a vetted wrapper) — never `UserDefaults`, plist files, JSON/config files, or app-support directories in plaintext
- [ ] An appropriate `kSecAttrAccessible` level is chosen deliberately, not left at a default that's more permissive than necessary
- [ ] Tokens are deleted from the Keychain on explicit sign-out
- [ ] Tokens are not duplicated into memory-mapped caches, crash reports, `NSUserActivity`/Handoff state, or Spotlight indexing

### 3. OAuth Flow Correctness

#### FAIL: NEVER Do This
```swift
// FAIL: implicit grant — token returned directly in the redirect URI fragment
let authURL = "https://accounts.spotify.com/authorize?response_type=token&client_id=\(clientId)&redirect_uri=\(redirectURI)"
```
```swift
// FAIL: no `state` parameter — any process that can trigger the redirect
// handler can inject a code/response as if it came from the real flow
```

#### PASS: ALWAYS Do This
```swift
// PASS: Authorization Code + PKCE, with `state` for CSRF-equivalent protection
let codeVerifier = generateCodeVerifier()      // random, kept only for this flow's lifetime
let codeChallenge = sha256Base64URL(codeVerifier)
let state = generateRandomState()              // persisted to verify on callback

var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
components.queryItems = [
    .init(name: "response_type", value: "code"),
    .init(name: "client_id", value: clientId),
    .init(name: "redirect_uri", value: redirectURI),
    .init(name: "code_challenge_method", value: "S256"),
    .init(name: "code_challenge", value: codeChallenge),
    .init(name: "state", value: state)
]
```
```swift
// PASS: validate scheme and state before exchanging the code
func handleCallback(url: URL) throws {
    guard url.scheme == expectedCustomScheme else { throw AuthError.unexpectedScheme }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let returnedState = items.first(where: { $0.name == "state" })?.value,
          returnedState == pendingState else {
        throw AuthError.stateMismatch  // possible hijacked/forged callback
    }
    // ... exchange code for tokens using codeVerifier
}
```

#### Verification Steps
- [ ] Authorization Code + PKCE flow used — not the deprecated implicit grant
- [ ] `state` generated per-flow, held in memory for the duration of the flow, and strictly compared against the value returned on callback before exchanging the code
- [ ] Redirect handling accounts for the custom-URL-scheme attack surface: another locally installed app can register the same scheme and may receive (or forge) the callback; prefer a loopback redirect (`http://127.0.0.1:<port>/callback`) with a per-flow random token, or at minimum treat `state` validation as mandatory if a custom scheme is used
- [ ] `code_verifier` is never persisted beyond the single auth flow (not written to disk, not logged)
- [ ] Authorization code is exchanged immediately and not reused
- [ ] Token refresh happens over HTTPS using the refresh token only — no client secret required or sent

### 4. FFI Boundary Safety (Rust `spotcore` <-> Swift)

#### FAIL: NEVER Do This
```rust
// FAIL: unwrap() on parsing untrusted network bytes — panics propagate
// across the FFI boundary as undefined behavior from Swift's perspective
let track = serde_json::from_slice::<Track>(&bytes).unwrap();
```
```rust
// FAIL: unsafe block with no comment justifying the invariant upheld
unsafe { std::mem::transmute(buf) }
```

#### PASS: ALWAYS Do This
```rust
// PASS: fallible parsing; errors cross the boundary as a typed Result
pub fn parse_track(bytes: &[u8]) -> Result<Track, SpotCoreError> {
    serde_json::from_slice(bytes).map_err(|e| SpotCoreError::Parse(e.to_string()))
}

// PASS: catch panics at exported entry points so they can't unwind into Swift
#[uniffi::export]
pub fn decode_frame(data: Vec<u8>) -> Result<Frame, SpotCoreError> {
    std::panic::catch_unwind(|| decode_frame_inner(&data))
        .unwrap_or(Err(SpotCoreError::InternalPanic))
}
```

#### Verification Steps
- [ ] Every UniFFI-exported function that parses network or protocol data returns `Result`, never panics on malformed input
- [ ] Panics cannot unwind across the FFI boundary (`catch_unwind` at exported entry points, or an explicit, understood `panic = "abort"` policy)
- [ ] Any `unsafe` Rust block carries a comment justifying the invariant it upholds; no `unsafe` used where a safe alternative exists
- [ ] Buffers/strings crossing the boundary are bounds- and UTF-8/length-validated before use on either side
- [ ] Swift call sites handle UniFFI error results explicitly rather than force-unwrapping (`try!`) values derived from network data

### 5. Network & TLS

#### FAIL: NEVER Do This
```swift
// FAIL: unconditionally trusting the server, defeating certificate validation
func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
}
```

#### PASS: ALWAYS Do This
```swift
// PASS: default system trust evaluation, HTTPS only, no custom delegate overriding it
var request = URLRequest(url: spotifyAPIURL)
let (data, response) = try await URLSession.shared.data(for: request)
```

#### Verification Steps
- [ ] All Spotify Web API calls use `https://` — no `http://` fallback
- [ ] No `URLSessionDelegate` unconditionally accepts server trust or self-signed certificates, even behind a "debug only" flag that could ship accidentally
- [ ] App Transport Security is not weakened via `NSAllowsArbitraryLoads` in `Info.plist`
- [ ] Any direct Rust-side network/protocol connections (e.g. librespot-style) use a maintained TLS stack with default certificate validation — no `danger_accept_invalid_certs` or equivalent in release builds

### 6. Input Validation (Untrusted Spotify API / librespot Data)

#### FAIL: NEVER Do This
```swift
// FAIL: force-casting an external response's shape
let track = json["track"] as! [String: Any]
let name = track["name"] as! String
```

#### PASS: ALWAYS Do This
```swift
// PASS: decode into typed, optional-safe models; fail closed on mismatch
struct Track: Decodable {
    let name: String
    let durationMs: Int?
}
do {
    let track = try JSONDecoder().decode(Track.self, from: data)
} catch {
    log.error("Failed to decode track response") // no raw body/token logged
    // fail closed rather than proceeding with partial/garbage state
}
```

#### Verification Steps
- [ ] All Spotify Web API responses are decoded through typed models (`Codable`/`Decodable`) rather than force-cast dictionaries
- [ ] Rust-side protocol/librespot parsing treats all server bytes as untrusted: length-prefixed fields are bounds-checked, enum/variant tags validated before use — "it's Spotify's own server" is not a reason to skip validation
- [ ] Malformed or unexpected responses fail gracefully into an error state rather than crashing the app or corrupting playback/session state
- [ ] Non-happy-path responses from Spotify's API (pagination edges, rate limiting/429, error-shaped JSON) are explicitly handled

### 7. macOS Sandboxing, Entitlements & Code Signing

#### Verification Steps
- [ ] App Sandbox enabled with the minimum entitlements needed (e.g. `com.apple.security.network.client` for outbound Spotify API calls); no broader entitlement (file system access, network server, etc.) than the feature set requires
- [ ] Hardened Runtime enabled; any exceptions (e.g. disabling library validation) are justified and minimized
- [ ] If distributed outside the Mac App Store: builds are code-signed with a valid Developer ID and notarized — unsigned/ad-hoc builds are not shipped to users
- [ ] Custom URL scheme (if used for the OAuth callback) is as specific as reasonably possible, to reduce collision risk with another locally installed app registering the same scheme
- [ ] Keychain access group/entitlement is scoped to this app, not shared broadly

### 8. Local IPC / XPC (if the audio engine runs out-of-process)

#### Verification Steps
- [ ] XPC services validate the connecting process (code-signing requirement / audit token check) rather than trusting any local connection
- [ ] Messages between the UI process and the audio engine process are schema-validated, not passed as raw/unvalidated blobs
- [ ] No tokens or secrets are passed over IPC in plaintext if avoidable; the data crossing the boundary is minimized
- [ ] XPC service entitlements are scoped as tightly as the main app's

### 9. Logging Hygiene

#### FAIL: NEVER Do This
```swift
print("Access token: \(accessToken)")
os_log("Spotify response: %{public}@", responseBody)
```

#### PASS: ALWAYS Do This
```swift
os_log("Token refresh succeeded", log: .default, type: .info)
os_log("Spotify API error: %{public}d", log: .default, type: .error, statusCode)
```

#### Verification Steps
- [ ] Access/refresh tokens, authorization codes, and `code_verifier` values are never logged, at any log level including debug
- [ ] Full Spotify API response bodies are not logged where they may contain user-identifying data (playlists, listening history) — log status codes/identifiers instead
- [ ] `os_log` arguments carrying sensitive data are marked `%{private}@`, not `%{public}@`
- [ ] Rust `log`/`tracing` output is reviewed the same way — no tokens or raw response bodies in `debug!`/`trace!` statements that could end up in a shipped build's diagnostics

### 10. Dependency Supply Chain (Swift Package Manager + Cargo)

#### Verification Steps
- [ ] `Package.resolved` committed for Swift Package Manager; `Cargo.lock` committed for `core/spotcore` — builds are reproducible
- [ ] `cargo audit` run (locally and/or in CI) and clean, especially for crates touching crypto, networking, or audio decoding
- [ ] Unmaintained or single-maintainer crates avoided on security-sensitive paths (TLS, PKCE/crypto helpers, protocol parsing); prefer well-known crates (e.g. rustls, ring/aws-lc-rs)
- [ ] Swift package dependencies pinned to specific versions/tags, not floating branches
- [ ] Dependabot or equivalent enabled on both the Swift and Rust dependency graphs

## Security Testing

### Example Tests
```swift
// Tokens must never land in UserDefaults
func testTokensNotInUserDefaults() {
    let defaults = UserDefaults.standard
    XCTAssertNil(defaults.string(forKey: "spotify_access_token"))
    XCTAssertNil(defaults.string(forKey: "spotify_refresh_token"))
}

// OAuth callback must reject a mismatched state
func testCallbackRejectsStateMismatch() {
    let flow = OAuthFlow(state: "expected-state")
    XCTAssertThrowsError(try flow.handleCallback(url: callbackURL(state: "attacker-state")))
}
```

```rust
// Malformed protocol bytes must not panic
#[test]
fn parse_track_rejects_malformed_bytes() {
    let garbage = b"\xff\xfe\x00not json";
    assert!(parse_track(garbage).is_err());
}

// FFI entry points must not unwind on internal panics
#[test]
fn decode_frame_does_not_unwind_on_panic() {
    let result = decode_frame(vec![]); // exercises the internal panic path
    assert!(result.is_err());
}
```

## Pre-Release Security Checklist

Before ANY build is shipped to users:

- [ ] **Secrets**: No Spotify client secret in shipped code; no secrets in git history
- [ ] **Token Storage**: Access/refresh tokens live only in the Keychain — never UserDefaults/plist/files
- [ ] **OAuth**: PKCE flow (not implicit), `state` validated on callback, redirect URI/scheme risk considered
- [ ] **FFI Safety**: No panics unwind across the Rust/Swift boundary; `unsafe` blocks are justified
- [ ] **Network**: HTTPS enforced everywhere; no disabled certificate validation
- [ ] **Input Validation**: Spotify API and librespot-protocol data parsed defensively, fails closed on malformed input
- [ ] **Sandboxing**: App Sandbox + Hardened Runtime enabled with minimal entitlements
- [ ] **Code Signing**: Signed with Developer ID and notarized (if distributed outside the App Store)
- [ ] **IPC/XPC**: Inter-process messages validated if the audio engine runs out-of-process
- [ ] **Logging**: No tokens, codes, or sensitive response bodies logged at any level
- [ ] **Dependencies**: `cargo audit` clean, lock files committed, no unmaintained crates on security-sensitive paths

## Resources

- [Spotify Web API Authorization Guide (PKCE)](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [UniFFI Documentation](https://mozilla.github.io/uniffi-rs/)
- [RustSec Advisory Database / cargo-audit](https://rustsec.org/)

---

**Remember**: Security is not optional. A compromised token grants an attacker ongoing access to a user's Spotify account, and a crash at the FFI boundary is a memory-safety bug, not just a bad user experience. When in doubt, err on the side of caution.
