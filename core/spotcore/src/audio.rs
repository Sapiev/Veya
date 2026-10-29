//! Audio path from librespot's player to CoreAudio (ADR-006).
//!
//! The player thread writes interleaved stereo f32 into a wait-free SPSC
//! ring; Swift's render callback drains it through `spotcore_audio_render`,
//! a plain C function, because UniFFI calls may allocate.

use std::sync::atomic::{
    AtomicBool, AtomicU64, Ordering::Acquire, Ordering::Relaxed, Ordering::Release,
};
use std::sync::{Arc, Mutex, PoisonError};
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
/// Audio kept while the render side holds a pause; a stalled engine cannot
/// grow it past this.
const PENDING_MAX_SAMPLES: usize = RING_SAMPLES * 2;
const WRITE_RETRY: Duration = Duration::from_millis(5);
/// A full ring nobody renders for this long means the engine stopped; the
/// write fails so librespot pauses instead of blocking its thread forever.
/// Long enough to ride out an engine restart after a device change.
const STALL_TIMEOUT: Duration = Duration::from_secs(2);
/// Fade length for starts, pauses and cuts (ADR-010).
pub const FADE: Duration = Duration::from_millis(300);
const FADE_FRAMES: usize = SAMPLE_RATE as usize * 300 / 1000;
pub const MAX_CROSSFADE_SECONDS: u8 = 12;

#[derive(Default)]
struct AudioStats {
    /// Between `Sink::start` and `Sink::stop`; silence outside it is expected.
    active: AtomicBool,
    /// Set by the first non-empty render after `start`, so the initial fill
    /// is not counted as an underrun.
    primed: AtomicBool,
    underruns: AtomicU64,
    /// Bumped by every render call, so a blocked writer can tell a slow
    /// consumer from one that stopped.
    renders: AtomicU64,
    /// Bumped by a discontinuity request: the render side fades out what is
    /// queued at once and drops everything until the next `cut_at`.
    fade_requests: AtomicU64,
    /// Samples pushed when the sink applied a discontinuity: audio after it
    /// is the new position, faded in.
    cut_at: AtomicU64,
    /// Bumped after each `cut_at` store: two cuts with nothing pushed between
    /// them share a position, so only the count tells the render side a new one came.
    cuts: AtomicU64,
    /// Set by `Sink::stop` on a pause: the render side fades out and keeps
    /// the rest queued until `start`.
    held: AtomicBool,
    /// Bumped by `Sink::start`; the render side fades in.
    starts: AtomicU64,
    /// A local pause is fading out live audio; the render side holds at 0.
    pausing: AtomicBool,
    /// The render side stopped reading a held pause, so a full ring must not
    /// block the writer: librespot takes its pause between writes.
    render_holding: AtomicBool,
}

/// Track-transition requests from the player's control side. The sink
/// applies them at its next write, so they line up with the sample stream.
pub struct Transitions {
    requests: Mutex<Requests>,
    stats: Arc<AudioStats>,
}

#[derive(Clone, Copy, Default)]
struct Requests {
    crossfade_frames: usize,
    /// The next track is preloaded, so this one may end in a crossfade.
    armed: bool,
    /// Length and position of the playing track, in frames.
    track: Option<(u64, u64)>,
    boundary: bool,
    discontinuity: bool,
    /// librespot acted on the command behind `discontinuity`, so the next
    /// write is new audio rather than a packet decoded before it.
    confirmed: bool,
    /// The context ended: the next stop lets queued audio play out.
    play_out: bool,
    /// A pause fades out until its delayed librespot pause runs.
    pause_pending: bool,
    /// Bumped by every pause and cancel, so a stale delayed pause does nothing.
    pause_generation: u64,
}

impl Transitions {
    fn new(stats: Arc<AudioStats>) -> Self {
        Self {
            requests: Mutex::default(),
            stats,
        }
    }

    /// 0 turns crossfade off; longer than `MAX_CROSSFADE_SECONDS` is clamped.
    pub fn set_crossfade(&self, seconds: u8) {
        let frames = usize::from(seconds.min(MAX_CROSSFADE_SECONDS)) * SAMPLE_RATE as usize;
        self.update(|r| r.crossfade_frames = frames);
    }

    /// The next track is preloaded and will follow without a user action.
    pub fn arm(&self) {
        self.update(|r| r.armed = true);
    }

    pub fn track(&self, duration_ms: u32, position_ms: u32) {
        let frames = |ms: u32| u64::from(ms) * u64::from(SAMPLE_RATE) / 1000;
        self.update(|r| r.track = Some((frames(duration_ms), frames(position_ms))));
    }

    /// The track ended naturally; the next write belongs to the next track.
    pub fn boundary(&self) {
        self.update(|r| {
            r.boundary = true;
            r.armed = false;
            r.track = None;
        });
    }

    /// A user load, skip or stop: no crossfade, and what is queued
    /// fades out now rather than at the next write. True if it cancelled a
    /// pending pause.
    pub fn discontinuity(&self) -> bool {
        self.cut(false)
    }

    /// A discontinuity within the playing track, so its preloaded next track
    /// still follows: librespot suggests the preload only once per track.
    pub fn seek(&self) -> bool {
        self.cut(true)
    }

    fn cut(&self, keep_armed: bool) -> bool {
        let mut pause_pending = false;
        self.update(|r| {
            pause_pending = r.pause_pending;
            *r = Requests {
                crossfade_frames: r.crossfade_frames,
                armed: keep_armed && r.armed,
                discontinuity: true,
                pause_generation: r.pause_generation + 1,
                ..Requests::default()
            };
            self.stats.pausing.store(false, Release);
        });
        self.stats.fade_requests.fetch_add(1, Release);
        pause_pending
    }

