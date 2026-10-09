//! Playback control over librespot's `Player`, fed through `AudioOutput`.
//!
//! A loaded URI expands to an ordered track list (the context) held by
//! `Queue` with Up Next, shuffle and repeat; `next` and `previous` walk it,
//! the end of a track advances it, and an exhausted context continues with
//! Spotify's autoplay radio for it.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use librespot_core::{Session, SpotifyUri};
use librespot_metadata::{Album, Artist, Metadata, Playlist};
use librespot_playback::config::PlayerConfig;
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::{Player, PlayerEvent};
use librespot_protocol::autoplay_context_request::AutoplayContextRequest;
use librespot_protocol::context::Context;
use log::{info, warn};

use crate::audio::AudioOutput;
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
        *self = Self {
            position_ms,
            reported_at: Some(Instant::now()),
            playing,
        };
    }

    fn position_ms(&self) -> u32 {
        let since = match self.reported_at {
            Some(at) if self.playing => at.elapsed().as_millis(),
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
    player: Arc<Player>,
    state: Arc<Mutex<State>>,
}

fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[uniffi::export(async_runtime = "tokio")]
impl SpotPlayer {
    /// Async so librespot's tasks spawn on the UniFFI tokio runtime.
    #[uniffi::constructor]
    pub async fn new(
        session: Arc<SpotSession>,
        output: Arc<AudioOutput>,
        observer: Arc<dyn PlayerObserver>,
    ) -> Result<Arc<Self>, PlayerError> {
        let sink = output.take_sink().ok_or(PlayerError::OutputTaken)?;
        let link = session.current_session();
        let config = PlayerConfig {
            position_update_interval: Some(POSITION_INTERVAL),
            ..PlayerConfig::default()
        };
        let state = Arc::new(Mutex::new(State {
            queue: Queue::default(),
            context_uri: None,
            autoplay: true,
            generation: 0,
            clock: Clock::default(),
            request_id: None,
            session_id: link.session_id(),
        }));
        let player = Player::new(config, link, Box::new(NoOpVolume), move || Box::new(sink));
        tokio::spawn(forward_events(
            Arc::clone(&session),
            Arc::clone(&player),
            Arc::clone(&state),
            observer,
        ));
        Ok(Arc::new(Self {
            session,
            player,
            state,
        }))
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
        let session = self.sync_session();
        let tracks = resolve(&session, &uri).await?;
        let mut state = lock(&self.state);
        state.queue.set_context(tracks, seed());
        state.context_uri = Some(uri.clone());
        state.generation += 1;
        let first = state
            .queue
            .current()
            .cloned()
            .ok_or_else(|| PlayerError::EmptyContext {
                uri: canonical(&uri),
            })?;
        info!("loading context of {} items", state.queue.tracks().len());
        self.player.load(first, autoplay, start_ms);
        Ok(())
    }

    pub fn play(&self) {
        self.player.play();
    }

    pub fn pause(&self) {
        self.player.pause();
    }

    pub fn seek(&self, position_ms: u32) {
        self.player.seek(position_ms);
    }

    /// Plays Up Next first, then the context. No-op at the end of the
    /// context unless repeat is on.
    pub fn next(&self) {
        self.sync_session();
        let mut state = lock(&self.state);
        if let Some(track) = state.queue.advance(true).cloned() {
            state.generation += 1;
            self.player.load(track, true, 0);
        }
    }

    /// Restarts the track once it is more than 3 s in, as Spotify does;
    /// otherwise goes back one track.
    pub fn previous(&self) {
        self.sync_session();
        let mut state = lock(&self.state);
        if state.clock.position_ms() > RESTART_THRESHOLD_MS {
            self.player.seek(0);
        } else if let Some(track) = state.queue.back().cloned() {
            state.generation += 1;
            self.player.load(track, true, 0);
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
        self.player.stop();
    }
}

impl SpotPlayer {
    /// Hands the player the supervisor's current session if a reconnect
    /// replaced the one it holds; loads on a dead session would fail.
    fn sync_session(&self) -> Session {
        sync_session(&self.session, &self.player, &self.state)
    }
}

fn sync_session(spot: &SpotSession, player: &Player, state: &Mutex<State>) -> Session {
    let session = spot.current_session();
    let id = session.session_id();
    let mut state = lock(state);
    if state.session_id != id {
        player.set_session(session.clone());
        state.session_id = id;
    }
    session
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
        self.player.stop();
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

async fn forward_events(
    session: Arc<SpotSession>,
    player: Arc<Player>,
    state: Arc<Mutex<State>>,
    observer: Arc<dyn PlayerObserver>,
) {
    let mut events = player.get_player_event_channel();
    while let Some(event) = events.recv().await {
        if let PlayerEvent::PlayRequestIdChanged { play_request_id } = event {
            lock(&state).request_id = Some(play_request_id);
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
            lock(&state).clock.note(&event);
            observer.on_event(event);
        }
        if context_ended && !continue_with_radio(&session, &player, &state).await {
            player.stop();
        }
    }
    warn!("player event channel closed");
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
        clock.note(&PlaybackEvent::Stopped);
        assert_eq!(clock.position_ms(), 0);
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
