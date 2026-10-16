//! Playback control over librespot's `Player`, fed through `AudioOutput`.
//!
//! A loaded URI expands to an ordered track list (the context) held by
//! `Queue` with Up Next, shuffle and repeat; `next` and `previous` walk it,
//! the end of a track advances it, and an exhausted context continues with
//! Spotify's autoplay radio for it.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use librespot_connect::{LoadRequest, LoadRequestOptions, PlayingTrack, Spirc};
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

use crate::audio::{AudioOutput, CoreAudioSink, FADE, Transitions};
use crate::connect::SpotConnect;
use crate::devices::DeviceList;
use crate::queue::{Queue, RepeatMode};
use crate::remote::{Change, PlayRequest, RemoteCommand, RemotePlayback, load_leaves_remote};
use crate::session::SpotSession;
use crate::util::{OffRuntime, canonical, lock};

const POSITION_INTERVAL: Duration = Duration::from_secs(1);
/// Past this point `previous` restarts the track instead of going back.
const RESTART_THRESHOLD_MS: u32 = 3_000;
/// Played tracks sent with an autoplay request so the radio skips them.
const RECENT_TRACKS: usize = 20;
/// Skip steps sent to a remote whose queue is not known yet.
const MAX_BLIND_SKIPS: usize = 100;

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
    /// Spirc's queue takes additions only; see ADR-009.
    #[error("this queue edit is unavailable while playing through Spotify Connect")]
    ConnectQueueEdit,
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
#[derive(Debug, Clone, PartialEq)]
struct Tuning {
    normalisation: Option<LoudnessPreset>,
    bitrate: Bitrate,
    local_folders: Vec<PathBuf>,
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
    /// A Connect remote changed the volume; 0..=65535 like `set_volume`.
    VolumeChanged {
        volume: u16,
    },
    /// The queue changed outside the app; read it again with `queue`.
    QueueChanged,
    /// The device this Mac controls in Remote mode, with its volume to show
    /// but never save as the app's; both `None` once back in Local mode.
    RemoteChanged {
        device_name: Option<String>,
        volume: Option<u16>,
    },
    /// The account's Connect devices, after every cluster update.
    DevicesChanged {
        devices: Vec<crate::devices::ConnectDevice>,
    },
}

/// Called on the thread that raised the event: a tokio thread, or the one
/// calling into `SpotPlayer`/`SpotConnect`. Never called under a core lock,
/// so it may call back into the core; events from one source keep their order.
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
    /// Bumped by every change the user makes to what plays, so a `load`
    /// whose resolve finishes after a newer choice is dropped.
    choice: u64,
    clock: Clock,
    /// Events from earlier play requests are stale: their end of track must
    /// not advance the queue a second time.
    request_id: Option<u64>,
    /// Session the player was last given; replaced after a reconnect.
    session_id: String,
}