    /// Starts fading live audio out for a pause; `None` while one is already
    /// pending. Pass the generation to `finish_pause` once `FADE` has passed.
    pub fn begin_pause(&self) -> Option<u64> {
        let mut generation = None;
        self.update(|r| {
            if !r.pause_pending {
                r.pause_pending = true;
                r.pause_generation += 1;
                generation = Some(r.pause_generation);
                self.stats.pausing.store(true, Release);
            }
        });
        generation
    }

    /// Runs `pause` unless a newer command cancelled the pause `generation`.
    /// Held under the lock so a racing `cancel_pause` orders after it.
    pub fn finish_pause(&self, generation: u64, pause: impl FnOnce()) {
        self.update(|r| {
            if r.pause_pending && r.pause_generation == generation {
                r.pause_pending = false;
                pause();
            }
        });
    }

    /// A play during a pause fade ramps back up from the current gain. True
    /// if a pause was still pending, so librespot never paused.
    pub fn cancel_pause(&self) -> bool {
        let mut pending = false;
        self.update(|r| {
            pending = std::mem::take(&mut r.pause_pending);
            r.pause_generation += 1;
            self.stats.pausing.store(false, Release);
        });
        pending
    }

    /// librespot started a new play request or seeked: writes from here on
    /// are the new audio.
    pub fn confirm(&self) {
        self.update(|r| r.confirmed = r.discontinuity);
    }

    /// The context ended without a next track; the coming stop plays out.
    pub fn play_out(&self) {
        self.update(|r| {
            r.play_out = true;
            r.armed = false;
        });
    }

    fn update(&self, change: impl FnOnce(&mut Requests)) {
        change(&mut self.requests.lock().unwrap_or_else(PoisonError::into_inner));
    }

    /// The settings plus the one-shot requests made since the last call. An
    /// unconfirmed discontinuity leaves everything pending.
    fn take(&self) -> Requests {
        let mut requests = self.requests.lock().unwrap_or_else(PoisonError::into_inner);
        let taken = *requests;
        if !taken.discontinuity || taken.confirmed {
            requests.track = None;
            requests.boundary = false;
            requests.discontinuity = false;
            requests.confirmed = false;
        }
        taken
    }

    fn take_play_out(&self) -> bool {
        std::mem::take(
            &mut self
                .requests
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .play_out,
        )
    }
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
            popped: 0,
            cut: 0,
            fades_seen: 0,
            cuts_seen: 0,
            starts_seen: 0,
            muted: false,
            holding: false,
            pausing: false,
            level: FADE_FRAMES as f32,
            step: 0.0,
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
            transitions: Arc::new(Transitions::new(Arc::clone(&self.stats))),
            pushed: 0,
            track_frames: None,
            written_frames: 0,
            since_mark: None,
            tail: Vec::new(),
            mixed: None,
            pending: Vec::new(),
        })
    }
}

pub struct CoreAudioSink {
    producer: Producer<f32>,
    stats: Arc<AudioStats>,
    logged_underruns: u64,
    transitions: Arc<Transitions>,
    /// Samples pushed since the ring was made; `cut_at` records one.
    pushed: u64,
    track_frames: Option<u64>,
    written_frames: u64,
    /// Frames written since a boundary or discontinuity, until the next
    /// track position arrives: its event lags the first packets.
    since_mark: Option<u64>,
    /// The outgoing track's last frames, held back to mix with the next one.
    tail: Vec<f32>,
    /// Frames of `tail` mixed into the next track so far, while mixing.
    mixed: Option<usize>,
    /// Audio written while the render side held a pause; it goes out first.
    pending: Vec<f32>,
}

impl CoreAudioSink {
    pub fn transitions(&self) -> Arc<Transitions> {
        Arc::clone(&self.transitions)
    }

    /// For Connect playback, which never crossfades (ADR-010).
    pub fn write_gapless(
        &mut self,
        packet: AudioPacket,
        converter: &mut Converter,
    ) -> SinkResult<()> {
        self.tail.clear();
        self.mixed = None;
        self.write_packet(packet, converter, false)
    }

    fn write_packet(
        &mut self,
        packet: AudioPacket,
        converter: &mut Converter,
        crossfade: bool,
    ) -> SinkResult<()> {
        let AudioPacket::Samples(samples) = packet else {
            return Err(SinkError::InvalidParams(
                "raw passthrough unsupported".into(),
            ));
        };
        if samples.len() % CHANNELS != 0 {
            return Err(SinkError::InvalidParams("partial stereo frame".into()));
        }
        if !crossfade {
            // Spirc's audio follows its own commands, never ours.
            self.transitions.confirm();
        }
        let mut requests = self.transitions.take();
        if !crossfade {
            requests.crossfade_frames = 0;
            requests.armed = false;
        }
        let mut samples = converter.f64_to_f32(&samples);
        if requests.discontinuity && !requests.confirmed {
            // Decoded before the command; the render side drops it.
            return self.push(&samples);
        }
        self.apply(requests)?;
        self.mix(&mut samples);
        let frames = samples.len() / CHANNELS;
        let (now, held) =
            samples.split_at((frames - self.frames_to_hold(&requests, frames)) * CHANNELS);
        self.push(now)?;
        self.tail.extend_from_slice(held);
        self.written_frames += frames as u64;
        if let Some(since) = &mut self.since_mark {
            *since += frames as u64;
        }
        self.trim_tail(requests.crossfade_frames)?;
        self.log_new_underruns();
        Ok(())
    }

