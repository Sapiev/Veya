# ADR-009: Spotify Connect as a hybrid beside the local player

- Status: Accepted
- Date: 2026-10-11

## Context

E5 makes the Mac a Spotify Connect device (PBI-501), lets the user move
playback between devices (PBI-502) and control another active device
(PBI-503). librespot 0.8's `Spirc` implements the device side, but:

- `Spirc::new` connects the `Session` it is given, after registering its
  dealer listeners, so it needs a fresh, unconnected session. Our
  `SpotSession` hands out connected sessions from its reconnect supervisor.
- `Spirc` owns a `Player` and its own queue (`ConnectState`). Its public
  API has no add, remove, reorder or skip-N, which `SpotPlayer`'s `Queue`
  provides (PBI-203, the queue panel).

We keep `SpotPlayer` and its `Queue` for local playback and run `Spirc`
beside it, instead of making `Spirc` the only playback engine.

## Decision

### Connect session (`connect.rs`, `SpotConnect`)

- `SpotConnect` owns a `Supervisor<ConnectLink>`, reusing ADR-004's
  reconnect and backoff. `ConnectLink` holds a dedicated `Session`, the
  `Spirc` handle and Spirc's `Player`. Its connector builds a fresh
  session from the main session's stored credentials and passes it to
  `Spirc::new`, which connects it. The link is invalid when the session
  is invalid or the Spirc task has ended.
- Device id: the main device id with a fixed `-connect` suffix. It is
  stable across launches, so phones do not list duplicates, and it does
  not collide with the main session's login.
- `ConnectConfig`: device type `Computer`, name from Settings (defaults to
  the Mac's localized name). Renaming restarts the link.

### One sink, two players

- Spirc's `Player` writes through the same `SharedSink` as the local
  player. A shared `owner` (`Local` or `Connect`) gates writes next to the
  existing epoch: a player writes only when its epoch is current and its
  role owns the sink.
- Spirc and the local player share one `SoftMixer`, so remote volume
  changes move the app's volume. Spirc's player emits `VolumeChanged`,
  forwarded as a `PlaybackEvent`.

### Modes

`SpotPlayer` routes each call by the current mode:

| Mode | Entered when | Transport | Load | Queue edits | Queue snapshot |
|------|--------------|-----------|------|-------------|----------------|
| Local | Spirc inactive, no other device active | local `Player` | local `Queue` | local `Queue` | local `Queue` |
| Connect | Spirc's player starts loading or playing (a remote picked this Mac, or a transfer to it) | `Spirc` handle | `Spirc::load` | connect-state command to this device | cluster update |
| Remote (PBI-503) | the cluster names another active device | connect-state command to that device | command to that device | command to that device | cluster update |

- Entering Connect or Remote stops the local player, so nothing is decoded
  locally in Remote mode.
- Remote mode is entered only while the other device is playing, since
  Spotify keeps a paused device as active for a long time. Once entered it
  holds while that device stays active, so the Mac can resume it. A local
  load while the remote is paused leaves Remote mode and plays locally;
  while the remote is playing, a load goes to the remote.
- Teardown (sign-out, quit) stops only local playback and never commands
  a remote. A remote's volume is shown but never saved as the app volume.
- Leaving Connect (Spirc goes inactive) returns the sink to Local with the
  local player stopped. The local queue is kept, not resumed.
- Connect-state commands are `POST /connect-state/v1/player/command/from/{me}/to/{target}`
  through `SpClient::request`, the path Spotify's own clients use. Spirc
  handles `add_to_queue`, `set_queue` and `skip_next` sent to itself, so
  Connect mode keeps add, remove and reorder without forking librespot.
- Local-mode playback is not published to Connect; the Mac shows as an
  idle device until a remote or a transfer activates it.

### Cluster and devices (PBI-502)

- `SpotConnect` listens to `hm://connect-state/v1/cluster` on its dealer
  and pushes a `ConnectCluster` (devices with id, name, type, volume,
  active flag, this-device flag; active device's track, position, paused,
  next tracks, shuffle, repeat) to a `ConnectObserver`.
- Transfer to this Mac: `Spirc::transfer(None)`. Transfer elsewhere:
  `SpClient::transfer(active, target, None)`.

### Zeroconf (optional, off by default)

- `librespot-discovery` with the `with-dns-sd` backend (Bonjour, no extra
  mDNS responder). Credentials it receives are accepted only when their
  username equals the signed-in user; others are dropped and logged
  without the username. The app never switches accounts from the LAN.
- Needs `NSLocalNetworkUsageDescription` and `NSBonjourServices`
  (`_spotify-connect._tcp`) in Info.plist and the network server
  entitlement.

## Consequences

- Two AP connections per signed-in app while Connect is enabled.
- The connect-state command JSON is undocumented; its shapes are pinned
  by unit tests on the request body and must be rechecked on librespot
  upgrades.
- In Connect and Remote modes the queue view comes from the cluster, so
  it shows what Spotify's servers hold, with dealer latency.
