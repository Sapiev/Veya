# Native macOS Spotify Client (librespot) — Plan & PBIs

Oct 7, 2026 · @Jacob

## Vision and constraints

Working name: **Veya**. A native SwiftUI/AppKit Spotify client for macOS 14+, open source, with playback powered by [librespot](https://github.com/librespot-org/librespot) v0.8.x (Rust, MIT) and no web view anywhere. Target: idle RAM under 120 MB, cold launch under 1 s on Apple silicon, full keyboard and VoiceOver support.

**Goals for 1.0**

- Sign in with Spotify (OAuth PKCE), Premium accounts only.
- Browse library: playlists, liked songs, albums, artists, podcasts.
- Search, play, queue, shuffle/repeat, seek, volume, gapless playback.
- Spotify Connect: appear as a device, and control/transfer to other devices.
- macOS integration: Now Playing / media keys, menu bar mini-player, Dock menu, notifications, Shortcuts/AppleScript.
- Lyrics, playlist editing, offline-friendly caching of metadata and artwork.

**Non-goals**

- Free-tier support (librespot requires Premium for playback).
- Downloading or exporting audio for offline use (DRM; would breach Spotify terms and get the project taken down).
- Ad blocking, Windows/Linux builds, iOS (possible later; keep the core portable).

**Key facts that shape the design**

- The official desktop app is built on the Chromium Embedded Framework (CEF), not Electron; the goal (no web runtime) is the same either way.
- librespot v0.8.0 is the latest release. It changed many core APIs from `SpotifyId` to a new `SpotifyUri` type and added basic local-file playback and a `transfer` method for Connect ([release notes](https://github.com/librespot-org/librespot/releases)). v0.7.0 set the MSRV to Rust 1.85 (edition 2024) and added an `OAuthClient` builder for login.
- librespot is an unofficial, reverse-engineered client. Spotify can break it at any time, and its use is not sanctioned by Spotify's terms. This is the project's biggest risk (see Risks).
- The public Web API is effectively closed to an open-source client of this kind. Since February 2026, Development Mode requires the app owner to hold Premium, allows one Client ID per developer and **five authorized users per Client ID**, and narrows the endpoint set ([Spotify blog](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security), [migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)). Search `limit` dropped from 50 to 10. Extended quota requires an organization with 250k MAU.
- Consequence: **all metadata, library and search must go through librespot's internal `spclient`/dealer APIs**, not the Web API. The Web API is used only as an optional, user-supplied fallback ("bring your own Client ID" for personal use).

Prior art to study: [psst](https://github.com/jpochyla/psst) (Rust native GUI), spotify-player and ncspot (terminal clients on librespot).

## Architecture

The app is two layers: a thin Rust crate (`spotcore`) that wraps librespot and exposes a small, stable API, and a Swift app that never touches Spotify protocols directly.

&#91;embedded content: architecture · Swift app over one Rust core\]

Design rules:

- **One boundary.** Swift calls `spotcore` through UniFFI-generated bindings; everything crosses as plain records and enums. librespot types never leak into Swift, so librespot upgrades (like 0.8's `SpotifyUri` change) touch only Rust.
- **Audio stays native.** A custom librespot `Sink` writes PCM into a lock-free ring buffer drained by an `AVAudioEngine` source node (or an AudioUnit render callback). This gives correct device switching, sample-rate handling and AirPods behaviour, rather than relying on rodio/cpal defaults.
- **Events, not polling.** `spotcore` emits a single event stream (track changed, position, state, volume, Connect updates, session lost). Swift turns it into an `AsyncStream` that feeds `@Observable` stores on the main actor.
- **Web API is optional.** A `CatalogProvider` protocol has an spclient implementation (default) and a Web API implementation that only activates if the user enters their own Client ID.
- **Sandbox-friendly.** App Sandbox with network client/server entitlements (server for Connect zeroconf), hardened runtime, notarized.

## Tech stack, repo and governance

| Area         | Choice                                                                                                    | Why                                                |
| ------------ | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| UI           | SwiftUI (macOS 14+), AppKit where needed (window chrome, NSStatusItem, table views for 10k-row playlists) | Native look, low memory                            |
| Language     | Swift 6 strict concurrency                                                                                | Data-race safety across FFI events                 |
| Core         | Rust stable ≥ 1.85, librespot 0.8.x pinned by git rev                                                     | Matches librespot MSRV                             |
| Bindings     | UniFFI (Mozilla) with async support                                                                       | Generated Swift, no hand-written C                 |
| Build        | Xcode 16+ project; Rust built by a `cargo` build phase into an xcframework (universal)                    | One-button build in Xcode                          |
| Persistence  | SQLite via GRDB (Swift) for UI cache; Keychain for credentials                                            | Fast, testable                                     |
| Tests        | Swift Testing + XCUITest; `cargo test` + `cargo clippy`                                                   |                                                    |
| CI           | GitHub Actions, macOS runners: build, test, lint, notarize on tag                                         |                                                    |
| Distribution | Signed + notarized DMG on GitHub Releases, Sparkle 2 auto-update, Homebrew cask                           | No App Store (unofficial client would be rejected) |

**Repo layout**

```
veya/
  App/                 Xcode project, SwiftUI app target
  Packages/SpotCoreKit/ Swift package wrapping the xcframework
  core/spotcore/       Rust crate (librespot wrapper + UniFFI)
  scripts/             build-xcframework.sh, notarize.sh
  docs/                ARCHITECTURE.md, CONTRIBUTING.md, adr/
  .github/             workflows, issue + PR templates
```

**Licensing and governance**

- License: MIT (compatible with librespot's MIT; keeps the door open for downstream use). GPL-3.0 is the alternative if you want forks to stay open.
- No Spotify trademarks: no "Spotify" in the app name or icon, no green circle logo. README states it is unofficial and not affiliated with Spotify.
- Contributor files: CODE_OF_CONDUCT (Contributor Covenant), CONTRIBUTING, SECURITY.md, DCO sign-off on commits.
- Decisions recorded as ADRs in `docs/adr/`.

## Product backlog

54 PBIs across 10 epics, 223 story points in total. Estimates are story points (Fibonacci); priority is MoSCoW; milestone M0–M4 matches the roadmap. Every PBI also has to meet the Definition of Done at the end of this doc.

### E0 · Foundations

#### PBI-001 · Create repository and OSS scaffolding

**Story:** As a contributor, I want a well-organised public repo so that I can understand and contribute quickly.

**Priority:** Must · **Estimate:** 2 · **Milestone:** M0 · **Depends on:** none

**Status:** In progress - branch protection pending (repo has no GitHub remote yet).

- [x] Repo created with the layout in "Tech stack"; MIT LICENSE, README with "unofficial, not affiliated with Spotify" notice.
- [x] CONTRIBUTING, CODE_OF_CONDUCT, SECURITY.md, issue templates (bug, feature), PR template with DoD checklist.
- [ ] Branch protection on `main`: PR + 1 review + green CI.
- [x] ADR-001 records the Swift + Rust/UniFFI architecture decision.

#### PBI-002 · Rust core crate with librespot

**Story:** As a developer, I want a `spotcore` crate that compiles librespot for macOS so that the app has a playback engine to call.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M0 · **Depends on:** PBI-001

**Status:** Done (merged to `main`).

- [x] `core/spotcore` depends on librespot 0.8.x crates (core, playback, connect, metadata, oauth) pinned to a git rev.
- [x] Builds for `aarch64-apple-darwin` and `x86_64-apple-darwin` with the `rustls-tls` backend (no OpenSSL dependency).
- [x] Default librespot audio backends disabled; only our sink is compiled.
- [x] `cargo clippy -D warnings` and `cargo test` pass.

#### PBI-003 · UniFFI bindings and xcframework build

**Story:** As a Swift developer, I want generated Swift bindings in a Swift package so that I can call the core with async/await.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M0 · **Depends on:** PBI-002

**Status:** Done (merged to `main`).

- [x] `scripts/build-xcframework.sh` produces a universal static xcframework plus generated Swift sources.
- [x] `SpotCoreKit` Swift package wraps it; a sample `version()` call works from the app.
- [x] Xcode build phase rebuilds Rust only when `core/` changes (incremental build under 10 s when unchanged).
- [x] Async Rust functions surface as Swift `async throws`; Rust errors map to a Swift `SpotCoreError` enum.

#### PBI-004 · Xcode app skeleton

**Story:** As a developer, I want an empty SwiftUI app with sandbox and hardened runtime configured so that later features drop in cleanly.

**Priority:** Must · **Estimate:** 2 · **Milestone:** M0 · **Depends on:** PBI-003

**Status:** Done (merged to develop).

- [x] macOS 14 deployment target, Swift 6 language mode, strict concurrency complete.
- [x] Entitlements: App Sandbox, network client, network server (for Connect zeroconf), audio output. (Sandboxed playback needs no entitlement; only audio input has one.)
- [x] Debug and Release configs; `.xcconfig` files hold the bundle ID and team ID so forks can change them in one place.

#### PBI-005 · CI pipeline

**Story:** As a maintainer, I want every PR built and tested on macOS so that regressions are caught before merge.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M0 · **Depends on:** PBI-003, PBI-004

**Status:** Done (merged to develop) - pipeline timing unverified until the repo has a GitHub remote.

- [x] GitHub Actions on `macos-latest`: Rust build + clippy + tests, xcframework build, `xcodebuild test`. (Pinned to `macos-26`: the project needs Xcode 26.)
- [x] SwiftLint and SwiftFormat checks; rustfmt check.
- [ ] Cargo and SPM caches; PR pipeline under 15 minutes. (Caches in place; timing unverified until the first GitHub run.)
- [x] Dependabot for Cargo, SPM and Actions.

#### PBI-006 · Logging and diagnostics

**Story:** As a user filing a bug, I want an easy way to export logs so that maintainers can diagnose problems.

**Priority:** Should · **Estimate:** 2 · **Milestone:** M1 · **Depends on:** PBI-003

**Status:** Done (merged to develop).

**UI tests:** `DiagnosticsUITests` (Help menu item).

- [x] Rust `log`/`tracing` output bridged to `os.Logger` with subsystem per module. (Subsystem per crate, category per module path; trace is never enabled because librespot logs raw tokens there.)
- [x] Help › Export Diagnostics writes a zip of the last 24 h of logs with tokens and usernames redacted.
- [x] No telemetry is sent anywhere by default. (Documented in the README privacy section.)

## Risks, open questions and Definition of Done

| Risk                                                      | Likelihood                     | Impact                      | Mitigation                                                                                                                  |
| --------------------------------------------------------- | ------------------------------ | --------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Spotify changes its private protocol and librespot breaks | High (has happened repeatedly) | Playback down for all users | Track librespot `dev`; all librespot use isolated in `spotcore`; Sparkle lets fixes ship within a day; status banner in app |
| Spotify sends a takedown (ToS / trademark)                | Medium                         | Project removed from GitHub | No Spotify branding, no download/ripping features, Premium-only, clear disclaimer; mirror on Codeberg                       |
| Shared librespot Client ID gets rate-limited or revoked   | Medium                         | Login or metadata fails     | Abstract the Client ID; allow user-supplied ID; ADR with fallback plan                                                      |
| Internal search/home endpoints change shape               | Medium                         | Search or Home broken       | Contract tests against recorded fixtures; typed errors; graceful hiding                                                     |
| Account flagged for unofficial client use                 | Low                            | User account action         | Document the risk in FAQ; mimic normal client behaviour (no scraping, no bulk requests)                                     |
| FFI and audio-thread bugs (crashes, glitches)             | Medium                         | Poor first impression       | Lock-free ring buffer, Thread Sanitizer in CI, 1 h soak test before each release                                            |
| Small maintainer team, scope creep                        | High                           | Missed dates                | MoSCoW cut line: only Must items gate 1.0                                                                                   |

**Open questions**

- App icon, and a trademark/domain check for the name Veya.
- MIT vs GPL-3.0 for the app code.
- Minimum macOS: 14 (Observation, modern SwiftUI) vs 13 (wider reach).
- Whether to ship Intel (x86_64) builds at all in 2026–27.

**Definition of Done (applies to every PBI)**

- [ ] All acceptance criteria met and demoed on Apple silicon (and Intel if shipped).
- [ ] Code reviewed and merged via PR with green CI (build, tests, SwiftLint, clippy, rustfmt).
- [ ] Unit tests for new logic; UI test for new user-facing flows.
- [ ] No new accessibility warnings; all new strings in the String Catalog.
- [ ] No regression against the performance budget (PBI-803).
- [ ] Docs and CHANGELOG updated; ADR written for any architectural decision.

### E1 · Authentication and session

#### PBI-101 · Sign in with Spotify (OAuth PKCE)

**Story:** As a Premium user, I want to sign in through Spotify's own login page so that I never type my password into the app.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M1 · **Depends on:** PBI-003, PBI-004

**Status:** Done (merged to develop).

**UI tests:** `SignInUITests` (sign-in success, cancelled sign-in with retry).

- [x] PKCE flow in `spotcore` on the `oauth2` crate (librespot's `OAuthClient` cannot expose the URL or validate `state`; see ADR-002); the browser opens via `ASWebAuthenticationSession` and returns through a loopback redirect.
- [x] Scopes requested are the minimum needed for streaming, library and playlist read/modify.
- [x] Cancelling or failing login shows a clear error and a retry button.
- [x] Client ID choice (librespot's shared ID vs user-supplied) is recorded in an ADR, with the trade-offs.

#### PBI-102 · Store credentials and auto sign-in

**Story:** As a returning user, I want the app to remember me so that music is one click away after launch.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M1 · **Depends on:** PBI-101

**Status:** Done (merged to develop).

**UI tests:** `SessionUITests` (silent restore, failed restore with retry). Rejected-credential fallback is covered in `SpotCoreKitTests`.

- [ ] Reusable credentials are stored in the Keychain (access group scoped to the app), never on disk in plain text. (Stored in the legacy login keychain with a creator-only ACL; an access group needs a Team ID, see ADR-003 follow-up.)
- [x] On launch the app connects silently; if credentials are rejected it falls back to the sign-in screen.
- [x] Session is ready (able to play) within 2 s of launch on a normal connection. (Measured 631 ms restore against live Spotify.)

#### PBI-103 · Session lifecycle and reconnect

**Story:** As a user, I want playback to recover after sleep or a network drop so that I do not need to restart the app.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M2 · **Depends on:** PBI-102

**Status:** In progress (merged to develop) - the player restores the current track and position after a reconnect (ADR-004 item 7); dealer close and takeover wait on PBI-501.

**UI tests:** `SessionUITests` (reconnect banner), `SettingsUITests` (cache size footer). Track restore is tested in spotcore: `cargo test -p spotcore reconnect`. Takeover needs tests when built.

- [ ] `spotcore` detects dead sessions (access point timeout, dealer close) and reconnects with backoff (1, 2, 4 … 60 s). (Access point timeout and backoff done; dealer close waits on PBI-501, which starts the dealer.)
- [x] Listens to `NSWorkspace` wake notifications and `NWPathMonitor` to reconnect promptly.
- [ ] Current track and position are restored after reconnect; UI shows an "Offline – reconnecting" banner meanwhile. (Banner done; restore of track, position, play state, context and queue done in spotcore and unit-tested, not yet checked against a live reconnect.)
- [ ] Another device taking over the account ("playing elsewhere") pauses locally and informs the user. (Waits on the player and Connect dealer, PBI-202 and PBI-501.)

#### PBI-104 · Sign out and switch account

**Story:** As a user sharing a Mac, I want to sign out so that my account is not used by others.

**Priority:** Should · **Estimate:** 2 · **Milestone:** M2 · **Depends on:** PBI-102

**Status:** In progress (merged to develop) - sign out also stops playback (`SessionModel.attach` ties the player to its session) and clears the audio cache; every step is attempted and repeats are safe.

**UI tests:** `SignOutUITests` (Account menu, menu disabled when signed out). The placeholder signed-in screen and its Sign Out button were replaced by the app shell (PBI-401); Settings › Account has a Sign Out button again (PBI-407, `SettingsUITests`). Stopping playback has nothing new to see in the UI-test fakes (a new sign-in gets a new player), so it is covered by `SessionSignOutTests`.

- [ ] Account menu › Sign Out stops playback, clears Keychain items, metadata cache and audio cache. (All four wired, unit-tested in `SessionSignOutTests`; Swift not compiled or run: written in a Linux container.)
- [x] App returns to the sign-in screen without a relaunch.

#### PBI-105 · Premium and region checks

**Story:** As a Free-tier user, I want a clear message instead of silent failures so that I know why playback does not work.

**Priority:** Must · **Estimate:** 1 · **Milestone:** M1 · **Depends on:** PBI-101

**Status:** In progress (merged to develop) - region-locked tracks are dimmed with a tooltip and refuse to play in track lists, artist top tracks, Home Recently Played and the show page; the Premium check on restore still waits on ADR-005.

**UI tests:** `PremiumUITests` (Free account sees the explanation and signs out), `TrackListUITests` (region-locked row refuses to play and stays out of the queue).

- [ ] After login, the `product` user attribute is read; non-Premium accounts see an explanation screen and can sign out. (Done for fresh sign-in through Web API `/v1/me`; restore and reconnect still hit librespot's `exit(1)`, see ADR-005.)
- [ ] Tracks unavailable in the user's country are greyed out with a tooltip. (Done in track lists and artist top tracks; Swift not compiled or run: written in a Linux container. Search results carry no playability yet.)

### E2 · Playback engine

#### PBI-201 · Native CoreAudio sink

**Story:** As a listener, I want audio to go through macOS's native audio stack so that it sounds right and follows my output device.

**Priority:** Must · **Estimate:** 8 · **Milestone:** M1 · **Depends on:** PBI-002, PBI-003

**Status:** In progress - sink, ring, C render API and Swift engine merged to develop (ADR-006); listening and device checks wait on the player, PBI-202.

- [x] Rust implements librespot's `Sink` trait and writes 44.1 kHz stereo PCM (f32) into a lock-free SPSC ring buffer exposed over FFI.
- [x] Swift drains it from an `AVAudioSourceNode` render block with no allocations or locks on the audio thread.
- [ ] No audible glitches across 1 h of continuous playback; buffer underruns are logged and counted. (Underruns are counted and logged; the 1 h listening test needs the player, PBI-202.)
- [ ] Output follows the system default device when it changes (AirPods connect/disconnect) within 1 s. (Engine restarts on `AVAudioEngineConfigurationChange`; not yet checked on hardware, needs the player, PBI-202.)

#### PBI-202 · Player control API

**Story:** As a listener, I want play, pause, next, previous and seek to respond instantly so that the app feels native.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M1 · **Depends on:** PBI-201

**Status:** In progress - `SpotPlayer` merged to develop and driven from the app through SpotCoreKit `PlayerModel` (PBI-402); latency not yet measured with a real account (`examples/live_player.rs`).

- [x] `spotcore` exposes `load(uri, start_ms, autoplay)`, `play`, `pause`, `seek`, `next`, `previous`, `stop`.
- [x] Accepts track, episode, album, playlist and artist URIs via librespot 0.8's `SpotifyUri`.
- [ ] Play/pause takes effect within 100 ms; a new track starts within 1 s on broadband. (Needs a signed-in listening check; no app UI drives the player yet.)
- [x] Player events (playing, paused, track changed, position every 1 s, end of track, unavailable) are emitted on the event stream.

#### PBI-203 · Play queue, shuffle and repeat

**Story:** As a listener, I want to queue songs and use shuffle/repeat so that I control what plays next.

**Priority:** Must · **Estimate:** 8 · **Milestone:** M2 · **Depends on:** PBI-202

**Status:** In progress (merged to develop) - Settings › Playback has an Autoplay switch, persisted in `PlaybackSettings.autoplay` and applied to the player at creation and live.

- [x] Queue model holds context (album/playlist) tracks plus a user "Up Next" list, matching Spotify's semantics.
- [x] Play Next, Add to Queue, remove, reorder and clear are supported.
- [x] Shuffle and repeat (off / context / track) work together; previous within 3 s restarts the track.
- [ ] When the context ends, autoplay continues with radio for that context (can be switched off in Settings). (Radio and `set_autoplay` work in `spotcore`; the Settings switch is wired and tested in `PlayerModelTests` and `SettingsUITests`; Swift not compiled or run: written in a Linux container.)

#### PBI-204 · Gapless playback and preloading

**Story:** As an album listener, I want no gap between tracks so that live and classical albums play as intended.

**Priority:** Should · **Estimate:** 3 · **Milestone:** M2 · **Depends on:** PBI-203

**Status:** In progress - preloading merged to develop (`SpotPlayer` preloads `Queue::upcoming()` on librespot's `TimeToPreloadNextTrack`); listening check pending.

- [x] Next track is preloaded about 30 s before the current one ends.
- [ ] No gap or click between consecutive tracks of a gapless album (verified on a reference album list in the test plan). (No test plan or reference album list exists yet; needs a signed-in listening check via `examples/live_player.rs`.)

#### PBI-205 · Volume and loudness normalisation

**Story:** As a listener, I want consistent loudness between tracks so that I am not reaching for the volume.

**Priority:** Should · **Estimate:** 2 · **Milestone:** M2 · **Depends on:** PBI-201

**Status:** Done (merged to develop) - volume slider (PBI-402) and Normalize toggle with Loudness presets (PBI-407) already merged to develop; adds a UI test for the toggle and a VoiceOver name for the Loudness picker.

- [x] App volume slider (logarithmic curve) independent from system volume; persisted across launches.
- [x] Normalisation toggle with Quiet / Normal / Loud presets mapped to librespot's normaliser settings.

#### PBI-206 · Output device selection

**Story:** As a user with an audio interface, I want to pick the output device in the app so that music goes where I want regardless of system default.

**Priority:** Could · **Estimate:** 3 · **Milestone:** M3 · **Depends on:** PBI-201

**Status:** Done (merged to develop) - the Output device picker (PBI-407) and the saved device applied when the player starts (`SpotSession.makePlayer`) were already merged to develop; adds a UI test and a VoiceOver name for the picker.

- [x] Settings lists CoreAudio output devices and updates live as devices appear/disappear.
- [x] Selected device is remembered; falls back to system default if missing.

#### PBI-207 · Streaming quality and audio cache

**Story:** As a user on a metered connection, I want to choose streaming quality and cache size so that I control data and disk use.

**Priority:** Should · **Estimate:** 3 · **Milestone:** M2 · **Depends on:** PBI-202

**Status:** In progress (merged to develop) - quality and cache size pickers already merged with PBI-407; Settings › Storage gains a confirmed Clear Audio Cache button (`SessionModel.clearAudioCache`).

- [x] Quality options 96 / 160 / 320 kbps map to librespot bitrate settings; default 320.
- [ ] Audio file cache in the app's Caches container with a size cap (default 1 GB, LRU eviction) and a Clear Cache button. (Cache, cap and size picker done; the Clear Audio Cache button is wired and has a `SettingsUITests` test; Swift not compiled or run: written in a Linux container.)
- [x] Cached audio is encrypted as librespot stores it and is not exportable.

### E3 · Catalog and library

#### PBI-301 · Metadata service (tracks, albums, artists)

**Story:** As the UI, I want typed metadata for any Spotify item so that pages can render without knowing about protobufs.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M1 · **Depends on:** PBI-003

**Status:** Done (merged to `develop`).

- [x] `spotcore` fetches tracks, albums, artists and episodes via librespot-metadata / extended metadata, batched up to 100 URIs per request.
- [x] Returns flat UniFFI records (title, artists, album, duration, explicit, playable, artwork URLs by size). (`playable` is the `Playability` enum: playable, region-locked, not yet released.)
- [x] In-memory LRU (5,000 items) avoids duplicate requests within a session.
- [x] Errors for unavailable or region-locked items are typed, not generic.

#### PBI-302 · Artwork loading

**Story:** As a user, I want cover art to appear quickly and crisply so that browsing feels fast.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M1 · **Depends on:** PBI-301

**Status:** In progress - SpotCoreKit `ArtworkLoader` and app `ArtworkView` merged to develop; the frame-rate check waits on the first grid (PBI-303, PBI-304).

- [x] Swift image pipeline picks the smallest size that fits the view at the screen's backing scale.
- [x] Memory cache plus disk cache (default 300 MB, LRU) in Caches; downscaled thumbnails decoded off the main thread.
- [ ] Scrolling a 1,000-item grid stays at 60 fps on an M1 MacBook Air. (No grid exists yet: PBI-303, PBI-304.)

#### PBI-303 · User library: liked songs, saved albums, followed artists

**Story:** As a user, I want my liked songs, albums and artists in the sidebar so that my collection is where I expect it.

**Priority:** Must · **Estimate:** 8 · **Milestone:** M2 · **Depends on:** PBI-301

**Status:** In progress - `LibraryService` in `spotcore` (collection v2 paging, delta, write, disk cache, dealer push wait) and SpotCoreKit `LibraryModel` (optimistic saves with rollback, metadata lookup, change watch) merged to develop; Liked Songs screen in PBI-403; Albums and Artists screens pending.

- [ ] Collection is loaded through the spclient collection endpoints, paginated, and kept fresh via dealer push updates. (Done in `spotcore` `library.rs`; no app UI yet, and not yet checked against a live account.)
- [ ] Liking/unliking a track or saving an album updates the server and the UI optimistically, rolling back on error. (Server write in `LibraryService::set_saved`, optimistic update and rollback in `LibraryModel`; the now-playing bar and the track list context menu use them; not yet checked against a live account.)
- [ ] Liked Songs with 10,000 tracks loads its first screen in under 1 s from cache. (The cached 10,000-item list decodes in under 250 ms; track titles now come from the PBI-308 metadata store; the Liked Songs screen renders it (PBI-403), not yet timed against a live account.)

#### PBI-304 · Playlists (root list and contents)

**Story:** As a user, I want all my playlists and folders in the sidebar so that I can open any of them.

**Priority:** Must · **Estimate:** 8 · **Milestone:** M2 · **Depends on:** PBI-301

**Status:** In progress (merged to develop) - sidebar shows folders as a collapsible tree (`PlaylistModel.tree`, expansion kept per window) and the playlist page shows the follower count; root list and open playlist refresh on dealer push now have a unit test.

- [ ] Root list including folders is fetched (playlist4 protocol) and shown as a collapsible tree. (Tree wired, `NavigationUITests` covers expanding a folder; Swift not compiled or run: written in a Linux container.)
- [ ] Playlist contents load incrementally; owner, description, follower count and artwork are shown. (Follower count wired and covered in `DetailPagesUITests`; Swift not compiled or run: written in a Linux container; not checked against a live account.)
- [ ] Changes made on other devices appear within 10 s via dealer notifications. (`PlaylistModel.watch` refreshes the root list and open playlists on push, tested in `PlaylistPageTests`; Swift not compiled or run: written in a Linux container; delay not measured against a live account.)

#### PBI-305 · Search

**Story:** As a user, I want to search for songs, artists, albums, playlists and podcasts so that I can find anything to play.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M2 · **Depends on:** PBI-301

**Status:** In progress - `SearchService` in `spotcore` (`searchview/km/v4` over spclient, grouped results, per-type pages, typed `SearchError`) and `SearchModel` in SpotCoreKit (250 ms debounce, stale responses dropped, "See all" paging, fallback provider hook) merged to develop; search screen merged with PBI-405 (`SearchView`, `SessionHandle.makeSearch`); a Web API provider is still pending.

- [ ] Search uses the internal search endpoint via spclient (not the Web API, which caps dev-mode results at 10). (Superseded by PBI-309: `searchview/km/v4` now answers HTTP 400 for every request, so search moved to the Web API through the user's own client ID, 10 results per page.)
- [x] Queries are debounced (250 ms) and stale responses cancelled.
- [x] Results grouped by type with "See all" pagination per type. (Search screen shows a section per type with a Show More button that loads the next page, PBI-405.)
- [ ] If the internal endpoint fails, a typed error is shown and the optional Web API provider is used when configured. (`SearchModel.failure` is typed and a `fallback` provider is used when passed; the search screen shows the failure with Try Again (PBI-405); no Web API provider yet.)

#### PBI-309 · Web API through the user's own client ID

**Story:** As a user, I want Veya to call the Spotify Web API through my own developer app so that search, Recently Played and podcast resume points work despite the shared client ID being rate limited.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M2 · **Depends on:** PBI-305, PBI-306, PBI-307

**Status:** Done (merged to develop)

**UI tests:** `SearchUITests` (not connected asks to connect and opens Settings › Account, connecting there shows the pending query's results, rate limit message), `SettingsUITests` (invalid Client ID keeps Connect disabled, connected state shows Disconnect).

- [x] Search calls `GET /v1/search` with a bearer token from the user's own client ID, at most 10 results per type; results keep the URI kind check and `https`-only artwork; 401, 403 and 429 are typed errors (`cargo test -p spotcore search`).
- [x] Settings › Account › Spotify Web API takes a Client ID (32 hex characters, checked before connecting), explains the dashboard steps and the redirect URI `http://127.0.0.1:8898/login`, connects through PKCE, shows the status and disconnects; a new Client ID drops the old refresh token.
- [x] Search, Recently Played and episode progress use the own client's tokens (`WebAPIConnection`, `WebAPITokenProvider`); the main sign-in no longer keeps the shared client's refresh token, and launch deletes its stale Keychain item (safe to repeat).
- [x] Without a connection, Search shows a prompt whose button opens Settings › Account; a rate limit has its own message.
- [ ] Search, Recently Played and resume points work against a live account through a real developer app. (Not run: needs the user's own Client ID.)

#### PBI-306 · Podcasts and episodes

**Story:** As a podcast listener, I want to follow shows and resume episodes so that I can use one app for everything.

**Priority:** Should · **Estimate:** 5 · **Milestone:** M3 · **Depends on:** PBI-303

**Status:** In progress (merged to develop) - show page (`ShowPage`: header, episodes with release date, length, played and resume progress, selected episode's notes, Resume via `PlayerModel.play(_:startingAt:)`), episode release time in core; earlier: `LibraryKind::Shows`, `SHOW_V4` metadata, Web API resume points, SpotCoreKit `PodcastModel`, episode speed (ADR-007) and Web API token refresh merged to develop.

**UI tests:** `PodcastUITests` (followed show opens its page, episode date, length, played and resume state, selected episode's notes, Resume and Play from the start).

- [ ] Followed shows list, show page with episode list, episode detail with description. (Podcasts list, `ShowPage` and `PodcastUITests` written; Swift not compiled or run: written in a Linux container; episode list in `SHOW_V4` not yet checked live)
- [ ] Resume position syncs with Spotify; played state is shown. (played and resume state shown on the show page and Resume starts at the resume point, Swift not compiled or run: written in a Linux container; needs re-sign-in for sign-ins before this change; writing back relies on Spotify recording playback, unverified)
- [ ] Playback speed 0.8×–2× for episodes (if librespot cannot support speed, document and defer). (engine, setting and Settings › Playback › Podcast speed picker done, ADR-007; not yet listened to)

#### PBI-307 · Home and discovery

**Story:** As a user, I want a start page with recent plays and suggestions so that I have something to tap after launch.

**Priority:** Could · **Estimate:** 5 · **Milestone:** M3 · **Depends on:** PBI-303, PBI-304

**Status:** In progress (merged to develop) - `HomeView` shows the `HomeModel` sections as card rows, hides empty ones, and asks accounts without `user-read-recently-played` to sign in again (`HomeModel.recentlyPlayedNeedsSignIn`); `HomeUITests`.

- [ ] Home shows Recently Played, Jump Back In (recent contexts) and "Made for you" playlists available to the account. ("Made for you" is the Spotify-owned playlists in the root list because the Web API closed its browse endpoints to new apps; `HomeView` and `HomeUITests` written, Swift not compiled or run: written in a Linux container)
- [x] Artist and track radio via librespot's `get_radio_for_track`.
- [ ] Sections that cannot be fetched are hidden, not shown empty. (`HomeView` hides empty sections and shows a sign-in-again note for `MissingScope`; `HomeUITests`, Swift not compiled or run: written in a Linux container)

#### PBI-308 · Persistent metadata cache

**Story:** As a user, I want my library to appear instantly at launch so that I am not waiting on the network.

**Priority:** Should · **Estimate:** 5 · **Milestone:** M3 · **Depends on:** PBI-303, PBI-304

**Status:** In progress - metadata store merged to develop (ADR-008); Reset button in Settings › Storage (PBI-407); cache-first launch waits on library screens (PBI-401, PBI-403).

- [x] SQLite stores library, playlists and item metadata with revision IDs; schema migrations are versioned. (`rusqlite` in `spotcore` instead of GRDB, ADR-008; `MetadataStore` with `PRAGMA user_version` migrations.)
- [ ] Launch renders from cache first, then reconciles with the server (stale-while-revalidate). (Done in `spotcore` (`cached`, `cached_rootlist`, `cached_page`, metadata store reads) and `LibraryModel`; no app screen renders the library yet: PBI-401, PBI-403.)
- [x] Cache is cleared on sign-out and has a Reset button in Settings. (Settings › Storage › Reset Metadata Cache, with a confirmation; `SettingsUITests`.)

### E4 · User interface

#### PBI-401 · App shell and navigation

**Story:** As a Mac user, I want a standard three-part window (sidebar, content, now-playing bar) so that the app feels like it belongs on macOS.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M1 · **Depends on:** PBI-004

**Status:** In progress - merged to develop: `AppShell` (`NavigationSplitView`, sidebar from SpotCoreKit `PlaylistModel`), SpotCoreKit `NavigationHistory` and `Route`, Go menu and toolbar back/forward; each route shows a placeholder until its screen lands (PBI-403 onwards).

**UI tests:** `NavigationUITests` (sidebar destinations and playlists, playlist selection, ⌘\[ / ⌘\], toolbar buttons, Go menu disabled without history).

- [x] `NavigationSplitView` with sidebar sections: Home, Search, Library (Liked Songs, Albums, Artists, Podcasts), Playlists.
- [ ] Back/forward history with ⌘\[ and ⌘\], toolbar buttons and swipe gestures. (Keyboard and toolbar covered by `NavigationUITests`; trackpad swipe uses an `NSEvent` swipe monitor that XCUITest can't drive and is not yet checked on a trackpad.)
- [ ] Window size and sidebar width restored on relaunch; full-screen and Stage Manager work. (Window frame relies on SwiftUI's autosave and sidebar visibility is kept in `@SceneStorage`; sidebar width, full-screen and Stage Manager not checked by hand yet.)
- [ ] Light and dark mode, accent colour follows system. (System colours and materials only; not checked by eye in both appearances yet.)

#### PBI-402 · Now-playing bar

**Story:** As a listener, I want transport controls always visible so that I can control playback from any page.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M1 · **Depends on:** PBI-202, PBI-401

**Status:** In progress - merged to develop: SpotCoreKit `PlayerModel` (events from `SpotPlayer`, interpolated position, shuffle, repeat, persisted volume and output device) and `SessionHandle.makePlayer` (starts `AudioEngine` and `SpotPlayer`); app `NowPlayingBar` and expanded view. The track list starts playback since PBI-403.

**UI tests:** `NowPlayingUITests` (bar controls, play/pause, artist link opens the artist route, expanded view with lyrics tab).

- [x] Shows artwork, title, artists (each clickable), like button, play/pause, prev/next, shuffle, repeat, scrubber with elapsed/remaining, volume, queue and device buttons. (The queue button toggles a per-window flag that the PBI-406 inspector reads.)
- [ ] Scrubber updates smoothly (interpolated between 1 s position events) and seeks on release. (Interpolation is unit-tested in `PlayerModelTests` and the slider seeks only on release; not yet watched against live playback.)
- [x] Expanded "Now Playing" view with large artwork and lyrics tab (lyrics via PBI-701).

#### PBI-403 · High-performance track list

**Story:** As a user with large playlists, I want long track lists to scroll smoothly so that the app never stutters.

**Priority:** Must · **Estimate:** 8 · **Milestone:** M2 · **Depends on:** PBI-301, PBI-401

**Status:** In progress - merged to develop: app `TrackList` (SwiftUI `Table`) on Liked Songs; `SpotPlayer::load_tracks` in `spotcore` plays a list the app holds from a chosen row; SpotCoreKit `PlayerModel.play(_:from:context:)`, `playNext(_:)`, `addToQueue(_:)`.

- [x] Reusable list (SwiftUI `Table` or `NSTableView` wrapper) with columns #, Title/Artist, Album, Date added, Duration; sortable and resizable.
- [ ] 10,000 rows scroll at 60 fps; rows load metadata lazily as they appear. (Metadata resolves in batches of 50 as rows appear, and a 10,000-song library opens in a UI test. Frame rate not measured: XCUITest's accessibility snapshot of a table this size takes about 27 s per query, so it needs an Instruments run on an M1 MacBook Air.)
- [ ] Double-click or Return plays; multi-select; context menu (Play Next, Add to Queue, Add to Playlist, Go to Album/Artist, Copy Link, Like). (All done except Add to Playlist, which is shown disabled: `spotcore` has no playlist write API yet. Since PBI-404, Return plays the selection only in the list's own window and never while a text field is editing or a one-column list has focus.)
- [x] Currently playing row is highlighted; unavailable rows dimmed.
- [ ] Drag rows to sidebar playlists and to the queue. (Rows are drag sources carrying their URI and the queue panel (PBI-406) accepts them; the sidebar drop waits on a playlist write API.)

#### PBI-404 · Album, artist and playlist pages

**Story:** As a user, I want detail pages for albums, artists and playlists so that I can explore music.

**Priority:** Must · **Estimate:** 8 · **Milestone:** M2 · **Depends on:** PBI-403, PBI-302

**Status:** In progress - merged to `develop`; the 500 ms first paint is not yet timed on a real account.

- [x] Album: header (art, title, artist, year, track count, length), play/shuffle, tracks, copyright. (`spotcore` album metadata now carries the release year and copyright lines.)
- [x] Artist: header image, top tracks, discography grouped by albums/singles/compilations, related artists, follow button. (`spotcore` artist metadata now carries top tracks for the account's country, the three discography groups and related artists; the header image is the artist portrait.)
- [x] Playlist: header, description, owner, play/shuffle, filter field, track list. (Return in the filter field no longer plays the table selection: TrackList's Return handling now skips text editing and one-column lists and acts only in its own window.)
- [ ] Each page loads its first paint in under 500 ms from cache. (Cache first is in place: a fully stored playlist renders synchronously from `cachedPage` before any request returns (`PlaylistPageTests`), and album and artist lookups read the PBI-308 metadata store before the network. Not timed on a real account.)

#### PBI-405 · Search UI

**Story:** As a user, I want a fast search page so that results appear as I type.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M2 · **Depends on:** PBI-305, PBI-401

**Status:** Done (merged to `develop`).

- [x] ⌘F / ⌘L focuses the search field from anywhere. (Go > Search is ⌘F; ⌘L is a window shortcut; both open the Search route and focus its field.)
- [x] Top result plus sections per type; keyboard navigation through results; Return plays. (Up/Down move the selection while the field keeps focus, Return or double-click plays tracks and episodes; albums, playlists, artists and shows open their page, which offers play once PBI-404 lands.)
- [x] Recent searches stored locally and clearable. (SpotCoreKit `RecentSearches` in UserDefaults, newest first, de-duplicated, at most 6 per the design mockup; recorded on Return or opening a result; shown as chips, each removable, cleared by Clear all and on sign-out.)
- [x] Search page rebuilt to the design mockup: idle page with recent chips, Artists you follow and Browse all genres; filter chips (All, Songs, Artists, Albums, Playlists) with server counts, empty ones disabled; top result picked by the mockup's rule (`SearchResults`, `swift test --filter SearchResultsTests`); no-results page with suggestions; clear button and Esc in the field; More Options menu in the top bar. (Genre cards carry no album art and artist/album/playlist top results open their page instead of playing; see `shortcut:` notes.)

#### PBI-406 · Queue panel

**Story:** As a listener, I want to see and edit what's coming up so that I control the session.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M2 · **Depends on:** PBI-203, PBI-403

**Status:** In progress - merged to `develop`; drag to reorder is not yet checked by hand.

- [x] Inspector panel showing Now Playing, Next in Queue, Next From (context). (The bar's Queue button and View > Show Queue (⌥⌘I) toggle it; SpotCoreKit `PlayerModel` exposes `upNext`, `nextFromContext` and the `context` Veya last played from, refreshed on track changes and after every queue edit. "Next From" names the playlist, album, artist or show, else reads "Next Up". Track list rows dropped on the panel are added to the queue.)
- [ ] Drag to reorder, swipe/Delete to remove, Clear Queue. (Remove from the context menu, a swipe, or the Delete key, and Clear Queue are covered by `QueueUITests`. Reordering uses `List.onMove`, whose mapping onto the player's one-row moves is unit-tested (`PlayerModelTests`), but XCUITest could not drive the drag, so it needs a check by hand. Only Up Next can be edited: the player's remove and move act on the user queue, not the context.)

#### PBI-407 · Settings window

**Story:** As a user, I want a standard Settings window so that I can adjust playback, cache and account options.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M2 · **Depends on:** PBI-401

**Status:** In progress - merged to `develop`; Web API Client ID and proxy open (see below).

**UI tests:** `SettingsUITests` (⌘, opens every tab, a Playback choice survives reopening, Account › Sign Out, Reset Metadata Cache confirmation, Advanced log level). Persistence across relaunch: `PlaybackSettingsTests.choicesSurviveARelaunch`; live apply: `PlayerModelTests.settingsChangesReachTheLivePlayerOnce`.

- [x] SwiftUI `Settings` scene with tabs: General, Playback, Storage, Connect, Account, Advanced. (General and Connect say "No settings yet." until a setting exists for them; Connect device options come with E5.)
- [ ] Advanced tab: optional Web API Client ID, log level, proxy. (Log level done, applied at once. No Client ID field: per ADR-002 a user-supplied ID gets no `streaming` scope, and Web API calls reuse the sign-in token, so a separate ID needs its own OAuth flow first. No proxy: `spotcore` has no proxy setting yet.)
- [x] All settings persist via `@AppStorage` and are applied without restart where possible. (One `PlaybackSettings` shared by the player and the Settings window, stored in `UserDefaults`; the log level uses `@AppStorage`. Volume, output device, podcast speed, streaming quality, normalisation and log level apply at once; changing the audio cache size reconnects, which stops the current track.)

#### PBI-408 · Onboarding and empty states

**Story:** As a first-time user, I want a clear welcome screen so that I understand what I need (Premium) and how to sign in.

**Priority:** Should · **Estimate:** 2 · **Milestone:** M2 · **Depends on:** PBI-101

**Status:** Done (merged to `develop`).

- [x] Welcome screen explains the app is unofficial and needs Premium, with a single Sign In button.
- [x] Every list has a designed empty and error state (no blank pages). (Liked Songs, Albums, Artists, Podcasts, sidebar Playlists, Search and Recent Searches use `ContentUnavailableView` through `LoadStateView`/`FailedState`, with Try Again on failure. The playlist, album and artist pages (PBI-404) use `LoadStateView` for loading, unavailable and failed lookups; Home and the show page have no list yet and show their title until PBI-307 and PBI-306.)

### E5 · Spotify Connect

#### PBI-501 · Appear as a Connect device

**Story:** As a user, I want my Mac to show up in the Spotify app on my phone so that I can start music on it remotely.

**Priority:** Must · **Estimate:** 8 · **Milestone:** M3 · **Depends on:** PBI-103, PBI-203
**Status:** In progress (merged to develop) - ADR-009 hybrid: `SpotConnect` runs `Spirc` on a second session for the signed-in account beside the local player.

- [x] `spotcore` runs librespot-connect's `Spirc` with the signed-in session; device name defaults to the Mac's name (editable in Settings).
- [ ] Remote play, pause, seek, skip, volume and queue changes from the phone are reflected in the app UI within 1 s. (Player events, volume and cluster queue updates are wired and unit tested; not yet checked with a real phone.)
- [ ] Local actions update the remote device's view of the queue and position. (Transport, load, shuffle, repeat, volume and add to queue route to Spirc in Connect mode; play next, remove, reorder and clear return `ConnectQueueEdit` until a `set_queue` command lands; not yet checked with a real phone.)
- [x] Optional zeroconf discovery on the LAN (Settings toggle, off by default) using mDNS.

#### PBI-502 · Device picker and transfer playback

**Story:** As a user, I want to move playback between my Mac, speakers and phone so that music follows me.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M3 · **Depends on:** PBI-501
**Status:** In progress (merged to develop) - devices come from the Connect cluster listener; with nothing active, a transfer starts from this Mac's device so Spotify resumes the last session on the target.

- [x] Device popover lists the account's active Connect devices with type icons and volume.
- [ ] Selecting a device transfers playback (position and queue preserved); "This Mac" uses librespot 0.8's `Spirc::transfer`. (Routing is unit and UI tested on fakes; not yet checked against real devices. Local-mode playback is not published to Connect, so moving it elsewhere pauses it here and the target resumes Spotify's last session, not the local queue.)
- [x] List refreshes live via dealer cluster updates.

#### PBI-503 · Remote control mode

**Story:** As a user playing on a speaker, I want the app to act as a remote so that I can control the speaker from my Mac.

**Priority:** Should · **Estimate:** 5 · **Milestone:** M3 · **Depends on:** PBI-502
**Status:** In progress (merged to develop) - the cluster drives the bar; transport, load, shuffle, repeat, volume and add to queue go to the active device as connect-state commands.

- [ ] When another device is active, the now-playing bar shows "Playing on \<device>" and all controls command that device. (Label, routing and command bodies are tested on fakes; not yet checked with a real device. Play next, remove, reorder and clear return `ConnectQueueEdit`, as a `set_queue` built from the remote's uids and queue revision cannot be verified here.)
- [x] Local audio is not decoded while in remote mode (CPU near idle). (Unit level: entering Remote mode stops the local player and every call routes away from it; real CPU use not measured.)

### E6 · macOS integration

#### PBI-601 · Now Playing and media keys

**Story:** As a Mac user, I want media keys, AirPods taps and Control Center to work so that I can control music without the window.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M1 · **Depends on:** PBI-202

**Status:** Done (merged to develop)

- [x] `MPNowPlayingInfoCenter` shows title, artist, album, artwork, duration and elapsed time.
- [x] `MPRemoteCommandCenter` handles play/pause, next, previous, seek (change playback position) and like.
- [ ] Works when the app is in the background or its window is closed. (implemented; `MediaControlsUITests/testClosingTheWindowKeepsPlaying` not yet green on the dev Mac, where a third-party auto-quit utility quits windowless apps)

#### PBI-602 · Menu bar mini-player

**Story:** As a user, I want a menu bar mini-player so that I can control music without switching apps.

**Priority:** Should · **Estimate:** 3 · **Milestone:** M3 · **Depends on:** PBI-402

**Status:** Done (merged to develop)

- [x] `MenuBarExtra` with artwork, title, controls, scrubber and like; optional scrolling title in the menu bar.
- [x] Setting to keep the app running in the menu bar after closing the last window. ("Keep running in menu bar only"; verified by hand, the window-close UI tests need third-party auto-quit apps such as Vorssaint off)

#### PBI-603 · Dock menu and track notifications

**Story:** As a user, I want Dock controls and an optional notification on track change so that I always know what is playing.

**Priority:** Could · **Estimate:** 2 · **Milestone:** M3 · **Depends on:** PBI-202

**Status:** Done (merged to develop)

- [x] Dock menu: now playing, play/pause, next, previous, like.
- [x] Optional `UserNotifications` banner with artwork on track change (off by default). ("Notify when the song changes" in General; banner delivery itself verified by unit test with a fake poster, not in UI tests)

#### PBI-604 · Shortcuts and Siri (App Intents)

**Story:** As a power user, I want Shortcuts actions so that I can automate music (e.g. a focus-mode playlist).

**Priority:** Could · **Estimate:** 3 · **Milestone:** M4 · **Depends on:** PBI-202, PBI-304

**Status:** In progress (merged to develop)

- [x] Intents: Play/Pause, Next, Previous, Play Playlist (with playlist entity query), Like Current Track, Get Current Track. (Each waits up to 20 s for the player, so a shortcut can launch the app; tested on fakes, not yet against a live account.)
- [ ] Intents appear in the Shortcuts app and Spotlight. (All six intents, six App Shortcuts and the playlist entity are in the built app's App Intents metadata; not yet checked by hand in Shortcuts and Spotlight.)

#### PBI-605 · AppleScript support

**Story:** As an automation user, I want AppleScript commands compatible with common scripts so that tools like Raycast and Alfred work.

**Priority:** Could · **Estimate:** 3 · **Milestone:** M4 · **Depends on:** PBI-202

**Status:** Done (merged to develop)

- [x] Scripting definition (.sdef) with `playpause`, `next track`, `previous track`, `player state`, `current track` properties and `play track <uri>`. (Not yet checked with Raycast or Alfred.)
- [x] Documented in `docs/automation.md` with examples.

#### PBI-606 · Keyboard shortcuts and links

**Story:** As a keyboard user, I want full shortcut coverage and Spotify link handling so that I rarely need the mouse.

**Priority:** Should · **Estimate:** 2 · **Milestone:** M2 · **Depends on:** PBI-401

**Status:** Done (merged to develop)

- [x] Space play/pause, ⌘→/← next/previous, ⌘↑/↓ volume, ⌘S shuffle, ⌘R repeat, ⌘L search; listed in the Help menu.
- [x] Registers a custom URL scheme; File › Open Link accepts `open.spotify.com` and `spotify:` URIs (the app does not claim the `spotify:` scheme by default to avoid hijacking the official app). (`veya://<type>/<id>`; not yet checked against a live account.)

### E7 · Extra features

#### PBI-701 · Lyrics

**Story:** As a listener, I want time-synced lyrics so that I can sing along.

**Priority:** Should · **Estimate:** 5 · **Milestone:** M3 · **Depends on:** PBI-402

**Status:** Done (merged to develop)

- [x] Lyrics fetched through librespot's spclient lyrics support; synced lines highlight and auto-scroll with playback. (Not yet checked against a live account.)
- [x] Clicking a line seeks to it; unsynced lyrics show as static text; "No lyrics" state handled.

#### PBI-702 · Playlist editing

**Story:** As a curator, I want to create, rename and edit playlists so that I can manage my library without the official app.

**Priority:** Must · **Estimate:** 8 · **Milestone:** M3 · **Depends on:** PBI-304, PBI-403

**Status:** Done (merged to develop)

- [x] Create, rename, edit description, delete (unfollow), make public/private, create folders. (Not yet checked against a live account.)
- [x] Add, remove and reorder tracks (drag and drop) with optimistic UI and conflict handling on revision mismatch. (Not yet checked against a live account.)
- [x] Undo (⌘Z) for track removal and reorder.
- [x] New playlists ask for a name and optional description first; private playlists show a lock; the playlist photo can be changed. (Photo upload not yet checked against a live account.)

#### PBI-703 · Local files

**Story:** As a user with my own MP3/FLAC files, I want them in my playlists so that one app plays everything.

**Priority:** Could · **Estimate:** 5 · **Milestone:** M4 · **Depends on:** PBI-202, PBI-304

**Status:** Done (merged to develop)

- [x] User picks local folders (security-scoped bookmarks); files are matched to `spotify:local:` entries in playlists.
- [x] Uses librespot 0.8's local-file playback; respects its current limit of 44.1 kHz files and shows a clear message for others.

### E8 · Quality

#### PBI-801 · Accessibility

**Story:** As a VoiceOver user, I want every control labelled and reachable so that I can use the app without sight.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M3 · **Depends on:** PBI-401–PBI-408

**Status:** Done (merged to develop)

- [x] All controls have labels, values and hints; track rows read title, artist, duration and playing state. (Not yet checked with VoiceOver that the row reads as one item.)
- [x] Full keyboard navigation (Tab, arrows, Return, Escape) across sidebar, lists and popovers. (Home grids are reached by Tab only.)
- [x] Respects Reduce Motion, Increase Contrast and Dynamic Type-equivalent text size setting (Settings > General > Text size).
- [ ] Accessibility Inspector audit has no warnings on main screens. (Clean on Home, Album, Settings, track list, queue and devices; Search, Lyrics and Now Playing still report an elementless "Parent/Child mismatch". Contrast is measured from screen pixels, since the audit flags text drawn at 5.6-9.5:1.)

#### PBI-802 · Localization

**Story:** As a non-English speaker, I want the app in my language so that it feels native.

**Priority:** Should · **Estimate:** 3 · **Milestone:** M4 · **Depends on:** PBI-401

- [ ] All strings in a String Catalog; no hard-coded UI text; dates, durations and numbers use locale formatters.
- [ ] English and Polish shipped at 1.0; Weblate or Crowdin project open for community languages.

#### PBI-803 · Performance budget and profiling

**Story:** As a user who left Electron-style apps, I want the app light on memory and battery so that the switch is worth it.

**Priority:** Must · **Estimate:** 5 · **Milestone:** M3 · **Depends on:** PBI-201, PBI-403

- [ ] Budgets enforced in CI performance tests: cold launch < 1 s, idle RAM < 120 MB, RAM during playback < 200 MB, CPU during playback < 3 % on M1.
- [ ] Instruments templates (Time Profiler, Allocations, Energy) documented in `docs/performance.md`.
- [ ] Comparison table vs the official desktop app published in the README.

#### PBI-804 · Opt-in crash reporting

**Story:** As a maintainer, I want crash reports from users who opt in so that I can fix real-world crashes.

**Priority:** Could · **Estimate:** 2 · **Milestone:** M4 · **Depends on:** PBI-006

- [ ] Off by default; asked once after the first crash.
- [ ] Uses MetricKit diagnostics and/or a self-hostable service (e.g. Sentry); payloads contain no account identifiers.

### E9 · Release and community

#### PBI-901 · Code signing and notarization

**Story:** As a user, I want to open the app without Gatekeeper warnings so that installation is easy and safe.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M2 · **Depends on:** PBI-005

- [ ] Tag push triggers a release workflow: archive, sign with Developer ID, notarize with `notarytool`, staple, build DMG.
- [ ] Secrets stored in GitHub encrypted secrets; reproducible build instructions for people who build from source.

#### PBI-902 · Auto-update with Sparkle

**Story:** As a user, I want automatic updates so that I always have fixes when Spotify changes something.

**Priority:** Must · **Estimate:** 3 · **Milestone:** M3 · **Depends on:** PBI-901

- [ ] Sparkle 2 with EdDSA-signed appcast hosted on GitHub Pages; stable and beta channels.
- [ ] Release notes generated from the changelog.

#### PBI-903 · Homebrew cask

**Story:** As a developer, I want `brew install --cask` so that I can install and update from the terminal.

**Priority:** Should · **Estimate:** 1 · **Milestone:** M4 · **Depends on:** PBI-901

- [ ] Cask submitted to homebrew-cask (or a project tap until it qualifies), updated automatically on release.

#### PBI-904 · Documentation and website

**Story:** As a newcomer, I want clear docs and a landing page so that I can install, use and contribute.

**Priority:** Should · **Estimate:** 3 · **Milestone:** M4 · **Depends on:** PBI-001

- [ ] GitHub Pages site: features, screenshots, download, FAQ (why Premium, is it legal, privacy).
- [ ] `docs/` covers architecture, building from source, debugging the Rust core from Xcode, release process.
- [ ] "Good first issue" labels on at least 10 open issues at 1.0.