    fn apply(&mut self, requests: Requests) -> SinkResult<()> {
        if requests.discontinuity {
            self.tail.clear();
            self.mixed = None;
            self.pending.clear();
            self.mark();
            self.stats.cut_at.store(self.pushed, Release);
            self.stats.cuts.fetch_add(1, Release);
        }
        if requests.boundary {
            self.finish_mix()?;
            self.trim_tail(requests.crossfade_frames)?;
            self.mixed = (!self.tail.is_empty()).then_some(0);
            self.mark();
        }
        if let Some((total, position)) = requests.track {
            self.track_frames = Some(total);
            self.written_frames = position + self.since_mark.take().unwrap_or(0);
        }
        Ok(())
    }

    fn mark(&mut self) {
        self.track_frames = None;
        self.written_frames = 0;
        self.since_mark = Some(0);
    }

    /// Mixes the next track's head into the held tail.
    fn mix(&mut self, samples: &mut [f32]) {
        let Some(mut done) = self.mixed else {
            return;
        };
        let len = self.tail.len() / CHANNELS;
        for frame in samples.chunks_exact_mut(CHANNELS).take(len - done) {
            let (fade_out, fade_in) = crossfade_gains(done, len);
            let tail = &self.tail[done * CHANNELS..];
            for (s, t) in frame.iter_mut().zip(tail) {
                *s = *s * fade_in + t * fade_out;
            }
            done += 1;
        }
        self.mixed = Some(done);
        if done == len {
            self.tail.clear();
            self.mixed = None;
        }
    }

    /// Pushes the rest of a mix the next track ended too soon to finish.
    fn finish_mix(&mut self) -> SinkResult<()> {
        let Some(done) = self.mixed.take() else {
            return Ok(());
        };
        let len = self.tail.len() / CHANNELS;
        let mut rest = std::mem::take(&mut self.tail);
        for (i, frame) in rest.chunks_exact_mut(CHANNELS).enumerate().skip(done) {
            let (fade_out, _) = crossfade_gains(i, len);
            frame.iter_mut().for_each(|s| *s *= fade_out);
        }
        let result = self.push(&rest[done * CHANNELS..]);
        rest.clear();
        self.tail = rest;
        result
    }

    /// Frames at the end of this packet that fall within the crossfade length
    /// of the track's end. Once capture starts it holds everything.
    fn frames_to_hold(&self, requests: &Requests, frames: usize) -> usize {
        if self.mixed.is_some() {
            return 0;
        }
        if !self.tail.is_empty() {
            return frames;
        }
        let Some(total) = self
            .track_frames
            .filter(|_| requests.armed && requests.crossfade_frames > 0)
        else {
            return 0;
        };
        let start = total
            .saturating_sub(requests.crossfade_frames as u64)
            .max(self.written_frames);
        (self.written_frames + frames as u64).saturating_sub(start) as usize
    }

    /// Pushes held frames beyond `cap_frames` from the front of the tail: the
    /// track ran past its reported length, or the setting shrank.
    fn trim_tail(&mut self, cap_frames: usize) -> SinkResult<()> {
        let excess = self.tail.len().saturating_sub(cap_frames * CHANNELS);
        if self.mixed.is_some() || excess == 0 {
            return Ok(());
        }
        let mut tail = std::mem::take(&mut self.tail);
        let result = self.push(&tail[..excess]);
        tail.drain(..excess);
        self.tail = tail;
        result
    }

    fn push(&mut self, samples: &[f32]) -> SinkResult<()> {
        if self.pending.is_empty() {
            return self.push_to_ring(samples);
        }
        let mut all = std::mem::take(&mut self.pending);
        all.extend_from_slice(samples);
        self.push_to_ring(&all)
    }

