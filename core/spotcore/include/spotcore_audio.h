// Hand-written C API for the real-time audio path (ADR-006). UniFFI calls
// may allocate, so the render callback uses these instead. Must match
// core/spotcore/src/audio.rs.
#pragma once

#include <stddef.h>

typedef struct SpotcoreRenderHandle SpotcoreRenderHandle;

// Fills `frames` floats of planar `left` and `right`, padding with silence;
// returns frames taken from the ring. No locks, no allocation.
size_t spotcore_audio_render(SpotcoreRenderHandle *_Nonnull handle,
                             float *_Nonnull left,
                             float *_Nonnull right,
                             size_t frames);

// Releases a handle from AudioOutput.takeRenderHandle(); no render may be in flight.
void spotcore_audio_render_handle_free(SpotcoreRenderHandle *_Nullable handle);
