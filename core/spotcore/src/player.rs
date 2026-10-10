//! Playback control over librespot's `Player`, fed through `AudioOutput`.
//!
//! A loaded URI expands to an ordered track list (the context) held by
//! `Queue` with Up Next, shuffle and repeat; `next` and `previous` walk it,
//! the end of a track advances it, and an exhausted context continues with
//! Spotify's autoplay radio for it.

use std::sync::atomic::{AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use librespot_core::{Session, SpotifyUri};
use librespot_metadata::{Album, Artist, Metadata, Playlist};
use librespot_playback::audio_backend::{Sink, SinkResult};
use librespot_playback::config::{self, NormalisationMethod, PlayerConfig};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent, PlayerEventChannel};
use librespot_protocol::autoplay_context_request::AutoplayContextRequest;
use librespot_protocol::context::Context;
use log::{info, warn};
use tokio::sync::watch;

use crate::audio::{AudioOutput, CoreAudioSink};
use crate::queue::{Queue, RepeatMode};
use crate::session::SpotSession;

const POSITION_INTERVAL: Duration = Duration::from_secs(1);
/// Past this point `previous` restarts the track instead of going back.
const RESTART_THRESHOLD_MS: u32 = 3_000;
/// Played tracks sent with an autoplay request so the radio skips them.
const RECENT_TRACKS: usize = 20;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PlayerError {
    #[error("invalid Spotify URI: {message}")]
    InvalidUri { message: String },
    #[error("nothing playable in {uri}")]
    EmptyContext { uri: String },
    #[error("metadata request failed: {message}")]
    Metadata { message: String },
    #[error("the audio output already feeds a player")]
    OutputTaken,
    #[error("no Up Next entry at {index}")]
    OutOfRange { index: u32 },
}

/// Spotify's loudness levels: Quiet is about -19 LUFS, Normal -14, Loud -11.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LoudnessPreset {
    Quiet,
    Normal,
    Loud,
}

/// Ogg Vorbis stream bitrate requested from Spotify.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Bitrate {
    Kbps96,
    Kbps160,
    Kbps320,
}

/// Player settings librespot fixes when the player is created.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Tuning {
    normalisation: Option<LoudnessPreset>,
    bitrate: Bitrate,
}

/// URIs are canonical `spotify:` strings.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum PlaybackEvent {
    Loading {
        uri: String,
        position_ms: u32,
    },
    Playing {
        uri: String,
        position_ms: u32,
    },
    Paused {
        uri: String,
        position_ms: u32,
    },
    /// Every second while playing, and after a seek.
    Position {
        uri: String,
        position_ms: u32,
    },
    TrackChanged {
        uri: String,
        name: String,
        duration_ms: u32,
    },
    EndOfTrack {
        uri: String,
    },
    Unavailable {
        uri: String,
    },
    Stopped,
}

/// Called on a tokio worker thread, in the order the player emits events.
#[uniffi::export(with_foreign)]
pub trait PlayerObserver: Send + Sync {
    fn on_event(&self, event: PlaybackEvent);
}

/// What is playing and what comes next. URIs are canonical `spotify:` strings.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QueueSnapshot {
    pub current: Option<String>,
    pub up_next: Vec<String>,
    pub next_from_context: Vec<String>,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub autoplay: bool,
}

/// Playback position extrapolated from the last player event, so `previous`
/// can tell how far into the track it is between 1 s position ticks.
#[derive(Default)]
struct Clock {
    position_ms: u32,
    reported_at: Option<Instant>,
    playing: bool,
    /// A track is loaded in the player, playing or paused.
    active: bool,
    /// Last play or pause the user asked for; unlike `playing` it holds
    /// through `Loading`.
    wants_play: bool,
}

impl Clock {
    fn note(&mut self, event: &PlaybackEvent) {
        let (position_ms, playing) = match event {
            PlaybackEvent::Playing { position_ms, .. } => (*position_ms, true),
            PlaybackEvent::Paused { position_ms, .. }
            | PlaybackEvent::Loading { position_ms, .. } => (*position_ms, false),
            PlaybackEvent::Position { position_ms, .. } => (*position_ms, self.playing),
            PlaybackEvent::Stopped => (0, false),
            _ => return,
        };
        let wants_play = match event {
            PlaybackEvent::Playing { .. } => true,
            PlaybackEvent::Paused { .. } | PlaybackEvent::Stopped => false,
            _ => self.wants_play,
        };
        *self = Self {
            position_ms,
            reported_at: Some(Instant::now()),
            playing,
            active: !matches!(event, PlaybackEvent::Stopped),
            wants_play,
        };
    }

    /// Extrapolates at most one tick interval: librespot reports position as
    /// it decodes, so a longer silence means a stalled stream, not progress.
    fn position_ms(&self) -> u32 {
        let since = match self.reported_at {
            Some(at) if self.playing => at.elapsed().min(POSITION_INTERVAL).as_millis(),
            _ => 0,
        };
        self.position_ms
            .saturating_add(u32::try_from(since).unwrap_or(u32::MAX))
    }
}

