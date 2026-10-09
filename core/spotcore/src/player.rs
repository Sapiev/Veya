//! Playback control over librespot's `Player`, fed through `AudioOutput`.
//!
//! A loaded URI expands to an ordered track list (the context); `next` and
//! `previous` walk it and the end of a track advances it. Shuffle, repeat
//! and Up Next belong to the queue model (PBI-203).

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use librespot_core::{Session, SpotifyUri};
use librespot_metadata::{Album, Artist, Metadata, Playlist};
use librespot_playback::config::PlayerConfig;
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::{Player, PlayerEvent};
use log::{info, warn};

use crate::audio::AudioOutput;
use crate::session::SpotSession;

const POSITION_INTERVAL: Duration = Duration::from_secs(1);

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

#[derive(Debug, Default, PartialEq)]
struct Queue {
    tracks: Vec<SpotifyUri>,
    index: usize,
}

impl Queue {
    fn current(&self) -> Option<&SpotifyUri> {
        self.tracks.get(self.index)
    }

    fn advance(&mut self) -> Option<&SpotifyUri> {
        if self.index + 1 >= self.tracks.len() {
            return None;
        }
        self.index += 1;
        self.current()
    }

    /// Steps back one track; on the first track, stays there to restart it.
    fn back(&mut self) -> Option<&SpotifyUri> {
        self.index = self.index.saturating_sub(1);
        self.current()
    }
}

#[derive(Default)]
struct State {
    queue: Queue,
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
            session_id: link.session_id(),
            ..State::default()
        }));
        let player = Player::new(config, link, Box::new(NoOpVolume), move || Box::new(sink));
        tokio::spawn(forward_events(
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
        state.queue = Queue { tracks, index: 0 };
        let first = state
            .queue
            .current()
            .cloned()
            .ok_or_else(|| PlayerError::EmptyContext {
                uri: canonical(&uri),
            })?;
        info!("loading context of {} items", state.queue.tracks.len());
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

    /// No-op on the last track.
    pub fn next(&self) {
        self.sync_session();
        if let Some(track) = lock(&self.state).queue.advance().cloned() {
            self.player.load(track, true, 0);
        }
    }

    pub fn previous(&self) {
        self.sync_session();
        if let Some(track) = lock(&self.state).queue.back().cloned() {
            self.player.load(track, true, 0);
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
        let session = self.session.current_session();
        let id = session.session_id();
        let mut state = lock(&self.state);
        if state.session_id != id {
            self.player.set_session(session.clone());
            state.session_id = id;
        }
        session
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
        if let PlayerEvent::EndOfTrack {
            play_request_id, ..
        } = event
        {
            let next = {
                let mut state = lock(&state);
                if state.request_id != Some(play_request_id) {
                    continue;
                }
                state.queue.advance().cloned()
            };
            match next {
                Some(track) => player.load(track, true, 0),
                None => player.stop(),
            }
        }
        if let Some(event) = map_event(event) {
            observer.on_event(event);
        }
    }
    warn!("player event channel closed");
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

    fn queue(len: u8, index: usize) -> Queue {
        Queue {
            tracks: (0..len).map(track).collect(),
            index,
        }
    }

    #[test]
    fn queue_advance_walks_forward_and_stops_at_end() {
        let mut q = queue(2, 0);
        assert_eq!(q.advance(), Some(&track(1)));
        assert_eq!(q.advance(), None);
        assert_eq!(q.index, 1);
    }

    #[test]
    fn queue_back_steps_back_and_restarts_first_track() {
        let mut q = queue(2, 1);
        assert_eq!(q.back(), Some(&track(0)));
        assert_eq!(q.back(), Some(&track(0)));
    }

    #[test]
    fn queue_empty_has_nothing_to_play() {
        let mut q = Queue::default();
        assert_eq!(q.current(), None);
        assert_eq!(q.advance(), None);
        assert_eq!(q.back(), None);
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
