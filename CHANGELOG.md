# Changelog

Notable changes to Veya. The release workflow publishes each version's entry
as its GitHub release notes and in-app update notes, and refuses to release a
tag without one. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.0] - 2026-10-24

### Added

- Settings switch to hide the queue and lyrics panel in full-window Now Playing.

### Fixed

- The page play button shows pause while its playlist, album or show is playing.
- Settings form dividers use the system separator color.
- The player bar picks its accessory layout from the bar width, so it settles when the queue closes.
- The compact sidebar hides the equalizer on the playing row.

## [1.0.0] - 2026-10-19

First release: a native macOS Spotify client (Premium account required).

### Added

- Playback, queue, search, library, playlists, podcasts and lyrics, with Spotify Connect, media keys, crossfade, menu bar and Dock controls.
- DMG releases, self-signed and not notarized (PBI-901).
- Automatic updates with Sparkle, with an opt-in beta channel (PBI-902).
- Homebrew cask in the project tap: `brew install --cask sapiev/veya/veya` (PBI-903).
