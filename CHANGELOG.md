# Changelog

Notable changes to Veya. The release workflow publishes each version's entry
as its GitHub release notes and in-app update notes, and refuses to release a
tag without one. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.1] - 2026-10-29

Security and reliability fixes from an audit of the app, the Rust core and the release pipeline.

### Fixed

- Sparkle update feeds must now be signed, and releases are gated and the supply chain hardened.
- Links, sign-out, caches and playback restore are hardened against untrusted input.
- Playback ownership, validation, log redaction and size caps are stricter in the core.
- Newer Spotify Connect pushes are no longer overwritten, root-list inserts retry safely, and failed owner lookups are remembered.
- A broken metadata cache is reopened and stale entries are pruned.
- Unanswered crash reports survive quitting the app.
- Restarting Connect waits for the previous shutdown, and the scrubber follows the playback rate.
- Selection-tint swizzling is narrower, and a missing selector is caught in debug builds.
- The sign-in log shows the port the listener actually bound.
- Devices are listed from the Web API until the first Connect cluster push.
- Title and artist lines in Now Playing no longer collapse or blank.

### Changed

- The theme cycle pauses while the app is inactive.
- Podcast episode progress pages load concurrently.
- Dependencies updated: rustls, time and other Cargo crates.

## [1.1.0] - 2026-10-24

### Added

- Settings switch to hide the queue and lyrics panel in full-window Now Playing.

### Fixed

- The page play button shows pause while its playlist, album or show is playing.
- Settings form dividers use the system separator color.
- The player bar picks its accessory layout from the bar width, so it settles when the queue closes.
- The compact sidebar hides the equalizer on the playing row.
- Artist tiles on Home show square artwork.

### Changed

- The menu bar mini-player opens the window from its artwork instead of a separate button.

## [1.0.0] - 2026-10-19

First release: a native macOS Spotify client (Premium account required).

### Added

- Playback, queue, search, library, playlists, podcasts and lyrics, with Spotify Connect, media keys, crossfade, menu bar and Dock controls.
- DMG releases, self-signed and not notarized (PBI-901).
- Automatic updates with Sparkle, with an opt-in beta channel (PBI-902).
- Homebrew cask in the project tap: `brew install --cask sapiev/veya/veya` (PBI-903).