/// Lock order: `state`, then `player` or `connect`, then `SpotConnect`'s
/// device list. Code holding the device list never calls back into a
/// `SpotPlayer` method that takes `state` or `player`; it only emits events.
#[derive(uniffi::Object)]
pub struct SpotPlayer {
    session: Arc<SpotSession>,
    /// Replaced when `tuning` changes, as librespot fixes it at creation.
    player: Mutex<Arc<Player>>,
    tuning: Mutex<Tuning>,
    sink: Arc<Mutex<CoreAudioSink>>,
    /// Shared with the sink and the local event loop, never locks the sink.
    transitions: Arc<Transitions>,
    epoch: Epoch,
    mixer: SoftMixer,
    observer: Arc<dyn PlayerObserver>,
    state: Arc<Mutex<State>>,
    owner: Owner,
    /// Set by `SpotConnect::start`; held weakly as the connect side owns this player.
    connect: Mutex<Weak<SpotConnect>>,
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
            local_folders: Vec::new(),
        };
        let sink = output.take_sink().ok_or(PlayerError::OutputTaken)?;
        let transitions = sink.transitions();
        let sink = Arc::new(Mutex::new(sink));
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
            choice: 0,
            clock: Clock::default(),
            request_id: None,
            session_id: link.session_id(),
        }));
        let owner = Owner::default();
        let shared = SharedSink {
            sink: Arc::clone(&sink),
            transitions: Arc::clone(&transitions),
            gate: Gate {
                epoch: epoch.clone(),
                role: Role::Local,
                owner: owner.clone(),
            },
        };
        let player = spawn_player(
            &session,
            link,
            shared,
            &mixer,
            &state,
            &observer,
            tuning.clone(),
        );
        let this = Arc::new(Self {
            session,
            player: Mutex::new(player),
            tuning: Mutex::new(tuning),
            sink,
            transitions,
            epoch,
            mixer,
            observer,
            state,
            owner,
            connect: Mutex::new(Weak::new()),
        });
        tokio::spawn(restore_after_reconnects(links, Arc::downgrade(&this)));
        Ok(this)
    }

    /// App volume on a logarithmic curve, independent of the system volume.
    pub fn set_volume(&self, volume: u16) {
        match self.connect_mode() {
            // Spirc sets the shared mixer and tells the remotes.
            Some(connect) => connect.spirc(|s| s.set_volume(volume)),
            None => self.mixer.set_volume(volume),
        }
    }

    /// The remote device's volume in Remote mode; otherwise ignored, so a
    /// remote's value never reaches the app's own mixer.
    pub fn set_remote_volume(&self, volume: u16) {
        if let Some((connect, target)) = self.remote_mode() {
            connect.remote_volume(target, volume);
        }
    }

    /// Stops local playback only, for teardown: never commands Spirc's
    /// remotes or a device in Remote mode.
    pub fn stop_local(&self) {
        self.player().stop();
    }

    /// Rebuilds the librespot player with the new normaliser settings and
    /// resumes the current track where it was. `None` turns normalisation off.
    pub async fn set_normalisation(&self, normalisation: Option<LoudnessPreset>) {
        self.retune(|t| t.normalisation = normalisation);
    }

    /// Crossfades tracks that follow on without a user action (ADR-010).
    /// 0 turns it off; values above 12 s are clamped to 12.
    pub fn set_crossfade(&self, seconds: u8) {
        self.transitions.set_crossfade(seconds);
    }

    /// Rebuilds the player like `set_normalisation`; the current track
    /// restarts its download at the new bitrate.
    pub async fn set_bitrate(&self, bitrate: Bitrate) {
        self.retune(|t| t.bitrate = bitrate);
    }

    /// Folders librespot scans for `spotify:local:` files, once per player.
    /// Rebuilds the player like `set_bitrate` only when the list changed.
    pub async fn set_local_folders(&self, paths: Vec<String>) {
        let folders: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).collect();
        if lock(&self.tuning).local_folders != folders {
            self.retune(|t| t.local_folders = folders);
        }
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
        if let Some(connect) = self.connect_mode() {
            let options = LoadRequestOptions {
                start_playing: autoplay,
                seek_to: start_ms,
                ..Default::default()
            };
            let request = match uri {
                SpotifyUri::Track { .. }
                | SpotifyUri::Episode { .. }
                | SpotifyUri::Local { .. } => {
                    LoadRequest::from_tracks(vec![canonical(&uri)], options)
                }
                _ => LoadRequest::from_context_uri(canonical(&uri), options),
            };
            connect.spirc(|s| s.load(request));
            return Ok(());
        }
        if let Some((connect, target)) = self.remote_for_load() {
            let single = matches!(
                uri,
                SpotifyUri::Track { .. } | SpotifyUri::Episode { .. } | SpotifyUri::Local { .. }
            );
            let request = PlayRequest {
                context_uri: (!single).then(|| canonical(&uri)),
                tracks: if single {
                    vec![canonical(&uri)]
                } else {
                    Vec::new()
                },
                start_index: 0,
                seek_to: start_ms,
                paused: !autoplay,
            };
            connect.remote(target, &RemoteCommand::Play(request));
            return Ok(());
        }
        // Adopt the session only once resolve succeeds: adopting first would
        // make a pending reconnect restore skip, leaving playback dead on failure.
        let choice = lock(&self.state).claim();
        let tracks = resolve(&self.session.current_session(), &uri).await?;
        self.sync_session();
        self.start_context(tracks, None, Some(uri), start_ms, autoplay, Some(choice))
    }

    /// Plays a list the app already holds (Liked Songs, a sorted playlist)
    /// from `uris[start_index]`. `context_uri`, when given, seeds autoplay
    /// radio once the list runs out. `in_context_order`: `uris` are the
    /// context's tracks in its own order, so Connect and Remote mode play the
    /// context itself and Spotify records the plays under it.
    pub fn load_tracks(
        &self,
        uris: Vec<String>,
        start_index: u32,
        context_uri: Option<String>,
        in_context_order: bool,
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
        let spotify_context = list_context(context.as_ref(), in_context_order);
        if let Some(connect) = self.connect_mode() {
            let mut options = LoadRequestOptions {
                start_playing: autoplay,
                ..Default::default()
            };
            let request = match spotify_context {
                Some(context) => {
                    options.playing_track =
                        Some(PlayingTrack::Uri(uris[start_index as usize].clone()));
                    LoadRequest::from_context_uri(context, options)
                }
                None => {
                    options.playing_track = Some(PlayingTrack::Index(start_index));
                    LoadRequest::from_tracks(uris, options)
                }
            };
            connect.spirc(|s| s.load(request));
            return Ok(());
        }
        if let Some((connect, target)) = self.remote_for_load() {
            let request = PlayRequest {
                context_uri: spotify_context,
                tracks: uris,
                start_index,
                seek_to: 0,
                paused: !autoplay,
            };
            connect.remote(target, &RemoteCommand::Play(request));
            return Ok(());
        }
        self.sync_session();
        self.start_context(
            tracks,
            Some(start_index as usize),
            context,
            0,
            autoplay,
            None,
        )
    }

    pub fn play(&self) {
        if let Some((connect, target)) = self.remote_mode() {
            return connect.remote(target, &RemoteCommand::Resume);
        }
        if let Some(connect) = self.connect_mode() {
            return connect.spirc(Spirc::play);
        }
        lock(&self.state).clock.wants_play = true;
        // During a pause fade librespot is still playing; the fade ramps back up.
        if !self.transitions.cancel_pause() {
            self.player().play();
        }
    }

    /// Locally, fades out over `FADE` before librespot pauses, so its Paused
    /// event comes that much later; a newer command cancels it (ADR-010).
    pub fn pause(self: Arc<Self>) {
        if let Some((connect, target)) = self.remote_mode() {
            return connect.remote(target, &RemoteCommand::Pause);
        }
        if let Some(connect) = self.connect_mode() {
            return connect.spirc(Spirc::pause);
        }
        let playing = {
            let mut state = lock(&self.state);
            state.clock.wants_play = false;
            state.clock.playing
        };
        if !playing {
            return self.player().pause();
        }
        let Some(generation) = self.transitions.begin_pause() else {
            return;
        };
        let this = Arc::downgrade(&self);
        std::thread::spawn(move || {
            std::thread::sleep(FADE);
            if let Some(this) = this.upgrade() {
                let player = this.player();
                this.transitions.finish_pause(generation, || player.pause());
            }
        });
    }

    pub fn seek(&self, position_ms: u32) {
        if let Some((connect, target)) = self.remote_mode() {
            return connect.remote(target, &RemoteCommand::SeekTo(position_ms));
        }
        if let Some(connect) = self.connect_mode() {
            return connect.spirc(|s| s.set_position_ms(position_ms));
        }
        if self.transitions.discontinuity() {
            // The seek cancelled a pause fade, so playback carries on.
            lock(&self.state).clock.wants_play = true;
        }
        self.player().seek(position_ms);
    }

    /// Plays Up Next first, then the context. No-op at the end of the
    /// context unless repeat is on.
    pub fn next(&self) {
        if let Some((connect, target)) = self.remote_mode() {
            return connect.remote(target, &RemoteCommand::SkipNext);
        }
        if let Some(connect) = self.connect_mode() {
            return connect.spirc(Spirc::next);
        }
        self.sync_session();
        let mut state = lock(&self.state);
        if let Some(track) = state.queue.advance(true).cloned() {
            state.supersede();
            state.clock.wants_play = true;
            self.transitions.discontinuity();
            self.player().load(track, true, 0);
        }
    }

    /// Jumps to the `count`th upcoming track (Up Next first, then the
    /// context) with one load, as a queue row click does.
    pub fn skip(&self, count: u32) {
        if let Some((connect, target)) = self.remote_mode() {
            // shortcut: one skip_next per step, as in Connect mode.
            for _ in 0..remote_steps(connect.queued(), count) {
                connect.remote(target.clone(), &RemoteCommand::SkipNext);
            }
            return;
        }
        if let Some(connect) = self.connect_mode() {
            // shortcut: Spirc has no skip-to, so each step loads a track; send a
            // `skip_next` command with the target track if that is audible.
            for _ in 0..remote_steps(connect.queued(), count) {
                connect.spirc(Spirc::next);
            }
            return;
        }
        self.sync_session();
        let mut state = lock(&self.state);
        if let Some(track) = state.queue.skip(count as usize).cloned() {
            state.supersede();
            state.clock.wants_play = true;
            self.transitions.discontinuity();
            self.player().load(track, true, 0);
        }
    }

    /// Restarts the track once it is more than 3 s in, as Spotify does;
    /// otherwise goes back one track.
    pub fn previous(&self) {
        if let Some((connect, target)) = self.remote_mode() {
            return connect.remote(target, &RemoteCommand::SkipPrev);
        }
        if let Some(connect) = self.connect_mode() {
            return connect.spirc(Spirc::prev);
        }
        self.sync_session();
        let mut state = lock(&self.state);
        if state.clock.position_ms() > RESTART_THRESHOLD_MS {
            self.transitions.discontinuity();
            self.player().seek(0);
        } else if let Some(track) = state.queue.back().cloned() {
            state.supersede();
            state.clock.wants_play = true;
            self.transitions.discontinuity();
            self.player().load(track, true, 0);
        }
    }

    /// Puts a track or episode at the front of Up Next.
    pub fn play_next(&self, uri: String) -> Result<(), PlayerError> {
        let track = playable(&uri)?;
        self.local_queue_only()?;
        lock(&self.state).queue.play_next(track);
        Ok(())
    }

    /// Puts a track or episode at the end of Up Next.
    pub fn add_to_queue(&self, uri: String) -> Result<(), PlayerError> {
        let track = playable(&uri)?;
        if let Some(connect) = self.connect_mode() {
            connect.add_to_queue(canonical(&track));
            return Ok(());
        }
        if let Some((connect, target)) = self.remote_mode() {
            connect.remote_add_to_queue(target, &canonical(&track));
            return Ok(());
        }
        lock(&self.state).queue.add(track);
        Ok(())
    }

    pub fn remove_from_queue(&self, index: u32) -> Result<(), PlayerError> {
        self.local_queue_only()?;
        lock(&self.state)
            .queue
            .remove(index as usize)
            .map(drop)
            .ok_or(PlayerError::OutOfRange { index })
    }

    /// Moves the Up Next entry at `from` so it ends up at `to`.
    pub fn move_in_queue(&self, from: u32, to: u32) -> Result<(), PlayerError> {
        self.local_queue_only()?;
        if lock(&self.state).queue.reorder(from as usize, to as usize) {
            Ok(())
        } else {
            Err(PlayerError::OutOfRange {
                index: from.max(to),
            })
        }
    }

    /// A no-op while playing through Spotify Connect or controlling another device.
    pub fn clear_queue(&self) {
        if self.local_queue_only().is_err() {
            return warn!("clear queue ignored in Connect or Remote mode");
        }
        lock(&self.state).queue.clear_up_next();
    }

    pub fn set_shuffle(&self, on: bool) {
        if let Some((connect, target)) = self.remote_mode() {
            return connect.remote(target, &RemoteCommand::Shuffle(on));
        }
        if let Some(connect) = self.connect_mode() {
            return connect.spirc(|s| s.shuffle(on));
        }
        lock(&self.state).queue.set_shuffle(on, seed());
    }

    pub fn set_repeat(&self, mode: RepeatMode) {
        if let Some((connect, target)) = self.remote_mode() {
            let (context, track) = spirc_repeat(mode);
            connect.remote(target.clone(), &RemoteCommand::RepeatContext(context));
            return connect.remote(target, &RemoteCommand::RepeatTrack(track));
        }
        if let Some(connect) = self.connect_mode() {
            let (context, track) = spirc_repeat(mode);
            connect.spirc(|s| s.repeat(context));
            return connect.spirc(|s| s.repeat_track(track));
        }
        lock(&self.state).queue.repeat = mode;
    }

    /// Whether an exhausted context continues with radio. On by default.
    pub fn set_autoplay(&self, on: bool) {
        lock(&self.state).autoplay = on;
    }

    pub fn queue(&self) -> QueueSnapshot {
        // Resolved before taking `state`; see the lock order on `SpotPlayer`.
        let cluster = self
            .connect_mode()
            .or_else(|| self.remote_mode().map(|(c, _)| c));
        let state = lock(&self.state);
        if let Some(connect) = cluster {
            return connect.queue(state.autoplay);
        }
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

    /// Pauses instead in Connect and Remote mode, where the remotes keep the
    /// queue; teardown uses `stop_local`.
    pub fn stop(&self) {
        if let Some((connect, target)) = self.remote_mode() {
            return connect.remote(target, &RemoteCommand::Pause);
        }
        if let Some(connect) = self.connect_mode() {
            return connect.spirc(Spirc::pause);
        }
        self.transitions.discontinuity();
        self.player().stop();
    }
}

