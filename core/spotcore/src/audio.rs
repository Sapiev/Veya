//! Audio path from librespot's player to CoreAudio (ADR-006).
//!
//! The player thread writes interleaved stereo f32 into a wait-free SPSC
//! ring; Swift's render callback drains it through `spotcore_audio_render`,
//! a plain C function, because UniFFI calls may allocate.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::{NUM_CHANNELS, SAMPLE_RATE};
use rtrb::{Consumer, Producer, RingBuffer};

const CHANNELS: usize = NUM_CHANNELS as usize;
/// 200 ms of audio. Every push and pop moves whole frames and the capacity is
/// a whole number of frames, so a frame never straddles the wrap point.
const RING_SAMPLES: usize = SAMPLE_RATE as usize / 5 * CHANNELS;
const WRITE_RETRY: Duration = Duration::from_millis(5);

#[derive(Default)]
struct AudioStats {
    /// Between `Sink::start` and `Sink::stop`; silence outside it is expected.
    active: AtomicBool,
    /// Set by the first non-empty render after `start`, so the initial fill
    /// is not counted as an underrun.
    primed: AtomicBool,
    underruns: AtomicU64,
}

/// One playback output: hands the ring's producer to the player's sink and
/// its consumer to the Swift render callback.
#[derive(uniffi::Object)]
pub struct AudioOutput {
    stats: Arc<AudioStats>,
    producer: Mutex<Option<Producer<f32>>>,
    consumer: Mutex<Option<Consumer<f32>>>,
}

#[uniffi::export]
impl AudioOutput {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        let (producer, consumer) = RingBuffer::new(RING_SAMPLES);
        Arc::new(Self {
            stats: Arc::default(),
            producer: Mutex::new(Some(producer)),
            consumer: Mutex::new(Some(consumer)),
        })
    }

    /// Render callbacks that came up short while playing.
    pub fn underrun_count(&self) -> u64 {
        self.stats.underruns.load(Relaxed)
    }

    /// Moves the ring's consumer out as an opaque `RenderHandle *` for
    /// `spotcore_audio_render`; 0 if already taken. The caller owns it and
    /// releases it with `spotcore_audio_render_handle_free`.
    pub fn take_render_handle(&self) -> u64 {
        let Some(consumer) = self.consumer.lock().ok().and_then(|mut c| c.take()) else {
            return 0;
        };
        let handle = Box::new(RenderHandle {
            consumer,
            stats: Arc::clone(&self.stats),
        });
        Box::into_raw(handle) as u64
    }
}

impl AudioOutput {
    /// The librespot sink feeding this output; `None` if already taken.
    pub fn take_sink(&self) -> Option<CoreAudioSink> {
        let producer = self.producer.lock().ok()?.take()?;
        Some(CoreAudioSink {
            producer,
            stats: Arc::clone(&self.stats),
            logged_underruns: 0,
        })
    }
}

pub struct CoreAudioSink {
    producer: Producer<f32>,
    stats: Arc<AudioStats>,
    logged_underruns: u64,
}

impl CoreAudioSink {
    /// Blocks while the ring is full: that back-pressure paces the decoder.
    fn push(&mut self, mut samples: &[f32]) -> SinkResult<()> {
        while !samples.is_empty() {
            if self.producer.is_abandoned() {
                return Err(SinkError::NotConnected("render handle released".into()));
            }
            let (_, rest) = self.producer.push_partial_slice(samples);
            if rest.len() == samples.len() {
                std::thread::sleep(WRITE_RETRY);
            }
            samples = rest;
        }
        Ok(())
    }

    /// Logged here, not on the audio thread, which must not lock or allocate.
    fn log_new_underruns(&mut self) {
        let total = self.stats.underruns.load(Relaxed);
        if total > self.logged_underruns {
            log::warn!(
                "audio underruns: {} new, {total} total",
                total - self.logged_underruns
            );
            self.logged_underruns = total;
        }
    }
}

impl Sink for CoreAudioSink {
    fn start(&mut self) -> SinkResult<()> {
        self.stats.primed.store(false, Relaxed);
        self.stats.active.store(true, Relaxed);
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        self.stats.active.store(false, Relaxed);
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let AudioPacket::Samples(samples) = packet else {
            return Err(SinkError::InvalidParams(
                "raw passthrough unsupported".into(),
            ));
        };
        if samples.len() % CHANNELS != 0 {
            return Err(SinkError::InvalidParams("partial stereo frame".into()));
        }
        self.push(&converter.f64_to_f32(&samples))?;
        self.log_new_underruns();
        Ok(())
    }
}

pub struct RenderHandle {
    consumer: Consumer<f32>,
    stats: Arc<AudioStats>,
}

impl RenderHandle {
    fn render(&mut self, left: &mut [f32], right: &mut [f32]) -> usize {
        let frames = left.len().min(right.len());
        let n = (self.consumer.slots() / CHANNELS).min(frames);
        if let Ok(chunk) = self.consumer.read_chunk(n * CHANNELS) {
            let mut samples = chunk.into_iter();
            for (l, r) in left.iter_mut().zip(right.iter_mut()).take(n) {
                *l = samples.next().unwrap_or(0.0);
                *r = samples.next().unwrap_or(0.0);
            }
        }
        left[n..].fill(0.0);
        right[n..].fill(0.0);

        if self.stats.active.load(Relaxed) {
            let primed = self.stats.primed.load(Relaxed);
            if primed && n < frames {
                self.stats.underruns.fetch_add(1, Relaxed);
            } else if !primed && n > 0 {
                self.stats.primed.store(true, Relaxed);
            }
        }
        n
    }
}

