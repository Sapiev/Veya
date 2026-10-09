# ADR-006: Audio path from librespot to CoreAudio

- Status: Accepted
- Date: 2026-10-09

## Context

ADR-001 left the audio path open. librespot's player decodes on its own
thread and hands 44.1 kHz stereo samples to a `Sink`. CoreAudio pulls
samples on a real-time thread that must not lock, allocate or block.
UniFFI calls do not guarantee that: they marshal through `RustBuffer`, and
the generated Swift wrappers retain objects and build call-status structs
for every call.

## Decision

- `spotcore::AudioOutput` (a UniFFI object) owns a wait-free SPSC ring
  (`rtrb`) holding 200 ms of interleaved f32. Its producer goes to
  `CoreAudioSink`, which implements librespot's `Sink`. Its consumer goes
  to Swift as an opaque handle.
- The render path does not use UniFFI. Two hand-written C functions,
  declared in `core/spotcore/include/spotcore_audio.h` and added to the
  `spotcoreFFI` module by `scripts/build-xcframework.sh`, render into
  planar left/right buffers and free the handle.
- `CoreAudioSink::write` blocks while the ring is full. This back-pressure
  paces the decoder. It returns `NotConnected` when the handle is freed, so
  the player thread cannot hang on a dead consumer.
- A render that comes up short counts as an underrun only between
  `Sink::start` and `Sink::stop`, and only after the first non-empty
  render, so the initial fill does not count. The audio thread only
  increments an atomic. The sink logs new underruns from the player thread.
- Swift's `AudioEngine` plays the ring through an `AVAudioSourceNode` on an
  `AVAudioEngine` bound to the system default output. When the default
  device changes, the engine posts `AVAudioEngineConfigurationChange` and
  stops; `AudioEngine` reconnects the mixer to the output and restarts it.

## Consequences

- One `AudioOutput` feeds one engine. The handle can be taken only once.
- Pause and stop drain what is already in the ring, so they take effect
  after up to 200 ms. Seek needs a flush, which comes with the player
  (PBI-202).
- The C header must match `audio.rs` by hand. Two functions keep that
  cheap. The Rust tests call the C functions directly.
