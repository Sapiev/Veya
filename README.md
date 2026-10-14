# Veya

A native SwiftUI/AppKit Spotify client for macOS 14+, with playback powered by
[librespot](https://github.com/librespot-org/librespot) (Rust, MIT). No web
view anywhere.

> **Unofficial and not affiliated with, endorsed by, or sponsored by Spotify.**
> Veya is an independent open-source project. "Spotify" and its logos are
> trademarks of Spotify AB. Veya requires a Spotify **Premium** account;
> librespot is an unofficial, reverse-engineered client and its use is not
> sanctioned by Spotify's terms. Use at your own risk - see
> [Risks](Veya/Native%20macOS%20Spotify%20Client%20(librespot)%20%E2%80%94%20Plan%20%26%20PBIs.md#risks-open-questions-and-definition-of-done).

## Status

Early development. See the [plan and backlog](Veya/Native%20macOS%20Spotify%20Client%20(librespot)%20%E2%80%94%20Plan%20%26%20PBIs.md)
for the roadmap, architecture and PBIs.

## Goals

- Sign in with Spotify (OAuth PKCE), Premium accounts only.
- Browse library: playlists, liked songs, albums, artists, podcasts.
- Search, play, queue, shuffle/repeat, seek, volume, gapless playback.
- Spotify Connect: appear as a device, and control/transfer to other devices.
- macOS integration: Now Playing / media keys, menu bar mini-player, Dock
  menu, notifications, Shortcuts/AppleScript.
- Lyrics, playlist editing, offline-friendly caching of metadata and artwork.
- Light on memory and battery, held to a budget in CI: launch under 1 s, under
  120 MB idle, under 200 MB and 3 % CPU playing. See
  [docs/performance.md](docs/performance.md).

## Non-goals

- Free-tier support.
- Downloading or exporting audio for offline use.
- Ad blocking, Windows/Linux builds, iOS.

## Privacy and diagnostics

Veya sends no telemetry, analytics or crash reports. Logs stay on your Mac:
they go to the unified log (Console.app, subsystem prefix is the app's bundle
ID) and to daily files under `~/Library/Containers/<bundle ID>/Data/Library/Logs/Veya`,
kept for about three days. To report a bug, choose **Help > Export
Diagnostics**: it saves a zip of the last 24 hours of logs, with tokens,
usernames and email addresses redacted, wherever you choose. Nothing is
uploaded; you decide whether to attach it to an issue.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Please report security issues per
[SECURITY.md](SECURITY.md) rather than in a public issue.

## License

MIT - see [LICENSE](LICENSE).