/// Fills `frames` samples of planar `left` and `right` from the ring, padding
/// with silence, and returns how many frames came from the ring. Real-time
/// safe: no locks, no allocation.
///
/// # Safety
/// `handle` comes from `AudioOutput::take_render_handle`, is not freed and is
/// used by one thread at a time; `left` and `right` each point to `frames`
/// writable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn spotcore_audio_render(
    handle: *mut RenderHandle,
    left: *mut f32,
    right: *mut f32,
    frames: usize,
) -> usize {
    if handle.is_null() || left.is_null() || right.is_null() {
        return 0;
    }
    // SAFETY: guaranteed by the caller contract above.
    unsafe {
        let left = std::slice::from_raw_parts_mut(left, frames);
        let right = std::slice::from_raw_parts_mut(right, frames);
        (*handle).render(left, right)
    }
}

/// # Safety
/// `handle` comes from `AudioOutput::take_render_handle` (or is null), no
/// render call is in flight, and it is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn spotcore_audio_render_handle_free(handle: *mut RenderHandle) {
    if !handle.is_null() {
        // SAFETY: guaranteed by the caller contract above.
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(samples: &[f64]) -> AudioPacket {
        AudioPacket::Samples(samples.to_vec())
    }

    fn setup() -> (Arc<AudioOutput>, CoreAudioSink, Box<RenderHandle>) {
        let output = AudioOutput::new();
        let sink = output.take_sink().unwrap();
        let handle = output.take_render_handle() as *mut RenderHandle;
        // SAFETY: freshly taken handle, owned by the test from here on.
        (output, sink, unsafe { Box::from_raw(handle) })
    }

    fn render(handle: &mut RenderHandle, frames: usize) -> (usize, Vec<f32>, Vec<f32>) {
        let (mut left, mut right) = (vec![9.0; frames], vec![9.0; frames]);
        let n = handle.render(&mut left, &mut right);
        (n, left, right)
    }

    #[test]
    fn render_deinterleaves_written_frames_and_pads_with_silence() {
        let (_output, mut sink, mut handle) = setup();
        sink.write(packet(&[0.5, -0.5, 0.25, -0.25]), &mut Converter::new(None))
            .unwrap();

        let (n, left, right) = render(&mut handle, 3);

        assert_eq!(n, 2);
        assert_eq!(left, [0.5, 0.25, 0.0]);
        assert_eq!(right, [-0.5, -0.25, 0.0]);
    }

    #[test]
    fn underruns_count_only_short_renders_after_priming_while_active() {
        let (output, mut sink, mut handle) = setup();
        let mut converter = Converter::new(None);

        render(&mut handle, 4);
        sink.start().unwrap();
        render(&mut handle, 4);
        sink.write(packet(&[0.1; 4]), &mut converter).unwrap();
        render(&mut handle, 4);
        assert_eq!(
            output.underrun_count(),
            0,
            "initial fill is not an underrun"
        );

        render(&mut handle, 4);
        assert_eq!(output.underrun_count(), 1);

        sink.stop().unwrap();
        render(&mut handle, 4);
        assert_eq!(
            output.underrun_count(),
            1,
            "silence while stopped is expected"
        );

        sink.start().unwrap();
        render(&mut handle, 4);
        assert_eq!(output.underrun_count(), 1, "restart re-arms priming");
    }

    #[test]
    fn write_blocks_on_a_full_ring_until_the_consumer_drains_it() {
        let (_output, mut sink, mut handle) = setup();
        let samples = vec![0.0; RING_SAMPLES * 3];
        let writer = std::thread::spawn(move || {
            sink.write(AudioPacket::Samples(samples), &mut Converter::new(None))
        });

        let mut drained = 0;
        while drained < RING_SAMPLES * 3 / CHANNELS {
            drained += render(&mut handle, 512).0;
        }

        writer.join().unwrap().unwrap();
    }

    #[test]
    fn write_fails_once_the_render_handle_is_released() {
        let (_output, mut sink, handle) = setup();
        drop(handle);
        let too_many = vec![0.0; RING_SAMPLES + CHANNELS];

        let result = sink.write(AudioPacket::Samples(too_many), &mut Converter::new(None));

        assert!(matches!(result, Err(SinkError::NotConnected(_))));
    }

    #[test]
    fn write_rejects_partial_frames_and_raw_packets() {
        let (_output, mut sink, _handle) = setup();
        let mut converter = Converter::new(None);

        assert!(sink.write(packet(&[0.1; 3]), &mut converter).is_err());
        assert!(
            sink.write(AudioPacket::Raw(vec![0; 4]), &mut converter)
                .is_err()
        );
    }

    #[test]
    fn ring_ends_are_taken_once() {
        let output = AudioOutput::new();
        let handle = output.take_render_handle();

        assert!(output.take_sink().is_some());
        assert!(output.take_sink().is_none());
        assert_ne!(handle, 0);
        assert_eq!(output.take_render_handle(), 0);
        // SAFETY: handle came from take_render_handle and is unused.
        unsafe { spotcore_audio_render_handle_free(handle as *mut RenderHandle) };
    }

    #[test]
    fn c_render_rejects_null_pointers() {
        let mut buf = [0.0f32; 1];
        // SAFETY: null handle is checked before any dereference.
        let n = unsafe {
            spotcore_audio_render(std::ptr::null_mut(), buf.as_mut_ptr(), buf.as_mut_ptr(), 1)
        };
        assert_eq!(n, 0);
    }
}