struct State {
    queue: Queue,
    /// URI the context was loaded from; autoplay radio is seeded from it.
    context_uri: Option<SpotifyUri>,
    autoplay: bool,
    /// Bumped by every user-initiated load, so an autoplay fetch that
    /// finishes afterwards does not replace what the user chose.
    generation: u64,
    clock: Clock,
    /// Events from earlier play requests are stale: their end of track must
    /// not advance the queue a second time.
    request_id: Option<u64>,
    /// Session the player was last given; replaced after a reconnect.
    session_id: String,
}

#[derive(uniffi::Object)]
pub struct SpotPlayer {
    session: Arc<SpotSession>,
    /// Replaced when `tuning` changes, as librespot fixes it at creation.
    player: Mutex<Arc<Player>>,
    tuning: Mutex<Tuning>,
    sink: Arc<Mutex<CoreAudioSink>>,
    epoch: Epoch,
    mixer: SoftMixer,
    observer: Arc<dyn PlayerObserver>,
    state: Arc<Mutex<State>>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[uniffi::export(async_runtime = "tokio")]
impl SpotPlayer {
    /// Async so librespot's tasks spawn on the UniFFI tokio runtime.
    /// `normalisation` of `None` plays tracks at their mastered loudness.
    #[uniffi::constructor]
    pub async fn new(
        session: Arc<SpotSession>,
        output: Arc<AudioOutput>,
        observer: Arc<dyn PlayerObserver>,
        volume: u16,
        normalisation: Option<LoudnessPreset>,
        bitrate: Bitrate,
    ) -> Result<Arc<Self>, PlayerError> {
        let tuning = Tuning {
            normalisation,
            bitrate,
        };
        let sink = Arc::new(Mutex::new(
            output.take_sink().ok_or(PlayerError::OutputTaken)?,
        ));
        let mixer = soft_mixer(volume);
        let epoch = Epoch {
            current: Arc::default(),
            mine: 0,
        };
        // Subscribe first so a reconnect between the two calls is not missed.
        let links = session.link_changes();
        let link = session.current_session();
        let state = Arc::new(Mutex::new(State {
            queue: Queue::default(),
            context_uri: None,
            autoplay: true,
            generation: 0,
            clock: Clock::default(),
            request_id: None,
            session_id: link.session_id(),
        }));
        let shared = SharedSink {
            sink: Arc::clone(&sink),
            epoch: epoch.clone(),
        };
        let player = spawn_player(&session, link, shared, &mixer, &state, &observer, tuning);
        let this = Arc::new(Self {
            session,
            player: Mutex::new(player),
            tuning: Mutex::new(tuning),
            sink,
            epoch,
            mixer,
            observer,
            state,
        });
        tokio::spawn(restore_after_reconnects(links, Arc::downgrade(&this)));
        Ok(this)
    }

    /// App volume on a logarithmic curve, independent of the system volume.
    pub fn set_volume(&self, volume: u16) {
        self.mixer.set_volume(volume);
    }

    /// Rebuilds the librespot player with the new normaliser settings and
    /// resumes the current track where it was. `None` turns normalisation off.
    pub async fn set_normalisation(&self, normalisation: Option<LoudnessPreset>) {
        self.retune(|t| t.normalisation = normalisation);
    }

    /// Rebuilds the player like `set_normalisation`; the current track
    /// restarts its download at the new bitrate.
    pub async fn set_bitrate(&self, bitrate: Bitrate) {
        self.retune(|t| t.bitrate = bitrate);
    }

    /// Expands `uri` (track, episode, album, playlist or artist top tracks)
    /// and starts its first item at `start_ms`.
    pub async fn load(
        &self,
        uri: String,
        start_ms: u32,
        autoplay: bool,
    ) -> Result<(), PlayerError> {
        let uri = SpotifyUri::from_uri(&uri).map_err(|e| PlayerError::InvalidUri {
            message: e.to_string(),
        })?;
        // Adopt the session only once resolve succeeds: adopting first would
        // make a pending reconnect restore skip, leaving playback dead on failure.
        let tracks = resolve(&self.session.current_session(), &uri).await?;
        self.sync_session();
        let empty = canonical(&uri);
        self.start_context(tracks, None, Some(uri), empty, start_ms, autoplay)
    }

    /// Plays a list the app already holds (Liked Songs, a sorted playlist)
    /// from `uris[start_index]`. `context_uri`, when given, seeds autoplay
    /// radio once the list runs out.
    pub fn load_tracks(
        &self,
        uris: Vec<String>,
        start_index: u32,
        context_uri: Option<String>,
        autoplay: bool,
    ) -> Result<(), PlayerError> {
        let tracks = uris
            .iter()
            .map(|uri| playable(uri))
            .collect::<Result<Vec<_>, _>>()?;
        let context = context_uri
            .map(|uri| {
                SpotifyUri::from_uri(&uri).map_err(|e| PlayerError::InvalidUri {
                    message: e.to_string(),
                })
            })
            .transpose()?;
        if start_index as usize >= tracks.len() {
            return Err(PlayerError::OutOfRange { index: start_index });
        }
        self.sync_session();
        self.start_context(
            tracks,
            Some(start_index as usize),
            context,
            String::new(),
            0,
            autoplay,
        )
    }