impl State {
    /// Retires in-flight radio fetches and slower `load` resolves.
    fn supersede(&mut self) {
        self.generation += 1;
        self.claim();
    }

    /// Retires slower `load` resolves only: a radio fetch keeps going until
    /// a load actually replaces what plays.
    fn claim(&mut self) -> u64 {
        self.choice += 1;
        self.choice
    }

    /// Sets the context and returns its first track to load, or `None` when
    /// `choice` is no longer the latest one.
    fn begin_context(
        &mut self,
        tracks: Vec<SpotifyUri>,
        start: Option<usize>,
        context_uri: Option<SpotifyUri>,
        autoplay: bool,
        choice: Option<u64>,
    ) -> Result<Option<SpotifyUri>, PlayerError> {
        if !is_latest(self, choice) {
            info!("dropping a load superseded while it resolved");
            return Ok(None);
        }
        match start {
            Some(start) => self.queue.set_context_at(tracks, start, seed()),
            None => self.queue.set_context(tracks, seed()),
        }
        self.context_uri = context_uri;
        self.supersede();
        let first = self
            .queue
            .current()
            .cloned()
            .ok_or_else(|| PlayerError::EmptyContext {
                uri: self.context_uri.as_ref().map(canonical).unwrap_or_default(),
            })?;
        info!("loading context of {} items", self.queue.tracks().len());
        self.clock.wants_play = autoplay;
        Ok(Some(first))
    }
}

impl SpotPlayer {
    /// Loads `track` paused at `position_ms` inside `context` on the local
    /// player, so Connect never owns playback the user did not hand over.
    /// Falls back to `track` alone when the context cannot be resolved or no
    /// longer holds it.
    pub(crate) async fn restore(
        &self,
        context: Option<String>,
        track: String,
        position_ms: u32,
    ) -> Result<(), PlayerError> {
        let track = playable(&track)?;
        let context = context.and_then(|uri| SpotifyUri::from_uri(&uri).ok());
        let choice = lock(&self.state).claim();
        let resolved = match &context {
            Some(uri) => resolve(&self.session.current_session(), uri).await.ok(),
            None => None,
        };
        let (tracks, start, context) = restore_start(resolved, track, context);
        self.sync_session();
        self.start_context(
            tracks,
            Some(start),
            context,
            position_ms,
            false,
            Some(choice),
        )
    }

