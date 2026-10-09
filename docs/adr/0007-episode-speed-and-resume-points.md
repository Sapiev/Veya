# ADR-007: Episode playback speed and resume points

- Status: Accepted
- Date: 2026-10-09

## Context

PBI-306 requires playback speed from 0.8x to 2x for podcast episodes, and
resume positions and played state that match Spotify.

librespot cannot change playback speed. Its player decodes and writes PCM at
1x into the sink. librespot also has no API to read or write episode resume
points. The Web API returns them as `resume_point` on
`GET /v1/episodes`, but only when the token has the
`user-read-playback-position` scope. The Web API has no endpoint to write a
resume point.

## Decision

1. Speed is set in the app's `AVAudioEngine` graph (ADR-006). An
   `AVAudioUnitTimePitch` sits between the source node and the main mixer, so
   pitch stays the same. `AudioEngine.rate` is clamped to 0.8...2.0. A device
   switch reconnects only the mixer to the output, so the time-pitch unit
   stays in the graph.
2. librespot still decodes at 1x. At a higher rate the engine drains the ring
   buffer faster, and back-pressure lets librespot write sooner.
3. `PlaybackSettings.episodeSpeed` persists the speed. `rate(for:)` returns
   that speed for `spotify:episode:` URIs and 1x for everything else. Music
   always plays at 1x.
4. `spotcore::episode_progress` reads resume points from `GET /v1/episodes`
   in batches of 50. It uses the same hardened HTTP client as the Premium
   check (ADR-005). `user-read-playback-position` is added to the OAuth
   scopes (ADR-002). A 403, or a response without `resume_point`, maps to
   `PodcastError::MissingScope`. A progress failure leaves the show page
   loaded without progress.
5. The app does not write resume points. Spotify is expected to record them
   from the playback that librespot reports.

## Consequences

- Tokens issued before this change lack the scope. Users must sign in again
  to see progress.
- Resume points written by Spotify from librespot playback are unverified.
  A live check must confirm that a position reached in Veya appears in
  another Spotify client. librespot reports the position of decoded audio,
  which runs ahead of what was heard by the ring buffer's length.
- The Kit stores no Web API access token after sign-in, and restored
  sessions never have one. The app shell must supply a token to
  `WebAPIEpisodeProgress` before progress can show.