    pub fn play(&self) {
        lock(&self.state).clock.wants_play = true;
        self.player().play();
    }

    pub fn pause(&self) {
        lock(&self.state).clock.wants_play = false;
        self.player().pause();
    }

    pub fn seek(&self, position_ms: u32) {
        self.player().seek(position_ms);
    }

    /// Plays Up Next first, then the context. No-op at the end of the
    /// context unless repeat is on.
    pub fn next(&self) {
        self.sync_session();
        let mut state = lock(&self.state);
        if let Some(track) = state.queue.advance(true).cloned() {
            state.generation += 1;
            state.clock.wants_play = true;
            self.player().load(track, true, 0);
        }
    }

    /// Jumps to the `count`th upcoming track (Up Next first, then the
    /// context) with one load, as a queue row click does.
    pub fn skip(&self, count: u32) {
        self.sync_session();
        let mut state = lock(&self.state);
        if let Some(track) = state.queue.skip(count as usize).cloned() {
            state.generation += 1;
            state.clock.wants_play = true;
            self.player().load(track, true, 0);
        }
    }

    /// Restarts the track once it is more than 3 s in, as Spotify does;
    /// otherwise goes back one track.
    pub fn previous(&self) {
        self.sync_session();
        let mut state = lock(&self.state);
        if state.clock.position_ms() > RESTART_THRESHOLD_MS {
            self.player().seek(0);
        } else if let Some(track) = state.queue.back().cloned() {
            state.generation += 1;
            state.clock.wants_play = true;
            self.player().load(track, true, 0);
        }
    }

    /// Puts a track or episode at the front of Up Next.
    pub fn play_next(&self, uri: String) -> Result<(), PlayerError> {
        let track = playable(&uri)?;
        lock(&self.state).queue.play_next(track);
        Ok(())
    }

    /// Puts a track or episode at the end of Up Next.
    pub fn add_to_queue(&self, uri: String) -> Result<(), PlayerError> {
        let track = playable(&uri)?;
        lock(&self.state).queue.add(track);
        Ok(())
    }

    pub fn remove_from_queue(&self, index: u32) -> Result<(), PlayerError> {
        lock(&self.state)
            .queue
            .remove(index as usize)
            .map(drop)
            .ok_or(PlayerError::OutOfRange { index })
    }

    /// Moves the Up Next entry at `from` so it ends up at `to`.
    pub fn move_in_queue(&self, from: u32, to: u32) -> Result<(), PlayerError> {
        if lock(&self.state).queue.reorder(from as usize, to as usize) {
            Ok(())
        } else {
            Err(PlayerError::OutOfRange {
                index: from.max(to),
            })
        }
    }

    pub fn clear_queue(&self) {
        lock(&self.state).queue.clear_up_next();
    }

    pub fn set_shuffle(&self, on: bool) {
        lock(&self.state).queue.set_shuffle(on, seed());
    }

    pub fn set_repeat(&self, mode: RepeatMode) {
        lock(&self.state).queue.repeat = mode;
    }

    /// Whether an exhausted context continues with radio. On by default.
    pub fn set_autoplay(&self, on: bool) {
        lock(&self.state).autoplay = on;
    }

    pub fn queue(&self) -> QueueSnapshot {
        let state = lock(&self.state);
        let q = &state.queue;
        QueueSnapshot {
            current: q.current().map(canonical),
            up_next: q.up_next().map(canonical).collect(),
            next_from_context: q.next_from_context().map(canonical).collect(),
            shuffle: q.shuffle(),
            repeat: q.repeat,
            autoplay: state.autoplay,
        }
    }

    pub fn stop(&self) {
        self.player().stop();
    }
}

impl SpotPlayer {
    /// Starts at `start`, or where `set_context` would (shuffled or first)
    /// without one. `empty_uri` names the context when `tracks` is empty.
    fn start_context(
        &self,
        tracks: Vec<SpotifyUri>,
        start: Option<usize>,
        context_uri: Option<SpotifyUri>,
        empty_uri: String,
        start_ms: u32,
        autoplay: bool,
    ) -> Result<(), PlayerError> {
        let mut state = lock(&self.state);
        match start {
            Some(start) => state.queue.set_context_at(tracks, start, seed()),
            None => state.queue.set_context(tracks, seed()),
        }
        state.context_uri = context_uri;
        state.generation += 1;
        let first = state
            .queue
            .current()
            .cloned()
            .ok_or(PlayerError::EmptyContext { uri: empty_uri })?;
        info!("loading context of {} items", state.queue.tracks().len());
        state.clock.wants_play = autoplay;
        self.player().load(first, autoplay, start_ms);
        Ok(())
    }

