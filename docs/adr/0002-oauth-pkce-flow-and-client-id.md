# ADR-002: OAuth PKCE flow in spotcore and the Client ID choice

- Status: Accepted
- Date: 2026-10-08

## Context

PBI-101 signs the user in through Spotify's own login page with the
Authorization Code + PKCE grant. The app never sees the password. Two
decisions are needed:

1. Which code runs the PKCE flow.
2. Which Spotify Client ID the app authenticates as.

### Flow implementation

The plan assumed librespot's `OAuthClient` (`librespot-oauth`). At the
pinned revision (`d36f9f1`) it has four problems:

- It never returns the authorize URL. It prints the URL to stdout or opens it
  with the `open` crate, so the app cannot hand it to
  `ASWebAuthenticationSession`.
- It generates a CSRF `state` but discards it and never checks it on the
  callback. Any local process that reaches the loopback port first can inject
  its own authorization code (login CSRF).
- The loopback listener is a blocking `std::net::TcpListener` inside an
  `async fn`. Login cannot be cancelled, and the listener blocks a tokio
  worker thread while it waits.
- It logs the full token response at `trace` level.

Options considered:

1. **Own flow in `spotcore` on the `oauth2` 5.0 crate**, which librespot
   already depends on. `spotcore` builds the authorize URL, validates
   `state`, and runs a cancellable tokio loopback listener.
2. **Fork `librespot-oauth`** and patch it. This adds a fork to rebase every
   time we track librespot `dev`.
3. **Use `OAuthClient` unchanged.** This drops `ASWebAuthenticationSession`,
   offers no cancel, and leaves the CSRF gap open.

### Client ID

Options considered:

1. **librespot's shared "keymaster" Client ID**
   (`65b708073fc0480ea92a077233ca87bd`). Its registered redirect is
   `http://127.0.0.1:8898/login`. It is the only practical way to get the
   `streaming` scope, which playback needs.
2. **A user-supplied Client ID** from the user's own Spotify developer app.
   Spotify does not grant `streaming` to custom IDs, so playback would not
   work.
3. **A Veya-registered Client ID.** This has the same `streaming`
   limitation as option 2.

## Decision

- `spotcore` implements the PKCE flow itself on `oauth2` (option 1). Swift
  calls `LoginFlow.start(config:)`, opens `authorizeUrl()` in an
  `ASWebAuthenticationSession`, and awaits `finish()`. When `finish()`
  returns, Swift closes the session.
- The listener binds `127.0.0.1` only. It ignores callbacks with a missing
  or mismatched `state`, so a local process cannot abort or hijack the flow.
  Request heads are size-bounded and time-limited.
- The default Client ID is the shared keymaster ID on port 8898. The ID and
  port travel through `OAuthConfig`, so a user-supplied ID can be added in
  Settings later without touching the flow.
- Scopes are the minimum for streaming, library and playlist read/modify,
  plus `user-read-private` for the Premium and region check (PBI-105):
  `streaming`, `user-read-private`, `user-library-read`,
  `user-library-modify`, `playlist-read-private`,
  `playlist-read-collaborative`, `playlist-modify-private`,
  `playlist-modify-public`.

## Consequences

- We own about one module of OAuth code and its tests. `oauth2` still handles
  the PKCE and token-exchange details.
- The shared ID can be rate-limited or revoked (see the risk table in the
  plan). If that happens, we change the default in `OAuthConfig` or surface
  the user-supplied ID option. The flow code stays the same.
- Port 8898 is fixed by the shared ID's registration. If another app holds
  the port, sign-in fails with a clear `PortInUse` error instead of picking a
  different port.
- `librespot-oauth` is no longer on the login path.
