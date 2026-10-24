# Veya - Plan

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

The backlog lives in the [Veya GitHub project](https://github.com/users/Sapiev/projects/5): one issue per PBI in `Sapiev/Veya`, titled `PBI-xxx · Title`. Each issue holds the story, dependencies and acceptance criteria checklist. The project's Priority field maps MoSCoW (P0 Must, P1 Should, P2 Could), Estimate holds story points (Fibonacci), repo milestones M0-M4 match the roadmap, and `epic: E0`-`E9` labels group the epics. Every PBI also has to meet the Definition of Done below.

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