    /// Starts at `start`, or where `set_context` would (shuffled or first)
    /// without one. Does nothing when `choice` is no longer the latest one.
    fn start_context(
        &self,
        tracks: Vec<SpotifyUri>,
        start: Option<usize>,
        context_uri: Option<SpotifyUri>,
        start_ms: u32,
        autoplay: bool,
        choice: Option<u64>,
    ) -> Result<(), PlayerError> {
        let mut state = lock(&self.state);
        if let Some(first) = state.begin_context(tracks, start, context_uri, autoplay, choice)? {
            self.transitions.discontinuity();
            self.player().load(first, autoplay, start_ms);
        }
        Ok(())
    }

    /// Must run on the UniFFI tokio runtime, for `spawn_blocking`.
    fn retune(&self, change: impl FnOnce(&mut Tuning)) {
        // Held throughout so overlapping calls and queue moves serialise.
        let mut state = lock(&self.state);
        let tuning = {
            let mut tuning = lock(&self.tuning);
            change(&mut tuning);
            tuning.clone()
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
            transitions: Arc::clone(&self.transitions),
            gate: Gate {
                epoch,
                role: Role::Local,
                owner: self.owner.clone(),
            },
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
        self.transitions.discontinuity();
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
        let Restore::Adopted(resume) = prepare_restore(&mut state, link.session_id()) else {
            return;
        };
        let player = self.player();
        player.set_session(link);
        if let Some((track, play, position_ms)) = resume {
            info!("restoring playback after reconnect at {position_ms} ms");
            self.transitions.discontinuity();
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

    /// The Connect session while it owns the sink (ADR-009 Connect mode).
    fn connect_mode(&self) -> Option<Arc<SpotConnect>> {
        if self.owner.get() != Role::Connect {
            return None;
        }
        lock(&self.connect).upgrade()
    }

    /// The remote's queue would need a `set_queue` built from its uids and
    /// queue revision, which no test here can verify (ADR-009).
    fn local_queue_only(&self) -> Result<(), PlayerError> {
        match self.connect_mode().is_some() || self.remote_mode().is_some() {
            true => Err(PlayerError::ConnectQueueEdit),
            false => Ok(()),
        }
    }

    /// The Connect session and the active device while another device plays
    /// (ADR-009 Remote mode).
    fn remote_mode(&self) -> Option<(Arc<SpotConnect>, String)> {
        self.followed_remote()
            .map(|(connect, remote)| (connect, remote.device_id))
    }

    fn followed_remote(&self) -> Option<(Arc<SpotConnect>, RemotePlayback)> {
        let connect = lock(&self.connect).upgrade()?;
        let owner = self.owner.get();
        let remote = connect.with_devices(|list| remote_for(owner, list))?;
        Some((connect, remote))
    }

    /// Where a load goes in Remote mode: to a playing remote; a paused one
    /// is left so the Mac plays (ADR-009).
    fn remote_for_load(&self) -> Option<(Arc<SpotConnect>, String)> {
        let (connect, remote) = self.followed_remote()?;
        if !load_leaves_remote(&remote) {
            return Some((connect, remote.device_id));
        }
        if connect.leave_paused_remote() {
            self.leave_remote(false);
        }
        None
    }

    /// Applies a cluster update's Remote-mode change and shows its events.
    /// Called without the device list locked; see the lock order.
    pub(crate) fn apply_remote(&self, change: Change, events: Vec<PlaybackEvent>, epoch: &Epoch) {
        match change {
            Change::Enter => {
                info!("entering Remote mode");
                if enter_remote(&self.owner, &mut lock(&self.state)) {
                    self.player().stop();
                }
                // Link shutdown retires before it leaves Remote mode; undo an
                // Enter that lost that race, or local events stay hidden.
                if !epoch.is_current() {
                    self.owner.set_remote(false);
                    return;
                }
            }
            Change::Leave => self.leave_remote(false),
            Change::Stay => {}
        }
        for event in events {
            self.observer.on_event(event);
        }
    }

    /// Shows the app's own volume again; `stopped` also clears the remote's
    /// playback. Takes no locks, so it is safe under the device list lock.
    pub(crate) fn leave_remote(&self, stopped: bool) {
        info!("leaving Remote mode");
        self.owner.set_remote(false);
        self.observer.on_event(PlaybackEvent::RemoteChanged {
            device_name: None,
            volume: None,
        });
        if stopped {
            self.observer.on_event(PlaybackEvent::Stopped);
        }
    }

    pub(crate) fn attach_connect(&self, connect: Weak<SpotConnect>) {
        *lock(&self.connect) = connect;
    }

    /// Nothing plays or is loaded on this Mac, and the user has chosen nothing yet.
    pub(crate) fn is_untouched(&self) -> bool {
        let state = lock(&self.state);
        state.choice == 0
            && state.queue.current().is_none()
            && self.owner.get() == Role::Local
            && !self.owner.is_remote()
    }

    pub(crate) fn volume(&self) -> u16 {
        self.mixer.volume()
    }

    pub(crate) fn connect_mixer(&self) -> Arc<dyn Mixer> {
        Arc::new(self.mixer.clone())
    }

    pub(crate) fn emit(&self, event: PlaybackEvent) {
        self.observer.on_event(event);
    }

    /// Pauses the local player unless Connect owns the sink. Never routed to
    /// a remote device.
    pub(crate) fn pause_local(&self) {
        if self.owner.get() == Role::Local {
            lock(&self.state).clock.wants_play = false;
            self.player().pause();
        }
    }

    /// The cluster's queue changed; it is the app's queue in Connect and
    /// Remote mode.
    pub(crate) fn queue_changed(&self, remote: bool) {
        if remote || self.owner.get() == Role::Connect {
            self.observer.on_event(PlaybackEvent::QueueChanged);
        }
    }

    /// Spirc's player: it shares the sink and mixer, and plays through the
    /// sink only while `epoch` is current and Connect owns it.
    pub(crate) fn spawn_connect_player(
        self: &Arc<Self>,
        session: Session,
        epoch: Epoch,
    ) -> Arc<Player> {
        let sink = SharedSink {
            sink: Arc::clone(&self.sink),
            transitions: Arc::clone(&self.transitions),
            gate: Gate {
                epoch: epoch.clone(),
                role: Role::Connect,
                owner: self.owner.clone(),
            },
        };
        let tuning = lock(&self.tuning).clone();
        let player = Player::new(
            player_config(tuning),
            session,
            self.mixer.get_soft_volume(),
            move || Box::new(sink),
        );
        tokio::spawn(forward_connect_events(
            player.get_player_event_channel(),
            Arc::downgrade(self),
            epoch,
        ));
        player
    }

    /// Hands the sink back to the local player when a retired Connect
    /// link held it, so the app is not left in Connect mode without Spirc.
    pub(crate) fn connect_retired(&self, epoch: &Epoch) {
        if self.owner.retire(epoch) {
            info!("leaving Connect mode: link retired");
            self.observer.on_event(PlaybackEvent::Stopped);
        }
    }

    fn on_connect_event(&self, event: PlayerEvent, epoch: &Epoch) {
        if let PlayerEvent::VolumeChanged { volume } = event {
            // The mixer is shared, so the app's volume moved even while idle.
            if epoch.is_current() {
                self.observer
                    .on_event(PlaybackEvent::VolumeChanged { volume });
            }
            return;
        }
        let attached = lock(&self.connect).strong_count() > 0;
        match connect_step(&self.owner, epoch, attached, &event) {
            Step::Drop => return,
            Step::Enter => {
                info!("entering Connect mode");
                self.player().stop();
            }
            // Spirc stopping as a transfer moves playback to the followed
            // remote would blank the remote's track.
            Step::Forward
                if self.owner.is_remote() && matches!(event, PlayerEvent::Stopped { .. }) =>
            {
                return;
            }
            Step::Forward => {}
        }
        if let Some(event) = map_event(event) {
            self.observer.on_event(event);
        }
    }
}

/// One command per step goes to the remote, so never more than the
/// cluster's queue holds, or `MAX_BLIND_SKIPS` before its first push.
fn remote_steps(queued: Option<usize>, count: u32) -> usize {
    (count as usize).min(queued.unwrap_or(MAX_BLIND_SKIPS))
}

/// The followed remote while it, not this Mac, plays (ADR-009 Remote mode).
fn remote_for(owner: Role, list: &DeviceList) -> Option<RemotePlayback> {
    match route(owner, list.remote.is_some()) {
        Route::Remote => list.remote.clone(),
        Route::Local | Route::Connect => None,
    }
}

/// Marks Remote mode and retires in-flight radio fetches; true when the
/// local player must stop, so nothing decodes while another device plays.
fn enter_remote(owner: &Owner, state: &mut State) -> bool {
    owner.set_remote(true);
    state.supersede();
    state.clock.wants_play = false;
    owner.get() == Role::Local
}

/// Where a player call goes. Connect wins over a remote, as this Mac then
/// plays itself; Local only when no other device is active.
#[derive(Debug, PartialEq, Eq)]
enum Route {
    Local,
    Connect,
    Remote,
}

fn route(owner: Role, remote_active: bool) -> Route {
    match (owner, remote_active) {
        (Role::Connect, _) => Route::Connect,
        (Role::Local, true) => Route::Remote,
        (Role::Local, false) => Route::Local,
    }
}

/// Spirc's `repeat` and `repeat_track` flags for a repeat mode.
fn spirc_repeat(mode: RepeatMode) -> (bool, bool) {
    match mode {
        RepeatMode::Off => (false, false),
        RepeatMode::Context => (true, false),
        RepeatMode::Track => (true, true),
    }
}

/// Which side a Spirc player event hands the sink to: loading, playing or
/// pausing means a remote picked this Mac; a stop means Spirc went inactive.
fn owner_after(event: &PlayerEvent) -> Option<Role> {
    match event {
        PlayerEvent::Loading { .. } | PlayerEvent::Playing { .. } | PlayerEvent::Paused { .. } => {
            Some(Role::Connect)
        }
        PlayerEvent::Stopped { .. } => Some(Role::Local),
        _ => None,
    }
}

/// Ends once the Connect link is retired or the local player is gone.
async fn forward_connect_events(
    mut events: PlayerEventChannel,
    spot: Weak<SpotPlayer>,
    epoch: Epoch,
) {
    while let Some(event) = events.recv().await {
        let Some(spot) = spot.upgrade().filter(|_| epoch.is_current()) else {
            return;
        };
        // This may hold the last reference, and dropping a player joins its thread.
        let epoch = epoch.clone();
        let _ = tokio::task::spawn_blocking(move || spot.on_connect_event(event, &epoch)).await;
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
        local_file_directories: tuning.local_folders,
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
    let gate = Gate {
        epoch: sink.gate.epoch.clone(),
        role: Role::Local,
        owner: sink.gate.owner.clone(),
    };
    let transitions = Arc::clone(&sink.transitions);
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
        gate,
        Arc::clone(state),
        Arc::clone(observer),
        transitions,
    ));
    player
}

/// Which librespot player is live. `current` only moves while the state lock
/// is held, so a check under that lock cannot race a rebuild.
#[derive(Clone, Default)]
pub(crate) struct Epoch {
    current: Arc<AtomicU64>,
    mine: u64,
}

impl Epoch {
    /// Makes this epoch and every earlier one stale without a successor.
    pub(crate) fn retire(&self) {
        self.current.fetch_add(1, SeqCst);
    }

    fn next(&self) -> Self {
        Self {
            current: Arc::clone(&self.current),
            mine: self.current.fetch_add(1, SeqCst) + 1,
        }
    }

    pub(crate) fn is_current(&self) -> bool {
        self.current.load(SeqCst) == self.mine
    }
}

/// The player feeding the sink: the local one, or Spirc's (ADR-009).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    Local,
    Connect,
}

/// Which role owns the sink; shared by every player on it.
#[derive(Clone, Default)]
struct Owner {
    connect: Arc<AtomicBool>,
    /// Serialises Connect handovers with link retirement.
    handover: Arc<Mutex<()>>,
    /// Another device plays (Remote mode); the sink stays Local but idle.
    remote: Arc<AtomicBool>,
}

impl Owner {
    fn get(&self) -> Role {
        if self.connect.load(SeqCst) {
            Role::Connect
        } else {
            Role::Local
        }
    }