    /// Must run on the UniFFI tokio runtime, for `spawn_blocking`.
    fn retune(&self, change: impl FnOnce(&mut Tuning)) {
        // Held throughout so overlapping calls and queue moves serialise.
        let mut state = lock(&self.state);
        let tuning = {
            let mut tuning = lock(&self.tuning);
            change(&mut tuning);
            *tuning
        };
        // From here the old player's writes and events are dropped.
        let epoch = self.epoch.next();
        // Stops an in-flight autoplay fetch from loading into the old player.
        state.generation += 1;
        let resume = resume_point(&state);
        let link = self.session.current_session();
        state.session_id = link.session_id();
        let shared = SharedSink {
            sink: Arc::clone(&self.sink),
            epoch,
        };
        let player = spawn_player(
            &self.session,
            link,
            shared,
            &self.mixer,
            &self.state,
            &self.observer,
            tuning,
        );
        if let Some((track, play, position_ms)) = resume {
            player.load(track, play, position_ms);
        }
        let old = std::mem::replace(&mut *lock(&self.player), player);
        drop(state);
        // `Player::drop` joins its thread; keep that off the async workers.
        tokio::task::spawn_blocking(move || drop(old));
    }

    /// Moves the player onto a reconnected session and restarts the current
    /// track where it was, playing or paused as before. The queue and context
    /// live here, not in the session, so they carry over. A no-op once the
    /// player holds the current session, so a repeat call changes nothing.
    fn restore_after_reconnect(&self) {
        let link = self.session.current_session();
        let mut state = lock(&self.state);
        let Some(resume) = prepare_restore(&mut state, link.session_id()) else {
            return;
        };
        let player = self.player();
        player.set_session(link);
        if let Some((track, play, position_ms)) = resume {
            info!("restoring playback after reconnect at {position_ms} ms");
            player.load(track, play, position_ms);
        }
    }

    /// Hands the player the supervisor's current session if a reconnect
    /// replaced the one it holds; loads on a dead session would fail.
    fn sync_session(&self) -> Session {
        sync_session(&self.session, &self.player(), &self.state)
    }

    fn player(&self) -> Arc<Player> {
        Arc::clone(&lock(&self.player))
    }
}

fn soft_mixer(volume: u16) -> SoftMixer {
    // `VolumeCtrl::default()` is librespot's 60 dB logarithmic curve.
    let mixer = SoftMixer::open(MixerConfig::default()).expect("SoftMixer::open never fails");
    mixer.set_volume(volume);
    mixer
}

fn player_config(tuning: Tuning) -> PlayerConfig {
    let bitrate = match tuning.bitrate {
        Bitrate::Kbps96 => config::Bitrate::Bitrate96,
        Bitrate::Kbps160 => config::Bitrate::Bitrate160,
        Bitrate::Kbps320 => config::Bitrate::Bitrate320,
    };
    let config = PlayerConfig {
        bitrate,
        position_update_interval: Some(POSITION_INTERVAL),
        ..PlayerConfig::default()
    };
    let Some(preset) = tuning.normalisation else {
        return config;
    };
    // Spotify's gain data targets -14 LUFS. Below it the peak-capped basic
    // method cannot clip; Loud needs the limiter.
    let (pregain_db, method) = match preset {
        LoudnessPreset::Quiet => (-5.0, NormalisationMethod::Basic),
        LoudnessPreset::Normal => (0.0, NormalisationMethod::Basic),
        LoudnessPreset::Loud => (3.0, NormalisationMethod::Dynamic),
    };
    PlayerConfig {
        normalisation: true,
        normalisation_pregain_db: pregain_db,
        normalisation_method: method,
        ..config
    }
}

/// Starts a librespot player on the shared sink and forwards its events.
/// The caller records `link`'s session id in the state.
fn spawn_player(
    session: &Arc<SpotSession>,
    link: Session,
    sink: SharedSink,
    mixer: &SoftMixer,
    state: &Arc<Mutex<State>>,
    observer: &Arc<dyn PlayerObserver>,
    tuning: Tuning,
) -> Arc<Player> {
    let epoch = sink.epoch.clone();
    let player = Player::new(
        player_config(tuning),
        link,
        mixer.get_soft_volume(),
        move || Box::new(sink),
    );
    tokio::spawn(forward_events(
        Arc::clone(session),
        player.get_player_event_channel(),
        Arc::downgrade(&player),
        epoch,
        Arc::clone(state),
        Arc::clone(observer),
    ));
    player
}

/// Which librespot player is live. `current` only moves while the state lock
/// is held, so a check under that lock cannot race a rebuild.
#[derive(Clone)]
struct Epoch {
    current: Arc<AtomicU64>,
    mine: u64,
}

impl Epoch {
    fn next(&self) -> Self {
        Self {
            current: Arc::clone(&self.current),
            mine: self.current.fetch_add(1, SeqCst) + 1,
        }
    }

