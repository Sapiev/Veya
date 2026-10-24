# ADR-004: Session reconnect

- Status: Accepted
- Date: 2026-10-09

## Context

PBI-103 requires the app to recover from sleep and network drops without a
restart. A librespot `Session` cannot be reused after it is invalidated.
librespot invalidates a session when the access point (AP) connection
closes, fails, or misses a keepalive deadline (up to 80 seconds). It emits no
event when this happens; `Session::is_invalid()` is the only signal.

The Connect dealer is not started yet (PBI-501), so the AP connection is the
only connection to watch for now. The player (PBI-201, PBI-202) does not
exist yet, so there is no track or position to restore.

## Decision

1. `spotcore` owns reconnection. `SpotSession` wraps the current librespot
   `Session` and runs a supervisor task. The supervisor polls
   `is_invalid()` every second. When the session is dead, the supervisor
   opens a new session on the same device ID with the reusable credentials
   of the last good session. If no session has produced reusable
   credentials yet, the supervisor reconnects with the credentials of the
   first connect and ignores wake events, so that a healthy session is not
   replaced by a retry with a possibly expired access token.
2. Failed attempts back off 1, 2, 4, 8, 16, 32, then 60 seconds, capped at
   60. A successful attempt resets the backoff.
3. Swift reports system events to `spotcore` and does not run its own retry
   loop:
   - `system_did_wake()` forces a reconnect, because sockets rarely survive
     sleep and the keepalive needs up to 80 seconds to notice.
   - `network_changed(available: true)` skips the remaining backoff delay
     while the supervisor is reconnecting.
4. `spotcore` reports `ConnectionState` (`Connected`, `Reconnecting`,
   `CredentialsRejected`) through the `ConnectionObserver` callback
   interface. Swift queues the callbacks in an `AsyncStream` so that they
   reach the main actor in order. While the state is `Reconnecting`, the UI
   shows an "Offline - reconnecting" banner.
5. `CredentialsRejected` is terminal. Swift deletes the stored credentials
   (only if they are unchanged) and shows the sign-in screen, as it does for
   a rejected restore at launch (ADR-003).
6. After each `Connected`, Swift saves `stored_credentials()` again, because
   the AP can issue new reusable credentials on reconnect.
7. `SpotPlayer` restores playback itself (amended 2026-10-10, PBI-103). The
   supervisor announces each installed session on an internal watch channel,
   not through `ConnectionObserver`, which has one slot that Swift owns. On
   each announcement the player moves to the new session and reloads the
   current track at its last position, playing or paused as before. The
   queue and context live in the player, so they carry over. The player
   records the session it holds, so a repeated announcement does nothing and
   a reconnect during a restore restores again.

## Consequences

- Retry policy and dead-session detection are tested in Rust with virtual
  time, without a network.
- Detection takes up to one polling interval longer than librespot's own
  detection. One second is small next to the keepalive deadlines.
- A future dealer-close signal (PBI-501) only needs to invalidate the
  session or wake the supervisor.
- Pausing when another device takes over playback is left for PBI-501.
  It must not add a second reconnect path.
- The restored position is the last one librespot reported, plus at most
  one second. If the stream stalled, the track restarts where audio
  stopped. If librespot already skipped a failed track, the next track
  restarts from its beginning.