    /// Returns the previous owner, so exactly one caller sees a handover.
    fn set(&self, role: Role) -> Role {
        if self.connect.swap(role == Role::Connect, SeqCst) {
            Role::Connect
        } else {
            Role::Local
        }
    }

    fn set_remote(&self, remote: bool) {
        self.remote.store(remote, SeqCst);
    }

    fn is_remote(&self) -> bool {
        self.remote.load(SeqCst)
    }

    /// The local player's events reach the app only in Local mode; its stop
    /// on entering Connect or Remote mode is not news.
    fn shows_local_events(&self) -> bool {
        self.get() == Role::Local && !self.remote.load(SeqCst)
    }

    /// Moves the sink for an event of the Connect link at `epoch`; None once
    /// that link is retired, so a late event cannot take the sink back.
    fn hand_over(&self, epoch: &Epoch, role: Role) -> Option<Role> {
        let _handover = lock(&self.handover);
        epoch.is_current().then(|| self.set(role))
    }

    /// Retires the Connect link at `epoch` and returns the sink to Local;
    /// true if Connect held it.
    fn retire(&self, epoch: &Epoch) -> bool {
        let _handover = lock(&self.handover);
        epoch.retire();
        self.set(Role::Local) == Role::Connect
    }
}

/// What a Spirc player event does to the app.
#[derive(Debug, PartialEq, Eq)]
enum Step {
    Drop,
    /// Connect takes the sink: stop the local player, then forward.
    Enter,
    Forward,
}

/// `attached`: the `SpotConnect` handle is set, so Connect-mode commands
/// reach Spirc; until then the sink stays Local.
fn connect_step(owner: &Owner, epoch: &Epoch, attached: bool, event: &PlayerEvent) -> Step {
    match owner_after(event) {
        Some(Role::Connect) if !attached => Step::Drop,
        Some(Role::Connect) => match owner.hand_over(epoch, Role::Connect) {
            Some(Role::Local) => Step::Enter,
            Some(Role::Connect) => Step::Forward,
            None => Step::Drop,
        },
        Some(Role::Local) => match owner.hand_over(epoch, Role::Local) {
            Some(Role::Connect) => Step::Forward,
            _ => Step::Drop,
        },
        None if epoch.is_current() && owner.get() == Role::Connect => Step::Forward,
        None => Step::Drop,
    }
}

/// A player reaches the sink only while it is the live one of its role and
/// its role owns the sink.
struct Gate {
    epoch: Epoch,
    role: Role,
    owner: Owner,
}

impl Gate {
    fn is_open(&self) -> bool {
        self.epoch.is_current() && self.owner.get() == self.role
    }
}

/// The one CoreAudio ring, shared by each rebuilt librespot player and
/// Spirc's. A player that is not let through has its output dropped.
struct SharedSink {
    sink: Arc<Mutex<CoreAudioSink>>,
    transitions: Arc<Transitions>,
    gate: Gate,
}

impl Sink for SharedSink {
    fn start(&mut self) -> SinkResult<()> {
        if !self.gate.is_open() {
            return Ok(());
        }
        lock(&self.sink).start()
    }