    fn is_current(&self) -> bool {
        self.current.load(SeqCst) == self.mine
    }
}

/// The one CoreAudio ring, shared by each rebuilt librespot player. A
/// replaced player may run until its thread is joined; its output is dropped.
struct SharedSink {
    sink: Arc<Mutex<CoreAudioSink>>,
    epoch: Epoch,
}

impl Sink for SharedSink {
    fn start(&mut self) -> SinkResult<()> {
        if !self.epoch.is_current() {
            return Ok(());
        }
        lock(&self.sink).start()
    }

    fn stop(&mut self) -> SinkResult<()> {
        if !self.epoch.is_current() {
            return Ok(());
        }
        lock(&self.sink).stop()
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        if !self.epoch.is_current() {
            return Ok(());
        }
        lock(&self.sink).write(packet, converter)
    }
}

/// Track, play intent and position to restart a rebuilt player at.
fn resume_point(state: &State) -> Option<(SpotifyUri, bool, u32)> {
    let clock = &state.clock;
    let track = state.queue.current().filter(|_| clock.active)?;
    Some((track.clone(), clock.wants_play, clock.position_ms()))
}

fn sync_session(spot: &SpotSession, player: &Player, state: &Mutex<State>) -> Session {
    let session = spot.current_session();
    if adopt_session(&mut lock(state), session.session_id()) {
        player.set_session(session.clone());
    }
    session
}

/// None when `session_id` is already held; otherwise where to resume, if
/// anything was playing. Bumps the generation so a radio fetch started on
/// the old session cannot replace the restored track.
fn prepare_restore(
    state: &mut State,
    session_id: String,
) -> Option<Option<(SpotifyUri, bool, u32)>> {
    if !adopt_session(state, session_id) {
        return None;
    }
    state.generation += 1;
    Some(resume_point(state))
}

/// Records `session_id` as the player's session; false if it already was.
fn adopt_session(state: &mut State, session_id: String) -> bool {
    if state.session_id == session_id {
        return false;
    }
    state.session_id = session_id;
    true
}

/// Ends once the player or the session is gone.
async fn restore_after_reconnects(mut links: watch::Receiver<u64>, player: Weak<SpotPlayer>) {
    while links.changed().await.is_ok() {
        let Some(player) = player.upgrade() else {
            return;
        };
        // This may hold the last reference, and dropping a player joins its thread.
        let _ = tokio::task::spawn_blocking(move || player.restore_after_reconnect()).await;
    }
}

fn seed() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64)
}

/// Up Next takes single items only, not contexts.
fn playable(uri: &str) -> Result<SpotifyUri, PlayerError> {
    match SpotifyUri::from_uri(uri) {
        Ok(uri @ (SpotifyUri::Track { .. } | SpotifyUri::Episode { .. })) => Ok(uri),
        Ok(other) => Err(PlayerError::InvalidUri {
            message: format!("not a track or episode: {}", canonical(&other)),
        }),
        Err(e) => Err(PlayerError::InvalidUri {
            message: e.to_string(),
        }),
    }
}

impl Drop for SpotPlayer {
    fn drop(&mut self) {
        self.player().stop();
    }
}

async fn resolve(session: &Session, uri: &SpotifyUri) -> Result<Vec<SpotifyUri>, PlayerError> {
    let metadata = |e: librespot_core::Error| PlayerError::Metadata {
        message: e.to_string(),
    };
    match uri {
        SpotifyUri::Track { .. } | SpotifyUri::Episode { .. } => Ok(vec![uri.clone()]),
        SpotifyUri::Album { .. } => {
            let album = Album::get(session, uri).await.map_err(metadata)?;
            Ok(album.tracks().cloned().collect())
        }
        SpotifyUri::Playlist { .. } => {
            let playlist = Playlist::get(session, uri).await.map_err(metadata)?;
            Ok(playlist.tracks().cloned().collect())
        }
        SpotifyUri::Artist { .. } => {
            let artist = Artist::get(session, uri).await.map_err(metadata)?;
            Ok(artist.top_tracks.for_country(&session.country()).0)
        }
        _ => Err(PlayerError::InvalidUri {
            message: format!("unsupported URI kind: {}", canonical(uri)),
        }),
    }
}

fn canonical(uri: &SpotifyUri) -> String {
    uri.to_uri().unwrap_or_else(|_| "<unprintable>".to_owned())
}

