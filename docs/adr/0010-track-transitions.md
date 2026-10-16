# ADR-010: Crossfade, de-click fades and track-change animation

- Status: Proposed
- Date: 2026-10-16

## Context

Users want Spotify-style transitions: an optional crossfade between tracks,
no clicks when playback pauses, seeks or skips, and a smooth now-playing
change in the UI. librespot decodes one track at a time and has no
crossfade. Its decoder is paced only by `CoreAudioSink::write` blocking on
the 200 ms ring (ADR-006). `EndOfTrack` fires after the last sample of a
track is written, and our event loop then loads the preloaded next track
(PBI-204), so a track boundary is ordered in the sample stream.

## Decision

- **Crossfade lives in `CoreAudioSink`, with one librespot player.**
  `SpotPlayer::set_crossfade(seconds)` (0 = off, at most 12) is stored on
  the sink. The event loop takes the track's length from `TrackChanged` and
  passes it, with the position, to the sink on `Playing` and `Seeked`.
  Capture is armed only once `TimeToPreloadNextTrack` has preloaded a next
  track, so a context's last track never captures a tail. Once a track is
  within the crossfade length
  of its end, `write` stops pushing to the ring and appends to a tail
  buffer without blocking, so the decoder runs ahead to `EndOfTrack`. The
  handler marks the boundary before loading the next track. The next
  track's first frames are mixed with the tail on an equal-power curve and
  pushed to the ring, which paces the decoder again. The fade length is
  the captured tail length, capped at the setting.
- Crossfade only happens when a track ends naturally and the next one
  starts automatically. A user load, skip, seek or stop, and any Connect
  (Spirc) playback, drops the tail and plays without a crossfade. With the
  setting at 0, the sink behaves exactly as it did before (gapless).
- **Fades on start, pause and cut are always on, and last 300 ms.** They
  run on the render side, which stays wait-free and never allocates: one
  gain per frame, driven by atomics.
  - After `start`, or after a discontinuity (seek, user skip or load), the
    new audio ramps up from 0 over 300 ms.
  - A discontinuity fades out only the audio already queued (at most the
    200 ms ring) and drops the rest, so skips stay instant. The control
    side asks for that fade at once. The producer marks the first new
    sample once librespot confirms the command (a new play request id or
    `Seeked`; a `Playing` may predate the command, so it never confirms),
    so packets decoded before it are dropped.
  - A local pause fades the live audio out over 300 ms, then holds what
    is queued, so nothing is lost. librespot's pause is sent 300 ms later
    from a timer. While the render side holds, writes go to a pending
    buffer instead of blocking, so librespot can reach that command.
    Resume ramps up from the held audio.
  - A newer play, seek, load, skip or stop during the fade cancels the
    pending pause through a generation counter. A play ramps back up from
    the current gain. A second pause during the fade does nothing.
    Connect and Remote mode pause as before.
- **The UI animates track changes in SwiftUI.** Artwork and title
  cross-dissolve when the track id changes. Under Reduce Motion there is
  no animation.
- The Settings › Playback "Crossfade songs" slider (0-12 s, default 0) is
  persisted in `PlaybackSettings` and applied to `SpotPlayer` the same way
  normalisation is.

## Consequences

- The UI moves to the next track when the fade begins. The outgoing track's
  last seconds are decoded faster than real time, so its reported position
  jumps to the end.
- Any delay in loading the preloaded track while the tail is captured comes
  out of the ring's 200 ms, so a slow load can underrun once. The
  existing underrun counter shows it.
- A crossfade longer than 0 also blends gapless albums. Spotify does the
  same, and the setting defaults to off.
- A local pause is reported 300 ms after the click, when librespot's
  Paused event arrives.
- A tail buffer holds at most 12 s of stereo f32 (about 4 MB). It is
  allocated on the player thread, never on the render thread.