    /// Blocks while the ring is full: that back-pressure paces the decoder.
    /// While the render side holds a pause it keeps the rest in `pending`
    /// instead, throttled, so librespot can reach its pause command.
    fn push_to_ring(&mut self, mut samples: &[f32]) -> SinkResult<()> {
        let mut renders = self.stats.renders.load(Relaxed);
        let mut stalled = Duration::ZERO;
        while !samples.is_empty() {
            if self.producer.is_abandoned() {
                return Err(SinkError::NotConnected("render handle released".into()));
            }
            let (_, rest) = self.producer.push_partial_slice(samples);
            self.pushed += (samples.len() - rest.len()) as u64;
            if rest.len() == samples.len() {
                if self.stats.render_holding.load(Acquire) {
                    std::thread::sleep(WRITE_RETRY);
                    if self.pending.len() + samples.len() > PENDING_MAX_SAMPLES {
                        // librespot pauses on a write error.
                        return Err(SinkError::OnWrite("held audio exceeds its cap".into()));
                    }
                    self.pending.extend_from_slice(samples);
                    return Ok(());
                }
                let now = self.stats.renders.load(Relaxed);
                if now == renders {
                    stalled += WRITE_RETRY;
                    if stalled >= STALL_TIMEOUT {
                        return Err(SinkError::OnWrite("audio output stopped rendering".into()));
                    }
                } else {
                    renders = now;
                    stalled = Duration::ZERO;
                }
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
        self.stats.held.store(false, Relaxed);
        self.stats.pausing.store(false, Relaxed);
        self.stats.render_holding.store(false, Release);
        self.stats.starts.fetch_add(1, Release);
        // A play-out whose stop never came must not skip the next pause hold.
        self.transitions.take_play_out();
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        self.stats.active.store(false, Relaxed);
        if self.transitions.take_play_out() {
            // shortcut: a tail held for a next track the queue lost since
            // the preload is dropped; flushing it would block this thread.
            self.tail.clear();
            self.mixed = None;
            self.mark();
        } else {
            self.stats.held.store(true, Release);
        }
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        self.write_packet(packet, converter, true)
    }
}

/// Equal-power gains (outgoing, incoming) at `frame` of a `len`-frame fade.
fn crossfade_gains(frame: usize, len: usize) -> (f32, f32) {
    let angle = frame as f32 / len as f32 * std::f32::consts::FRAC_PI_2;
    (angle.cos(), angle.sin())
}

/// Render-thread state only; the producer and control side reach it
/// through `AudioStats` atomics.
pub struct RenderHandle {
    consumer: Consumer<f32>,
    stats: Arc<AudioStats>,
    popped: u64,
    /// The latest `cut_at` seen; samples before it are dropped.
    cut: u64,
    fades_seen: u64,
    cuts_seen: u64,
    starts_seen: u64,
    /// Dropping everything until a newer cut arrives.
    muted: bool,
    /// Paused by librespot: the rest stays queued until `start`.
    holding: bool,
    /// Fading live audio for a pause, then holding.
    pausing: bool,
    /// Output gain in frames of a full ramp: `FADE_FRAMES` is unity, and a
    /// fade-in adds exactly 1 per frame.
    level: f32,
    /// Levels per frame while fading out; 0 until silenced.
    step: f32,
}

impl RenderHandle {
    fn render(&mut self, left: &mut [f32], right: &mut [f32]) -> usize {
        self.stats.renders.fetch_add(1, Relaxed);
        let frames = left.len().min(right.len());
        self.follow_requests();
        let mut n = 0;
        let mut dropped = false;
        let mut idle = false;
        while n < frames {
            let available = self.consumer.slots() / CHANNELS;
            if available == 0 {
                break;
            }
            if !self.is_silenced() {
                let k = available.min(frames - n);
                self.read(&mut left[n..n + k], &mut right[n..n + k], false);
                n += k;
            } else if self.level > 0.0 {
                let mut k = available
                    .min(frames - n)
                    .min((self.level / self.step).ceil() as usize);
                if !self.muted && !self.holding && !self.pausing {
                    k = k.min(self.before_cut());
                }
                self.read(&mut left[n..n + k], &mut right[n..n + k], true);
                n += k;
            } else if self.holding || self.pausing {
                idle = true;
                break;
            } else {
                let k = if self.muted {
                    available
                } else {
                    available.min(self.before_cut())
                };
                if let Ok(chunk) = self.consumer.read_chunk(k * CHANNELS) {
                    chunk.commit_all();
                }
                self.popped += (k * CHANNELS) as u64;
                dropped = true;
            }
        }
        left[n..].fill(0.0);
        right[n..].fill(0.0);
        self.stats.render_holding.store(idle, Release);

        if dropped {
            // The producer refills after a cut; that gap is not an underrun.
            self.stats.primed.store(false, Relaxed);
        } else if self.stats.active.load(Relaxed) {
            let primed = self.stats.primed.load(Relaxed);
            if primed && n < frames {
                self.stats.underruns.fetch_add(1, Relaxed);
            } else if !primed && n > 0 {
                self.stats.primed.store(true, Relaxed);
            }
        }
        n
    }

    fn before_cut(&self) -> usize {
        self.cut.saturating_sub(self.popped) as usize / CHANNELS
    }

    fn is_silenced(&self) -> bool {
        self.muted || self.holding || self.pausing || self.before_cut() > 0
    }

    /// Picks the fade-out slope when a request silences output. A pause
    /// fades live audio over `FADE`; anything else fades only what is queued.
    fn follow_requests(&mut self) {
        let was_silenced = self.is_silenced();
        let starts = self.stats.starts.load(Acquire);
        if starts != self.starts_seen {
            self.starts_seen = starts;
            // A resume ramps up from where the hold left the gain.
            if !self.holding && !self.pausing {
                self.level = 0.0;
            }
            self.holding = false;
        }
        if self.stats.held.load(Acquire) {
            self.holding = true;
        }
        self.pausing = self.stats.pausing.load(Acquire);
        let fades = self.stats.fade_requests.load(Acquire);
        if fades != self.fades_seen {
            self.fades_seen = fades;
            self.muted = true;
        }
        let cuts = self.stats.cuts.load(Acquire);
        if cuts != self.cuts_seen {
            self.cuts_seen = cuts;
            self.cut = self.stats.cut_at.load(Acquire);
            self.muted = false;
            if !self.is_silenced() {
                // Nothing of the old position is left to fade out.
                self.level = 0.0;
            }
        }
        if !self.is_silenced() {
            self.step = 0.0;
            return;
        }
        let live = self.pausing && !self.muted && self.before_cut() == 0;
        if live {
            if !was_silenced || self.step == 0.0 {
                self.step = 1.0;
            }
            return;
        }
        let queued = self.consumer.slots() / CHANNELS;
        let scope = if self.muted || self.holding {
            queued
        } else {
            queued.min(self.before_cut())
        };
        if scope == 0 {
            self.level = 0.0;
            return;
        }
        if !was_silenced || self.step == 0.0 {
            self.step = self.level / (scope as f32).min(self.level.ceil()).max(1.0);
        }
        // Reach silence before the queued audio runs out.
        if self.level / self.step > scope as f32 {
            self.step = self.level / scope as f32;
        }
    }

    /// Pops `left.len()` frames, which the caller checked are queued, ramping
    /// the gain down by `step` or up by one level per frame.
    fn read(&mut self, left: &mut [f32], right: &mut [f32], fading: bool) {
        let Ok(chunk) = self.consumer.read_chunk(left.len() * CHANNELS) else {
            return;
        };
        let mut samples = chunk.into_iter();
        let full = FADE_FRAMES as f32;
        for (l, r) in left.iter_mut().zip(right.iter_mut()) {
            let gain = if fading {
                self.level = (self.level - self.step).max(0.0);
                self.level / full
            } else {
                let gain = self.level / full;
                self.level = (self.level + 1.0).min(full);
                gain
            };
            *l = samples.next().unwrap_or(0.0) * gain;
            *r = samples.next().unwrap_or(0.0) * gain;
        }
        self.popped += (left.len() * CHANNELS) as u64;
    }
}

/// Fills `frames` samples of planar `left` and `right` from the ring, padding
/// with silence, and returns how many frames came from the ring. Real-time
/// safe: no locks, no allocation.
///
/// # Safety
/// `handle` comes from `AudioOutput::take_render_handle`, is not freed and is
/// used by one thread at a time; `left` and `right` each point to `frames`
/// writable, properly aligned floats, and the two ranges do not overlap.
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
    fn write_fails_when_a_full_ring_stops_being_rendered() {
        let (_output, mut sink, _handle) = setup();
        let too_many = vec![0.0; RING_SAMPLES + CHANNELS];
        let started = std::time::Instant::now();

        let result = sink.write(AudioPacket::Samples(too_many), &mut Converter::new(None));

        assert!(matches!(result, Err(SinkError::OnWrite(_))));
        assert!(started.elapsed() >= STALL_TIMEOUT);
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

    fn render_all(handle: &mut RenderHandle) -> Vec<(f32, f32)> {
        let mut out = Vec::new();
        loop {
            let (n, left, right) = render(handle, 512);
            if n == 0 {
                return out;
            }
            out.extend(left.into_iter().zip(right).take(n));
        }
    }

    fn write_frames(sink: &mut CoreAudioSink, frames: usize, value: f64) {
        sink.write(
            packet(&vec![value; frames * CHANNELS]),
            &mut Converter::new(None),
        )
        .unwrap();
    }

    /// FNV-1a over the frames as interleaved little-endian f32.
    fn fnv(frames: &[(f32, f32)]) -> u64 {
        frames
            .iter()
            .flat_map(|(l, r)| [l.to_le_bytes(), r.to_le_bytes()])
            .flatten()
            .fold(0xcbf2_9ce4_8422_2325, |h, b| {
                (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
            })
    }

    /// Recorded from the sink before ADR-010: 5000 frames written in 256-frame
    /// packets, rendered without a `start`.
    const GAPLESS_HASH: u64 = 0xcae2_f4c1_dda1_1e19;

    fn gapless_signal() -> Vec<f64> {
        (0..5000 * CHANNELS)
            .map(|i| (i as f64 * 0.013).sin() * 0.8)
            .collect()
    }

    fn play_gapless_pair(sink: &mut CoreAudioSink) {
        let transitions = sink.transitions();
        transitions.arm();
        transitions.track(60, 0);
        let mut converter = Converter::new(None);
        for (i, chunk) in gapless_signal().chunks(256 * CHANNELS).enumerate() {
            if i == 12 {
                transitions.boundary();
            }
            sink.write(packet(chunk), &mut converter).unwrap();
        }
    }

    #[test]
    fn crossfade_zero_plays_the_recorded_gapless_stream() {
        let (_output, mut sink, mut handle) = setup();
        play_gapless_pair(&mut sink);
        assert_eq!(fnv(&render_all(&mut handle)), GAPLESS_HASH);

        let (_output, mut sink, mut handle) = setup();
        sink.start().unwrap();
        play_gapless_pair(&mut sink);
        let out = render_all(&mut handle);
        assert_eq!(out.len(), 5000);
        let signal = gapless_signal();
        for (k, (l, _)) in out.iter().enumerate() {
            let expected = signal[k * CHANNELS] as f32 * (k as f32 / FADE_FRAMES as f32);
            assert_eq!(*l, expected, "fade-in frame {k}");
        }
    }

    #[test]
    fn set_crossfade_clamps_to_twelve_seconds() {
        let transitions = Transitions::new(Arc::default());
        transitions.set_crossfade(200);
        assert_eq!(
            transitions.take().crossfade_frames,
            12 * SAMPLE_RATE as usize
        );
        transitions.set_crossfade(0);
        assert_eq!(transitions.take().crossfade_frames, 0);
    }

    /// A 300-frame track with a 100-frame crossfade, its next track preloaded.
    fn armed_sink() -> (Arc<AudioOutput>, CoreAudioSink, Box<RenderHandle>) {
        let (output, sink, handle) = setup();
        sink.transitions.update(|r| {
            r.crossfade_frames = 100;
            r.armed = true;
            r.track = Some((300, 0));
        });
        (output, sink, handle)
    }

    #[test]
    fn the_track_end_is_held_back_without_blocking() {
        let (_output, mut sink, mut handle) = armed_sink();

        write_frames(&mut sink, 250, 0.5);
        assert_eq!(render_all(&mut handle).len(), 200);
        assert_eq!(sink.tail.len(), 50 * CHANNELS);

        // Longer than reported: the oldest held frames go out first.
        write_frames(&mut sink, 100, 0.5);
        assert_eq!(render_all(&mut handle).len(), 50);
        assert_eq!(sink.tail.len(), 100 * CHANNELS);
    }

    #[test]
    fn nothing_is_held_unless_the_next_track_is_preloaded() {
        let (_output, mut sink, mut handle) = armed_sink();
        sink.transitions.update(|r| r.armed = false);

        write_frames(&mut sink, 300, 0.5);

        assert_eq!(render_all(&mut handle).len(), 300);
        assert!(sink.tail.is_empty());
    }

    #[test]
    fn equal_power_gains_keep_the_sum_of_squares_at_one() {
        assert_eq!(crossfade_gains(0, 100), (1.0, 0.0));
        let mut last_out = 1.0;
        for i in 0..100 {
            let (fade_out, fade_in) = crossfade_gains(i, 100);
            assert!((fade_out * fade_out + fade_in * fade_in - 1.0).abs() < 1e-6);
            assert!(fade_out <= last_out);
            last_out = fade_out;
        }
    }

    #[test]
    fn the_next_track_head_is_mixed_into_the_tail_then_passes_through() {
        let (_output, mut sink, mut handle) = armed_sink();
        write_frames(&mut sink, 300, 0.5);
        assert_eq!(render_all(&mut handle).len(), 200);

        sink.transitions.boundary();
        write_frames(&mut sink, 150, 0.25);
        let out = render_all(&mut handle);

        assert_eq!(out.len(), 150);
        for (i, (l, r)) in out[..100].iter().enumerate() {
            let (fade_out, fade_in) = crossfade_gains(i, 100);
            let expected = 0.25 * fade_in + 0.5 * fade_out;
            assert!(
                (l - expected).abs() < 1e-6 && (r - expected).abs() < 1e-6,
                "frame {i}"
            );
        }
        assert!(out[100..].iter().all(|&s| s == (0.25, 0.25)));
        assert!(sink.tail.is_empty());
        assert!(!sink.transitions.take().armed);
    }

    #[test]
    fn a_short_next_track_still_plays_out_the_tail() {
        let (_output, mut sink, mut handle) = armed_sink();
        write_frames(&mut sink, 300, 0.5);
        render_all(&mut handle);

        sink.transitions.boundary();
        write_frames(&mut sink, 40, 0.0);
        sink.transitions.boundary();
        write_frames(&mut sink, 10, 0.0);
        let out = render_all(&mut handle);

        assert_eq!(out.len(), 40 + 60 + 10);
        let (fade_out, _) = crossfade_gains(40, 100);
        assert!((out[40].0 - 0.5 * fade_out).abs() < 1e-6);
    }

    /// Writes `frames` in 512-frame packets valued by `value(index)`,
    /// rendering 512 frames after each, as a live stream does.
    fn stream(
        sink: &mut CoreAudioSink,
        handle: &mut RenderHandle,
        frames: std::ops::Range<usize>,
        value: fn(usize) -> f64,
    ) -> Vec<(f32, f32)> {
        let mut out = Vec::new();
        for start in frames.step_by(512) {
            let samples: Vec<f64> = (start..start + 512).flat_map(|i| [value(i); 2]).collect();
            sink.write(packet(&samples), &mut Converter::new(None))
                .unwrap();
            let (n, left, right) = render(handle, 512);
            out.extend(left.into_iter().zip(right).take(n));
        }
        out
    }

    /// Whole 512-frame packets that reach past the fade.
    const PAST_FADE: usize = (FADE_FRAMES / 512 + 1) * 512;

    fn one(_: usize) -> f64 {
        1.0
    }

    #[test]
    fn a_discontinuity_drops_the_tail_and_fades_in() {
        let (_output, mut sink, mut handle) = armed_sink();
        write_frames(&mut sink, 300, 0.5);
        render_all(&mut handle);

        sink.transitions.discontinuity();
        sink.transitions.confirm();
        let mut out = stream(&mut sink, &mut handle, 0..PAST_FADE, one);
        out.extend(render_all(&mut handle));

        assert_eq!(out.len(), PAST_FADE);
        assert_eq!(out[0], (0.0, 0.0));
        assert!(out[FADE_FRAMES..].iter().all(|&s| s == (1.0, 1.0)));
        assert!(sink.tail.is_empty());
        assert!(!sink.transitions.take().armed);
    }

    #[test]
    fn a_seek_after_the_preload_still_crossfades() {
        let (_output, mut sink, mut handle) = armed_sink();
        write_frames(&mut sink, 100, 0.5);

        sink.transitions.seek();
        sink.transitions.confirm();
        sink.transitions.update(|r| r.track = Some((300, 150)));
        write_frames(&mut sink, 150, 0.5);
        render_all(&mut handle);

        assert_eq!(sink.tail.len(), 100 * CHANNELS);
    }

    /// A linear ramp from just under unity to 0 over `len` frames.
    fn assert_fades_out(out: &[(f32, f32)], len: usize) {
        assert_eq!(out.len(), len);
        for (k, (l, _)) in out.iter().enumerate() {
            let expected = (len - 1 - k) as f32 / len as f32;
            assert!((l - expected).abs() < 1e-4, "frame {k}: {l} vs {expected}");
        }
        assert_eq!(out[len - 1].0, 0.0);
    }

    #[test]
    fn a_discontinuity_fades_out_the_queue_before_any_write() {
        let (_output, mut sink, mut handle) = setup();
        write_frames(&mut sink, 2000, 1.0);
        render(&mut handle, 100);

        sink.transitions.discontinuity();

        assert_fades_out(&render_all(&mut handle), 1900);
        assert_eq!(handle.consumer.slots(), 0);
    }

    #[test]
    fn packets_decoded_before_the_command_are_dropped() {
        let (_output, mut sink, mut handle) = setup();
        write_frames(&mut sink, 100, 1.0);
        render_all(&mut handle);
        sink.transitions.discontinuity();
        render_all(&mut handle);

        write_frames(&mut sink, 50, 0.5);
        assert!(render_all(&mut handle).is_empty(), "stale audio plays");

        sink.transitions.confirm();
        let mut out = stream(&mut sink, &mut handle, 0..PAST_FADE, one);
        out.extend(render_all(&mut handle));
        assert_eq!(out.len(), PAST_FADE);
        assert_eq!(out[0], (0.0, 0.0));
        assert!(out[FADE_FRAMES..].iter().all(|&s| s == (1.0, 1.0)));
    }

    #[test]
    fn a_cut_with_nothing_pushed_since_the_last_one_still_plays_the_new_audio() {
        let (_output, mut sink, mut handle) = setup();
        // A paused restore: a cut that writes nothing, as a paused load decodes nothing.
        sink.transitions.discontinuity();
        sink.transitions.confirm();
        render_all(&mut handle);

        sink.transitions.discontinuity();
        sink.transitions.confirm();
        let mut out = stream(&mut sink, &mut handle, 0..PAST_FADE, one);
        out.extend(render_all(&mut handle));

        assert_eq!(out.len(), PAST_FADE, "new audio is dropped");
        assert_eq!(out[PAST_FADE - 1], (1.0, 1.0));
    }

    #[test]
    fn the_first_position_counts_frames_written_before_it_arrived() {
        let (_output, mut sink, mut handle) = setup();
        sink.transitions.boundary();
        sink.transitions.update(|r| {
            r.crossfade_frames = 100;
            r.armed = true;
        });
        write_frames(&mut sink, 50, 0.5);

        sink.transitions.update(|r| r.track = Some((300, 0)));
        write_frames(&mut sink, 200, 0.5);

        assert_eq!(sink.tail.len(), 50 * CHANNELS);
        assert_eq!(render_all(&mut handle).len(), 200);
    }

    #[test]
    fn a_boundary_drops_the_outgoing_track_position() {
        let (_output, mut sink, mut handle) = setup();
        sink.transitions.update(|r| {
            r.crossfade_frames = 100;
            r.track = Some((100, 0));
        });

        sink.transitions.boundary();
        sink.transitions.arm();
        write_frames(&mut sink, 300, 0.5);

        assert!(sink.tail.is_empty());
        assert_eq!(render_all(&mut handle).len(), 300);
    }

    #[test]
    fn a_context_end_plays_out_the_queue_and_clears_the_tail() {
        let (_output, mut sink, mut handle) = armed_sink();
        write_frames(&mut sink, 300, 0.5);

        sink.transitions.play_out();
        sink.stop().unwrap();

        let out = render_all(&mut handle);
        assert_eq!(out.len(), 200);
        assert!(out.iter().all(|&s| s == (0.5, 0.5)));
        assert!(sink.tail.is_empty());
        assert!(!sink.transitions.take().armed);
    }

    #[test]
    fn a_play_out_the_stop_never_consumed_does_not_skip_a_later_pause_hold() {
        let (_output, mut sink, _handle) = setup();
        sink.transitions.play_out();
        sink.transitions.discontinuity();
        sink.stop().unwrap();
        assert!(sink.stats.held.load(Acquire));

        sink.transitions.play_out();
        sink.start().unwrap();
        sink.stop().unwrap();
        assert!(sink.stats.held.load(Acquire));
    }

    #[test]
    fn connect_playback_never_crossfades() {
        let (_output, mut sink, mut handle) = armed_sink();
        write_frames(&mut sink, 300, 0.5);
        render_all(&mut handle);

        sink.transitions.update(|r| r.armed = true);
        sink.write_gapless(packet(&[0.25; 300 * CHANNELS]), &mut Converter::new(None))
            .unwrap();

        let out = render_all(&mut handle);
        assert_eq!(out.len(), 300);
        assert!(out.iter().all(|&s| s == (0.25, 0.25)));
        assert!(sink.tail.is_empty());
    }

    #[test]
    fn connect_playback_after_an_unconfirmed_discontinuity_cuts_once() {
        let (_output, mut sink, mut handle) = setup();
        sink.transitions.discontinuity();
        let cuts = sink.stats.cuts.load(Acquire);

        let mut out = Vec::new();
        for _ in 0..PAST_FADE / 512 {
            sink.write_gapless(packet(&[1.0; 512 * CHANNELS]), &mut Converter::new(None))
                .unwrap();
            let (n, left, right) = render(&mut handle, 512);
            out.extend(left.into_iter().zip(right).take(n));
        }
        out.extend(render_all(&mut handle));

        assert!(sink.stats.cuts.load(Acquire) - cuts <= 1);
        assert_eq!(out.len(), PAST_FADE);
        assert!(out[FADE_FRAMES..].iter().all(|&s| s == (1.0, 1.0)));
    }

    #[test]
    fn fades_last_300_ms() {
        assert_eq!(FADE.as_millis(), 300);
        assert_eq!(FADE_FRAMES, SAMPLE_RATE as usize * 300 / 1000);
    }

    #[test]
    fn start_ramps_the_first_frames_up_from_silence() {
        let (_output, mut sink, mut handle) = setup();
        sink.start().unwrap();
        let mut out = stream(&mut sink, &mut handle, 0..PAST_FADE, one);
        out.extend(render_all(&mut handle));

        assert_eq!(out.len(), PAST_FADE);
        for (k, (l, r)) in out.iter().enumerate() {
            let gain = (k as f32 / FADE_FRAMES as f32).min(1.0);
            assert_eq!((*l, *r), (gain, gain), "frame {k}");
        }
    }

    #[test]
    fn held_audio_is_capped_when_the_engine_stops_while_paused() {
        let (_output, mut sink, _handle) = setup();
        sink.stats.render_holding.store(true, Release);
        let chunk = vec![0.0; RING_SAMPLES / 2];
        let mut failed = false;
        for _ in 0..16 {
            failed |= sink
                .write(packet(&chunk), &mut Converter::new(None))
                .is_err();
        }
        assert!(failed, "writes fail once the held audio hits its cap");
        assert!(sink.pending.len() <= PENDING_MAX_SAMPLES);

        sink.start().unwrap();
        assert!(!sink.stats.render_holding.load(Acquire));
    }

    #[test]
    fn a_librespot_stop_fades_out_what_is_queued() {
        let (_output, mut sink, mut handle) = setup();
        write_frames(&mut sink, 3000, 1.0);
        render(&mut handle, 1000);

        sink.stop().unwrap();

        assert_fades_out(&render_all(&mut handle), 2000);
    }

    fn index(i: usize) -> f64 {
        i as f64 * 1e-5
    }

    #[test]
    fn a_pause_fades_live_audio_then_holds_it_and_loses_nothing() {
        let (_output, mut sink, mut handle) = setup();
        let transitions = sink.transitions();
        let mut out = stream(&mut sink, &mut handle, 0..4096, index);

        let generation = transitions.begin_pause().unwrap();
        let end = 4096 + FADE_FRAMES / 512 * 512 + 16 * 1024;
        out.extend(stream(&mut sink, &mut handle, 4096..end, index));
        assert_eq!(
            out.len(),
            4096 + FADE_FRAMES,
            "the fade lasts 300 ms, then holds"
        );
        for (k, (l, _)) in out[4096..].iter().enumerate() {
            let gain = (FADE_FRAMES - 1 - k) as f32 / FADE_FRAMES as f32;
            assert_eq!(*l, index(4096 + k) as f32 * gain, "frame {k}");
        }
        assert!(!sink.pending.is_empty(), "writes never block while held");

        // librespot handles the pause command later, on its own thread.
        let mut paused = false;
        transitions.finish_pause(generation, || paused = true);
        assert!(paused);
        sink.stop().unwrap();
        assert!(!transitions.cancel_pause(), "librespot already paused");
        sink.start().unwrap();
        // The held ring and the pending audio go out first, so the writer
        // blocks until the render side drains them, as on real hardware.
        let writer = std::thread::spawn(move || {
            for start in (end..end + 4096).step_by(512) {
                let samples: Vec<f64> = (start..start + 512).flat_map(|i| [index(i); 2]).collect();
                sink.write(packet(&samples), &mut Converter::new(None))
                    .unwrap();
            }
        });
        let mut resumed = Vec::new();
        while !writer.is_finished() {
            let (n, left, right) = render(&mut handle, 512);
            resumed.extend(left.into_iter().zip(right).take(n));
        }
        writer.join().unwrap();
        resumed.extend(render_all(&mut handle));

        assert_eq!(resumed[0].0, 0.0, "resume fades in");
        out.extend(resumed);
        assert_eq!(out.len(), end + 4096, "nothing is lost");
        let last = out.len() - 1;
        assert_eq!(out[last].0, index(last) as f32);
    }

    #[test]
    fn a_play_during_the_pause_fade_ramps_up_from_the_current_gain() {
        let (_output, mut sink, mut handle) = setup();
        let transitions = sink.transitions();
        stream(&mut sink, &mut handle, 0..4096, one);
        let generation = transitions.begin_pause().unwrap();
        let fading = stream(&mut sink, &mut handle, 0..2048, one);

        assert!(transitions.cancel_pause(), "librespot never paused");
        let rising = stream(&mut sink, &mut handle, 0..2048, one);
        transitions.finish_pause(generation, || panic!("a cancelled pause ran"));

        let low = fading[2047].0;
        assert_eq!(low, (FADE_FRAMES - 2048) as f32 / FADE_FRAMES as f32);
        assert_eq!(rising[0].0, low, "no jump");
        assert!(rising.windows(2).all(|w| w[1].0 > w[0].0));
        assert!(rising[2047].0 < 1.0);
    }

    #[test]
    fn a_second_pause_during_the_fade_keeps_the_first() {
        let (_output, mut sink, mut handle) = setup();
        let transitions = sink.transitions();
        stream(&mut sink, &mut handle, 0..4096, one);
        let generation = transitions.begin_pause().unwrap();
        let first = stream(&mut sink, &mut handle, 0..2048, one);

        assert_eq!(transitions.begin_pause(), None);
        let second = stream(&mut sink, &mut handle, 0..2048, one);

        assert_eq!(second[0].0, first[2047].0 - 1.0 / FADE_FRAMES as f32);
        let mut paused = false;
        transitions.finish_pause(generation, || paused = true);
        assert!(paused);
    }

    #[test]
    fn a_cut_during_the_pause_fade_cancels_it_and_fades_out_the_queue() {
        let (_output, mut sink, mut handle) = setup();
        let transitions = sink.transitions();
        write_frames(&mut sink, 4000, 1.0);
        let generation = transitions.begin_pause().unwrap();
        let (_, before, _) = render(&mut handle, 1000);

        assert!(transitions.discontinuity());
        let rest = render_all(&mut handle);

        assert_eq!(rest.len(), 3000);
        assert!(rest[0].0 < before[999]);
        assert!(rest.windows(2).all(|w| w[1].0 <= w[0].0));
        assert_eq!(rest[2999].0, 0.0);
        transitions.finish_pause(generation, || panic!("a cancelled pause ran"));

        transitions.confirm();
        write_frames(&mut sink, 10, 1.0);
        assert_eq!(render(&mut handle, 10).0, 10, "the new position plays");
    }

    #[test]
    fn a_discontinuity_with_little_queued_shortens_the_ramp() {
        let (_output, mut sink, mut handle) = setup();
        write_frames(&mut sink, 10, 1.0);

        sink.transitions.discontinuity();

        assert_fades_out(&render_all(&mut handle), 10);
    }

    #[test]
    fn a_discontinuity_during_a_fade_extends_it_without_raising_the_gain() {
        let (_output, mut sink, mut handle) = setup();
        write_frames(&mut sink, 2000, 1.0);
        sink.transitions.discontinuity();
        let (_, first, _) = render(&mut handle, 100);

        write_frames(&mut sink, 100, 1.0);
        sink.transitions.discontinuity();
        let rest = render_all(&mut handle);

        assert_eq!(rest.len(), 1900);
        assert!(rest[0].0 < first[99]);
        assert_eq!(handle.consumer.slots(), 0);
    }
}