/// Holds the player weakly so `set_normalisation` can drop it. Once a rebuild
/// moves the epoch on, this player's events are stale and end the loop;
/// state changes check it under the state lock.
async fn forward_events(
    session: Arc<SpotSession>,
    mut events: PlayerEventChannel,
    player: Weak<Player>,
    epoch: Epoch,
    state: Arc<Mutex<State>>,
    observer: Arc<dyn PlayerObserver>,
) {
    while let Some(event) = events.recv().await {
        let Some(player) = player.upgrade().filter(|_| epoch.is_current()) else {
            return;
        };
        if let PlayerEvent::PlayRequestIdChanged { play_request_id } = event {
            let mut state = lock(&state);
            if !epoch.is_current() {
                return;
            }
            state.request_id = Some(play_request_id);
            continue;
        }
        // librespot fires this ~30 s before the end; a preloaded track lets the
        // EndOfTrack load below start without a gap.
        if let PlayerEvent::TimeToPreloadNextTrack {
            play_request_id, ..
        } = event
        {
            let next = {
                let state = lock(&state);
                (state.request_id == Some(play_request_id))
                    .then(|| state.queue.upcoming().cloned())
                    .flatten()
            };
            if let Some(track) = next {
                player.preload(track);
            }
            continue;
        }
        let mut context_ended = false;
        if let PlayerEvent::EndOfTrack {
            play_request_id, ..
        } = event
        {
            let next = {
                let mut state = lock(&state);
                if !epoch.is_current() {
                    return;
                }
                if state.request_id != Some(play_request_id) {
                    continue;
                }
                state.queue.advance(false).cloned()
            };
            match next {
                Some(track) => player.load(track, true, 0),
                None => context_ended = true,
            }
        }
        if let Some(event) = map_event(event) {
            {
                let mut state = lock(&state);
                if !epoch.is_current() {
                    return;
                }
                state.clock.note(&event);
            }
            observer.on_event(event);
        }
        if context_ended && !continue_with_radio(&session, &player, &state).await {
            player.stop();
        }
    }
    if epoch.is_current() {
        warn!("player event channel closed");
    }
}

/// Replaces the exhausted context with its autoplay radio and starts it.
/// Returns false when autoplay is off, unavailable, or the user loaded
/// something else while the radio was fetched.
async fn continue_with_radio(spot: &SpotSession, player: &Player, state: &Mutex<State>) -> bool {
    let (request, generation) = {
        let state = lock(state);
        let Some(context) = state.context_uri.as_ref() else {
            return false;
        };
        if !state.autoplay
            || matches!(
                context,
                SpotifyUri::Episode { .. } | SpotifyUri::Show { .. }
            )
        {
            return false;
        }
        let played: Vec<_> = state.queue.played().map(canonical).collect();
        let recent = played[played.len().saturating_sub(RECENT_TRACKS)..].to_vec();
        let request = AutoplayContextRequest {
            context_uri: Some(canonical(context)),
            recent_track_uri: recent,
            ..Default::default()
        };
        (request, state.generation)
    };
    let session = sync_session(spot, player, state);
    let tracks = match session.spclient().get_autoplay_context(&request).await {
        Ok(context) => radio_tracks(&context),
        Err(e) => {
            warn!("autoplay request failed: {e}");
            return false;
        }
    };
    let mut state = lock(state);
    if state.generation != generation || tracks.is_empty() {
        return false;
    }
    state.queue.set_context(tracks, seed());
    let Some(first) = state.queue.current().cloned() else {
        return false;
    };
    info!("autoplay radio of {} items", state.queue.tracks().len());
    player.load(first, true, 0);
    true
}

/// Tracks of a resolved autoplay context, skipping page delimiters.
// shortcut: reads only pages delivered inline, not ones behind `page_url`;
// follow those if autoplay ever comes back empty in practice.
fn radio_tracks(context: &Context) -> Vec<SpotifyUri> {
    context
        .pages
        .iter()
        .flat_map(|page| &page.tracks)
        .filter_map(|track| SpotifyUri::from_uri(track.uri()).ok())
        .filter(|uri| matches!(uri, SpotifyUri::Track { .. }))
        .collect()
}