    fn stop(&mut self) -> SinkResult<()> {
        if !self.gate.is_open() {
            return Ok(());
        }
        lock(&self.sink).stop()
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        if !self.gate.is_open() {
            return Ok(());
        }
        let mut sink = lock(&self.sink);
        match self.gate.role {
            Role::Local => sink.write(packet, converter),
            Role::Connect => sink.write_gapless(packet, converter),
        }
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

#[derive(Debug, PartialEq)]
enum Restore {
    /// The player already holds the session.
    Held,
    /// Where to resume on the adopted session, if anything was playing.
    Adopted(Option<(SpotifyUri, bool, u32)>),
}

/// False once a newer user choice replaced `choice`; `None` claims nothing.
fn is_latest(state: &State, choice: Option<u64>) -> bool {
    choice.is_none_or(|choice| choice == state.choice)
}

/// Bumps the generation on adoption so a radio fetch started on the old
/// session cannot replace the restored track.
fn prepare_restore(state: &mut State, session_id: String) -> Restore {
    if !adopt_session(state, session_id) {
        return Restore::Held;
    }
    state.generation += 1;
    Restore::Adopted(resume_point(state))
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

/// Contexts Spotify can play by uri, as Spirc's `from_context_uri` and the
/// connect-state play command take them.
pub(crate) fn is_spotify_context(uri: &SpotifyUri) -> bool {
    matches!(
        uri,
        SpotifyUri::Album { .. }
            | SpotifyUri::Artist { .. }
            | SpotifyUri::Playlist { .. }
            | SpotifyUri::Show { .. }
    )
}

/// The context to play a held list as: only a list in the context's own
/// order, as a sorted or filtered one would play in another order.
fn list_context(context: Option<&SpotifyUri>, in_context_order: bool) -> Option<String> {
    context
        .filter(|uri| in_context_order && is_spotify_context(uri))
        .map(canonical)
}

/// Up Next takes single items only, not contexts.
pub(crate) fn playable(uri: &str) -> Result<SpotifyUri, PlayerError> {
    match SpotifyUri::from_uri(uri) {
        Ok(
            uri
            @ (SpotifyUri::Track { .. } | SpotifyUri::Episode { .. } | SpotifyUri::Local { .. }),
        ) => Ok(uri),
        Ok(other) => Err(PlayerError::InvalidUri {
            message: format!("not a track, episode or local file: {}", canonical(&other)),
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

/// Where a restore starts: `track` inside its resolved context, else `track` alone.
fn restore_start(
    resolved: Option<Vec<SpotifyUri>>,
    track: SpotifyUri,
    context: Option<SpotifyUri>,
) -> (Vec<SpotifyUri>, usize, Option<SpotifyUri>) {
    match resolved.and_then(|t| t.iter().position(|u| *u == track).map(|i| (t, i))) {
        Some((tracks, start)) => (tracks, start, context),
        None => (vec![track], 0, None),
    }
}

async fn resolve(session: &Session, uri: &SpotifyUri) -> Result<Vec<SpotifyUri>, PlayerError> {
    let metadata = |e: librespot_core::Error| PlayerError::Metadata {
        message: e.to_string(),
    };
    match uri {
        SpotifyUri::Track { .. } | SpotifyUri::Episode { .. } | SpotifyUri::Local { .. } => {
            Ok(vec![uri.clone()])
        }
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

/// Holds the player weakly so `set_normalisation` can drop it. Once a rebuild
/// moves the epoch on, this player's events are stale and end the loop;
/// state changes check it under the state lock.
async fn forward_events(
    session: Arc<SpotSession>,
    mut events: PlayerEventChannel,
    player: Weak<Player>,
    gate: Gate,
    state: Arc<Mutex<State>>,
    observer: Arc<dyn PlayerObserver>,
    transitions: Arc<Transitions>,
) {
    let Gate { epoch, owner, .. } = gate;
    let mut duration_ms = 0;
    while let Some(event) = events.recv().await {
        // Held across the radio fetch below, so it may be the last reference.
        let Some(player) = player
            .upgrade()
            .filter(|_| epoch.is_current())
            .map(OffRuntime::new)
        else {
            return;
        };
        if let PlayerEvent::PlayRequestIdChanged { play_request_id } = event {
            let mut state = lock(&state);
            if !epoch.is_current() {
                return;
            }
            state.request_id = Some(play_request_id);
            transitions.confirm();
            continue;
        }
        match &event {
            PlayerEvent::TrackChanged { audio_item } => duration_ms = audio_item.duration_ms,
            PlayerEvent::Playing { position_ms, .. } | PlayerEvent::Seeked { position_ms, .. } => {
                transitions.confirm();
                transitions.track(duration_ms, *position_ms);
            }
            _ => {}
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
                transitions.arm();
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
            transitions.boundary();
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
            if owner.shows_local_events() {
                observer.on_event(event);
            }
        }
        if context_ended && !continue_with_radio(&session, &player, &state, &owner).await {
            transitions.play_out();
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
async fn continue_with_radio(
    spot: &SpotSession,
    player: &Player,
    state: &Mutex<State>,
    owner: &Owner,
) -> bool {
    let (request, generation) = {
        let state = lock(state);
        if owner.is_remote() {
            return false;
        }
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
    // Entering Remote mode bumps the generation, so this also covers it.
    if state.generation != generation || tracks.is_empty() || owner.is_remote() {
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
    fn a_restore_starts_at_its_track_in_the_context_or_plays_it_alone() {
        let context = SpotifyUri::from_uri("spotify:playlist:0kfSfq4tGP2VGZJ2j8ZTxD").ok();
        let in_context = restore_start(
            Some(vec![track(1), track(2), track(3)]),
            track(2),
            context.clone(),
        );
        assert_eq!(
            in_context,
            (vec![track(1), track(2), track(3)], 1, context.clone())
        );

        let alone = (vec![track(9)], 0, None);
        assert_eq!(
            restore_start(Some(vec![track(1)]), track(9), context.clone()),
            alone
        );
        assert_eq!(restore_start(None, track(9), context), alone);
    }

    #[test]
    fn list_context_plays_only_a_list_in_the_contexts_order() {
        let playlist = SpotifyUri::from_uri("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M").unwrap();
        assert_eq!(
            list_context(Some(&playlist), true).as_deref(),
            Some("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")
        );
        assert_eq!(
            list_context(Some(&playlist), false),
            None,
            "sorted or filtered"
        );
        assert_eq!(list_context(None, true), None, "Liked Songs");
        assert_eq!(list_context(Some(&track(1)), true), None, "not a context");
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
            choice: 0,
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
            Restore::Held,
            "no reconnect yet"
        );
        assert_eq!(state.generation, generation);
        assert_eq!(
            prepare_restore(&mut state, "second".to_owned()),
            Restore::Adopted(Some((track(0), false, 42_000)))
        );
        assert!(
            state.generation > generation,
            "a radio fetch from the old session could replace the restored track"
        );
        assert_eq!(
            prepare_restore(&mut state, "second".to_owned()),
            Restore::Held,
            "a repeated notice for the same session restores nothing"
        );
        assert_eq!(
            prepare_restore(&mut state, "third".to_owned()),
            Restore::Adopted(Some((track(0), false, 42_000))),
            "a reconnect during a restore restores again"
        );
    }

    #[test]
    fn a_load_resolving_after_a_newer_choice_is_dropped() {
        let mut state = state_playing(track(0));
        let slow = state.claim();
        let fast = state.claim();

        let first = state.begin_context(vec![track(2)], None, None, true, Some(fast));
        assert_eq!(first.unwrap(), Some(track(2)));
        let first = state.begin_context(vec![track(1)], None, None, true, Some(slow));
        assert_eq!(first.unwrap(), None, "the slower load is dropped");
        assert_eq!(state.queue.current(), Some(&track(2)));

        let pending = state.claim();
        state.supersede();
        let first = state.begin_context(vec![track(1)], None, None, true, Some(pending));
        assert_eq!(first.unwrap(), None, "next or skip replaced it");

        let pending = state.claim();
        prepare_restore(&mut state, "reconnected".to_owned());
        let first = state.begin_context(vec![track(1)], None, None, true, Some(pending));
        assert_eq!(
            first.unwrap(),
            Some(track(1)),
            "a restore is not a user choice"
        );

        let first = state.begin_context(vec![track(3)], Some(0), None, true, None);
        assert_eq!(first.unwrap(), Some(track(3)), "load_tracks claims nothing");
    }

    #[test]
    fn a_pending_load_leaves_a_radio_fetch_running() {
        let mut state = state_playing(track(0));
        let radio = state.generation;
        let pending = state.claim();
        assert_eq!(
            state.generation, radio,
            "a load that fails would cancel radio"
        );
        state
            .begin_context(vec![track(1)], None, None, true, Some(pending))
            .unwrap();
        assert!(state.generation > radio, "the load that plays retires it");
    }

    #[test]
    fn remote_skips_are_capped_by_the_known_queue_or_a_blind_limit() {
        assert_eq!(remote_steps(Some(3), 2), 2);
        assert_eq!(remote_steps(Some(3), 9), 3);
        assert_eq!(remote_steps(None, 2), 2, "skips before the first push");
        assert_eq!(remote_steps(None, u32::MAX), MAX_BLIND_SKIPS);
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
    fn gate_lets_through_only_the_live_player_of_the_owning_role() {
        let owner = Owner::default();
        let local_epoch = Epoch::default();
        let gate = |epoch: &Epoch, role| Gate {
            epoch: epoch.clone(),
            role,
            owner: owner.clone(),
        };
        let local = gate(&local_epoch, Role::Local);
        let connect_epoch = Epoch::default();
        let connect = gate(&connect_epoch, Role::Connect);
        assert!(local.is_open(), "Local owns the sink at launch");
        assert!(!connect.is_open());

        assert_eq!(owner.set(Role::Connect), Role::Local);
        assert_eq!(owner.set(Role::Connect), Role::Connect, "one handover only");
        assert!(
            !local.is_open(),
            "the local player is silenced in Connect mode"
        );
        assert!(connect.is_open());

        connect_epoch.retire();
        assert!(!connect.is_open(), "a retired Connect link stays silent");
        owner.set(Role::Local);
        let rebuilt = gate(&local_epoch.next(), Role::Local);
        assert!(!local.is_open(), "a retuned-away player stays silent");
        assert!(rebuilt.is_open());
    }

    #[test]
    fn spirc_player_events_hand_the_sink_over() {
        let uri = track(0);
        let loading = PlayerEvent::Loading {
            play_request_id: 1,
            track_id: uri.clone(),
            position_ms: 0,
        };
        let paused = PlayerEvent::Paused {
            play_request_id: 1,
            track_id: uri.clone(),
            position_ms: 0,
        };
        let stopped = PlayerEvent::Stopped {
            play_request_id: 1,
            track_id: uri.clone(),
        };
        let position = PlayerEvent::PositionChanged {
            play_request_id: 1,
            track_id: uri,
            position_ms: 0,
        };
        assert_eq!(owner_after(&loading), Some(Role::Connect));
        assert_eq!(
            owner_after(&paused),
            Some(Role::Connect),
            "a paused transfer"
        );
        assert_eq!(owner_after(&stopped), Some(Role::Local));
        assert_eq!(owner_after(&position), None);
        assert_eq!(owner_after(&PlayerEvent::VolumeChanged { volume: 1 }), None);
    }

    fn playing() -> PlayerEvent {
        PlayerEvent::Playing {
            play_request_id: 1,
            track_id: track(0),
            position_ms: 0,
        }
    }

    #[test]
    fn a_late_event_from_a_retired_link_cannot_take_the_sink_back() {
        let owner = Owner::default();
        let epoch = Epoch::default();
        assert_eq!(connect_step(&owner, &epoch, true, &playing()), Step::Enter);

        // The forwarder checked the epoch, then the link was retired before
        // the event was applied.
        assert!(epoch.is_current());
        assert!(owner.retire(&epoch), "Connect held the sink");
        assert_eq!(connect_step(&owner, &epoch, true, &playing()), Step::Drop);

        assert_eq!(owner.get(), Role::Local, "the local player stays audible");
    }

    #[test]
    fn connect_takes_the_sink_only_once_its_handle_is_attached() {
        let owner = Owner::default();
        let epoch = Epoch::default();
        assert_eq!(connect_step(&owner, &epoch, false, &playing()), Step::Drop);
        assert_eq!(
            owner.get(),
            Role::Local,
            "commands would go to a muted player"
        );
        assert_eq!(connect_step(&owner, &epoch, true, &playing()), Step::Enter);
        assert_eq!(owner.get(), Role::Connect);
    }

    #[test]
    fn spirc_stop_returns_the_sink_once_and_idle_events_are_dropped() {
        let owner = Owner::default();
        let epoch = Epoch::default();
        let stopped = PlayerEvent::Stopped {
            play_request_id: 1,
            track_id: track(0),
        };
        assert_eq!(connect_step(&owner, &epoch, true, &stopped), Step::Drop);
        connect_step(&owner, &epoch, true, &playing());
        assert_eq!(connect_step(&owner, &epoch, true, &stopped), Step::Forward);
        assert_eq!(owner.get(), Role::Local);
        let tick = PlayerEvent::PositionChanged {
            play_request_id: 1,
            track_id: track(0),
            position_ms: 0,
        };
        assert_eq!(connect_step(&owner, &epoch, true, &tick), Step::Drop);
    }

    #[test]
    fn the_local_players_stop_is_hidden_while_another_device_plays() {
        let owner = Owner::default();
        assert!(owner.shows_local_events());
        owner.set_remote(true);
        assert!(
            !owner.shows_local_events(),
            "it would blank the remote's track"
        );
        owner.set_remote(false);
        assert!(owner.shows_local_events());
        owner.set(Role::Connect);
        assert!(!owner.shows_local_events());
    }

    fn followed(playing: bool) -> DeviceList {
        let mut list = DeviceList::default();
        list.remote = Some(RemotePlayback {
            device_id: "phone".to_owned(),
            uri: canonical(&track(0)),
            title: String::new(),
            duration_ms: 0,
            position_ms: 0,
            playing,
            volume: 0,
            device_name: String::new(),
        });
        list
    }

    #[test]
    fn remote_mode_follows_the_device_list_unless_this_mac_plays() {
        assert_eq!(remote_for(Role::Local, &DeviceList::default()), None);
        assert_eq!(
            remote_for(Role::Local, &followed(false)).map(|r| r.device_id),
            Some("phone".to_owned()),
            "a followed remote stays in control while paused"
        );
        assert_eq!(remote_for(Role::Connect, &followed(true)), None);
    }

    #[test]
    fn entering_remote_mode_stops_local_playback_and_retires_radio() {
        let owner = Owner::default();
        let mut state = state_playing(track(0));
        state.clock.wants_play = true;
        let generation = state.generation;

        assert!(enter_remote(&owner, &mut state), "the local player stops");
        assert!(owner.is_remote());
        assert!(
            state.generation > generation,
            "an in-flight radio fetch cannot load"
        );
        assert!(!state.clock.wants_play);

        owner.set(Role::Connect);
        assert!(
            !enter_remote(&owner, &mut state),
            "Spirc's player is not stopped"
        );
    }

    #[test]
    fn calls_reach_the_local_player_only_when_no_other_device_plays() {
        assert_eq!(route(Role::Local, false), Route::Local);
        assert_eq!(
            route(Role::Local, true),
            Route::Remote,
            "nothing loads or decodes locally while another device plays"
        );
        assert_eq!(route(Role::Connect, true), Route::Connect);
        assert_eq!(route(Role::Connect, false), Route::Connect);
    }

    #[test]
    fn spirc_repeat_maps_each_mode() {
        assert_eq!(spirc_repeat(RepeatMode::Off), (false, false));
        assert_eq!(spirc_repeat(RepeatMode::Context), (true, false));
        assert_eq!(spirc_repeat(RepeatMode::Track), (true, true));
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
                local_folders: Vec::new(),
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
                local_folders: Vec::new(),
            });
            assert_eq!(config.bitrate, expected);
            assert!(config.normalisation, "bitrate must not reset normalisation");
        };
        check(Bitrate::Kbps96, config::Bitrate::Bitrate96);
        check(Bitrate::Kbps160, config::Bitrate::Bitrate160);
        check(Bitrate::Kbps320, config::Bitrate::Bitrate320);
    }

    #[test]
    fn player_config_scans_local_folders() {
        let folders = vec![
            PathBuf::from("/Users/me/Music"),
            PathBuf::from("/Volumes/x"),
        ];
        let config = player_config(Tuning {
            normalisation: None,
            bitrate: Bitrate::Kbps320,
            local_folders: folders.clone(),
        });
        assert_eq!(config.local_file_directories, folders);
    }

    #[test]
    fn playable_accepts_tracks_episodes_and_local_files_only() {
        assert!(playable("spotify:track:4uLU6hMCjMI75M1A2tKUQ0").is_ok());
        assert!(playable("spotify:episode:4uLU6hMCjMI75M1A2tKUQ0").is_ok());
        assert!(playable("spotify:local:Daft+Punk:Discovery:One+More+Time:320").is_ok());
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