fn map_event(event: PlayerEvent) -> Option<PlaybackEvent> {
    use PlayerEvent as E;
    Some(match event {
        E::Loading {
            track_id,
            position_ms,
            ..
        } => PlaybackEvent::Loading {
            uri: canonical(&track_id),
            position_ms,
        },
        E::Playing {
            track_id,
            position_ms,
            ..
        } => PlaybackEvent::Playing {
            uri: canonical(&track_id),
            position_ms,
        },
        E::Paused {
            track_id,
            position_ms,
            ..
        } => PlaybackEvent::Paused {
            uri: canonical(&track_id),
            position_ms,
        },
        E::PositionChanged {
            track_id,
            position_ms,
            ..
        }
        | E::PositionCorrection {
            track_id,
            position_ms,
            ..
        }
        | E::Seeked {
            track_id,
            position_ms,
            ..
        } => PlaybackEvent::Position {
            uri: canonical(&track_id),
            position_ms,
        },
        E::TrackChanged { audio_item } => PlaybackEvent::TrackChanged {
            uri: audio_item.uri,
            name: audio_item.name,
            duration_ms: audio_item.duration_ms,
        },
        E::EndOfTrack { track_id, .. } => PlaybackEvent::EndOfTrack {
            uri: canonical(&track_id),
        },
        E::Unavailable { track_id, .. } => PlaybackEvent::Unavailable {
            uri: canonical(&track_id),
        },
        E::Stopped { .. } => PlaybackEvent::Stopped,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(n: u8) -> SpotifyUri {
        SpotifyUri::from_uri(&format!("spotify:track:4uLU6hMCjMI75M1A2tKUQ{n}")).unwrap()
    }

    #[test]
    fn clock_extrapolates_only_while_playing() {
        let uri = canonical(&track(0));
        let mut clock = Clock::default();
        clock.note(&PlaybackEvent::Paused {
            uri: uri.clone(),
            position_ms: 2_000,
        });
        clock.note(&PlaybackEvent::Position {
            uri: uri.clone(),
            position_ms: 2_500,
        });
        assert_eq!(clock.position_ms(), 2_500, "seek while paused stays put");
        clock.note(&PlaybackEvent::Playing {
            uri,
            position_ms: 2_500,
        });
        clock.reported_at = Instant::now().checked_sub(Duration::from_millis(600));
        assert!(clock.position_ms() > RESTART_THRESHOLD_MS);
        assert!(clock.active);
        clock.note(&PlaybackEvent::Stopped);
        assert_eq!(clock.position_ms(), 0);
        assert!(!clock.active, "nothing to resume after a stop");
    }

    fn state_playing(track: SpotifyUri) -> State {
        let mut queue = Queue::default();
        queue.set_context(vec![track], 0);
        State {
            queue,
            context_uri: None,
            autoplay: true,
            generation: 0,
            clock: Clock::default(),
            request_id: None,
            session_id: String::new(),
        }
    }

    #[test]
    fn resume_point_keeps_play_intent_through_loading() {
        let uri = canonical(&track(0));
        let mut state = state_playing(track(0));
        assert_eq!(resume_point(&state), None, "nothing loaded yet");

        state.clock.wants_play = true;
        state.clock.note(&PlaybackEvent::Loading {
            uri: uri.clone(),
            position_ms: 1_000,
        });
        assert_eq!(resume_point(&state), Some((track(0), true, 1_000)));

        state.clock.note(&PlaybackEvent::Paused {
            uri,
            position_ms: 1_500,
        });
        assert_eq!(resume_point(&state), Some((track(0), false, 1_500)));

        state.clock.note(&PlaybackEvent::Stopped);
        assert_eq!(resume_point(&state), None);
    }

    #[test]
    fn clock_stops_extrapolating_when_position_ticks_stop() {
        let mut clock = Clock::default();
        clock.note(&PlaybackEvent::Playing {
            uri: canonical(&track(0)),
            position_ms: 10_000,
        });
        clock.reported_at = Instant::now().checked_sub(Duration::from_secs(30));

        assert_eq!(
            clock.position_ms(),
            11_000,
            "a stalled stream did not play on"
        );
    }

    #[test]
    fn reconnect_restores_once_per_new_session_and_retires_radio_fetches() {
        let mut state = state_playing(track(0));
        state.session_id = "first".to_owned();
        state.clock.note(&PlaybackEvent::Paused {
            uri: canonical(&track(0)),
            position_ms: 42_000,
        });
        let generation = state.generation;

        assert_eq!(
            prepare_restore(&mut state, "first".to_owned()),
            None,
            "no reconnect yet"
        );
        assert_eq!(state.generation, generation);
        assert_eq!(
            prepare_restore(&mut state, "second".to_owned()),
            Some(Some((track(0), false, 42_000)))
        );
        assert!(
            state.generation > generation,
            "a radio fetch from the old session could replace the restored track"
        );
        assert_eq!(
            prepare_restore(&mut state, "second".to_owned()),
            None,
            "a repeated notice for the same session restores nothing"
        );
        assert_eq!(
            prepare_restore(&mut state, "third".to_owned()),
            Some(Some((track(0), false, 42_000))),
            "a reconnect during a restore restores again"
        );
    }

    #[test]
    fn next_epoch_retires_every_earlier_player() {
        let first = Epoch {
            current: Arc::default(),
            mine: 0,
        };
        assert!(first.is_current());
        let second = first.next();
        let third = first.next();
        assert!(!first.is_current());
        assert!(!second.is_current(), "a rebuild racing another loses");
        assert!(third.is_current());
    }

    #[test]
    fn soft_mixer_attenuates_on_a_log_curve() {
        let gain = |volume| soft_mixer(volume).get_soft_volume().attenuation_factor();
        assert_eq!(gain(u16::MAX), 1.0);
        assert_eq!(gain(0), 0.0);
        let half = gain(u16::MAX / 2);
        assert!(
            half < 0.1,
            "half volume is ~-30 dB on a 60 dB log curve, got {half}"
        );
    }

    #[test]
    fn player_config_maps_loudness_presets_to_normaliser() {
        let tuned = |normalisation| {
            player_config(Tuning {
                normalisation,
                bitrate: Bitrate::Kbps320,
            })
        };
        assert!(!tuned(None).normalisation);
        let check = |preset, pregain_db, method| {
            let config = tuned(Some(preset));
            assert!(config.normalisation);
            assert_eq!(config.normalisation_pregain_db, pregain_db);
            assert_eq!(config.normalisation_method, method);
            assert_eq!(config.position_update_interval, Some(POSITION_INTERVAL));
        };
        check(LoudnessPreset::Quiet, -5.0, NormalisationMethod::Basic);
        check(LoudnessPreset::Normal, 0.0, NormalisationMethod::Basic);
        check(LoudnessPreset::Loud, 3.0, NormalisationMethod::Dynamic);
    }

    #[test]
    fn player_config_maps_bitrates() {
        let check = |bitrate, expected| {
            let normalisation = Some(LoudnessPreset::Loud);
            let config = player_config(Tuning {
                normalisation,
                bitrate,
            });
            assert_eq!(config.bitrate, expected);
            assert!(config.normalisation, "bitrate must not reset normalisation");
        };
        check(Bitrate::Kbps96, config::Bitrate::Bitrate96);
        check(Bitrate::Kbps160, config::Bitrate::Bitrate160);
        check(Bitrate::Kbps320, config::Bitrate::Bitrate320);
    }

    #[test]
    fn playable_accepts_tracks_and_episodes_only() {
        assert!(playable("spotify:track:4uLU6hMCjMI75M1A2tKUQ0").is_ok());
        assert!(playable("spotify:episode:4uLU6hMCjMI75M1A2tKUQ0").is_ok());
        for uri in ["spotify:album:4uLU6hMCjMI75M1A2tKUQ0", "nonsense"] {
            assert!(matches!(playable(uri), Err(PlayerError::InvalidUri { .. })));
        }
    }

    #[test]
    fn radio_tracks_keeps_tracks_across_pages_and_drops_delimiters() {
        use librespot_protocol::context_page::ContextPage;
        use librespot_protocol::context_track::ContextTrack;
        let page = |uris: &[&str]| ContextPage {
            tracks: uris
                .iter()
                .map(|uri| ContextTrack {
                    uri: Some((*uri).to_owned()),
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        };
        let context = Context {
            pages: vec![
                page(&[&canonical(&track(0)), "spotify:delimiter"]),
                page(&[&canonical(&track(1))]),
            ],
            ..Default::default()
        };
        assert_eq!(radio_tracks(&context), [track(0), track(1)]);
    }

    #[test]
    fn map_event_reports_position_ticks_and_seeks() {
        let uri = track(0);
        for event in [
            PlayerEvent::PositionChanged {
                play_request_id: 1,
                track_id: uri.clone(),
                position_ms: 1000,
            },
            PlayerEvent::Seeked {
                play_request_id: 1,
                track_id: uri.clone(),
                position_ms: 1000,
            },
        ] {
            assert_eq!(
                map_event(event),
                Some(PlaybackEvent::Position {
                    uri: canonical(&uri),
                    position_ms: 1000
                })
            );
        }
    }

    #[test]
    fn map_event_reports_end_unavailable_and_stop() {
        let uri = track(0);
        let s = canonical(&uri);
        assert_eq!(
            map_event(PlayerEvent::EndOfTrack {
                play_request_id: 1,
                track_id: uri.clone()
            }),
            Some(PlaybackEvent::EndOfTrack { uri: s.clone() })
        );
        assert_eq!(
            map_event(PlayerEvent::Unavailable {
                play_request_id: 1,
                track_id: uri.clone()
            }),
            Some(PlaybackEvent::Unavailable { uri: s })
        );
        assert_eq!(
            map_event(PlayerEvent::Stopped {
                play_request_id: 1,
                track_id: uri
            }),
            Some(PlaybackEvent::Stopped)
        );
    }

    #[tokio::test]
    async fn resolve_plays_tracks_and_episodes_alone_and_rejects_shows() {
        let session = Session::new(librespot_core::SessionConfig::default(), None);
        for uri in [
            "spotify:track:4uLU6hMCjMI75M1A2tKUQ0",
            "spotify:episode:4uLU6hMCjMI75M1A2tKUQ0",
        ] {
            let uri = SpotifyUri::from_uri(uri).unwrap();
            assert_eq!(resolve(&session, &uri).await.unwrap(), vec![uri]);
        }
        let show = SpotifyUri::from_uri("spotify:show:4uLU6hMCjMI75M1A2tKUQ0").unwrap();
        assert!(matches!(
            resolve(&session, &show).await,
            Err(PlayerError::InvalidUri { .. })
        ));
    }

    #[test]
    fn map_event_drops_events_meant_for_spirc() {
        assert_eq!(map_event(PlayerEvent::VolumeChanged { volume: 1 }), None);
        assert_eq!(
            map_event(PlayerEvent::PlayRequestIdChanged { play_request_id: 1 }),
            None
        );
    }
}
