//! Remote mode: another Connect device is active, so the app shows its
//! playback from the cluster and sends it connect-state commands
//! (ADR-009 Remote row, PBI-503). Nothing is decoded locally meanwhile.

use librespot_protocol::connect::ClusterUpdate;
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, PercentEncode, utf8_percent_encode};
use serde_json::{Value, json};

use crate::player::PlaybackEvent;

/// A connect-state player command. Bodies follow what Spotify's clients
/// send and what librespot's `Request` parser accepts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemoteCommand {
    Pause,
    Resume,
    SeekTo(u32),
    SkipNext,
    SkipPrev,
    Shuffle(bool),
    RepeatContext(bool),
    RepeatTrack(bool),
    Play(PlayRequest),
}

/// Plays the context `context_uri`, or `tracks` when it is `None`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PlayRequest {
    pub(crate) context_uri: Option<String>,
    pub(crate) tracks: Vec<String>,
    pub(crate) start_index: u32,
    pub(crate) seek_to: u32,
    pub(crate) paused: bool,
}

/// Device ids come from the cluster, so each is escaped as one path segment.
const SEGMENT: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

pub(crate) fn command_endpoint(from: &str, to: &str) -> String {
    let (from, to) = (segment(from), segment(to));
    format!("/connect-state/v1/player/command/from/{from}/to/{to}")
}

pub(crate) fn volume_endpoint(from: &str, to: &str) -> String {
    let (from, to) = (segment(from), segment(to));
    format!("/connect-state/v1/connect/volume/from/{from}/to/{to}")
}

fn segment(id: &str) -> PercentEncode<'_> {
    utf8_percent_encode(id, SEGMENT)
}

/// Wire format of the volume request: `{"volume": 0..=65535}`.
pub(crate) fn volume_body(volume: u16) -> Vec<u8> {
    json!({ "volume": volume }).to_string().into_bytes()
}

/// Wire format: `{"command": {"endpoint": ..., ..., "logging_params": {}}}`;
/// the server adds `message_id` and `sent_by_device_id`.
pub(crate) fn command_body(command: &RemoteCommand) -> Vec<u8> {
    let value = |endpoint: &str, value: bool| json!({ "endpoint": endpoint, "value": value });
    let mut body = match command {
        RemoteCommand::Pause => json!({ "endpoint": "pause" }),
        RemoteCommand::Resume => json!({ "endpoint": "resume" }),
        // Spirc reads the position from `value`; `position` must be present.
        RemoteCommand::SeekTo(ms) => json!({ "endpoint": "seek_to", "value": ms, "position": 0 }),
        RemoteCommand::SkipNext => json!({ "endpoint": "skip_next" }),
        RemoteCommand::SkipPrev => json!({ "endpoint": "skip_prev" }),
        RemoteCommand::Shuffle(on) => value("set_shuffling_context", *on),
        RemoteCommand::RepeatContext(on) => value("set_repeating_context", *on),
        RemoteCommand::RepeatTrack(on) => value("set_repeating_track", *on),
        RemoteCommand::Play(request) => play_command(request),
    };
    body["logging_params"] = json!({});
    json!({ "command": body }).to_string().into_bytes()
}

fn play_command(request: &PlayRequest) -> Value {
    let context = match &request.context_uri {
        Some(uri) => json!({ "uri": uri, "url": format!("context://{uri}") }),
        None => {
            let tracks: Vec<_> = request
                .tracks
                .iter()
                .map(|uri| json!({ "uri": uri }))
                .collect();
            json!({ "pages": [{ "tracks": tracks }] })
        }
    };
    json!({
        "endpoint": "play",
        "context": context,
        "play_origin": { "feature_identifier": "veya" },
        "options": {
            "skip_to": skip_to(request),
            "seek_to": request.seek_to,
            "initially_paused": request.paused,
        },
    })
}

/// The start track by index and, for a track list, by uri: Spirc and
/// Spotify's clients prefer the uri when both are given.
// shortcut: these play bodies are checked against librespot's parser, not
// against Spotify's own clients; verify with a real device.
fn skip_to(request: &PlayRequest) -> Value {
    let mut skip_to = json!({ "track_index": request.start_index });
    if let Some(uri) = request.tracks.get(request.start_index as usize) {
        skip_to["track_uri"] = json!(uri);
    }
    skip_to
}

/// The active remote device's playback, from one cluster update.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemotePlayback {
    pub(crate) device_id: String,
    pub(crate) uri: String,
    pub(crate) title: String,
    pub(crate) duration_ms: u32,
    pub(crate) position_ms: u32,
    pub(crate) playing: bool,
    pub(crate) volume: u16,
    pub(crate) device_name: String,
}

/// `None` unless a device other than this Mac (`this_id`) is active. The
/// position is extrapolated to the server's timestamp of the update.
pub(crate) fn remote_playback(update: &ClusterUpdate, this_id: &str) -> Option<RemotePlayback> {
    let cluster = &update.cluster;
    let active = &cluster.active_device_id;
    if active.is_empty() || active == this_id {
        return None;
    }
    let state = &cluster.player_state;
    let device = cluster.device.get(active);
    let playing = state.is_playing && !state.is_paused;
    let elapsed = if playing {
        cluster
            .server_timestamp_ms
            .saturating_sub(state.timestamp)
            .max(0)
    } else {
        0
    };
    let mut position = state
        .position_as_of_timestamp
        .saturating_add(elapsed)
        .max(0);
    if state.duration > 0 {
        position = position.min(state.duration);
    }
    let ms = |value: i64| u32::try_from(value.max(0)).unwrap_or(u32::MAX);
    Some(RemotePlayback {
        device_id: active.clone(),
        uri: state.track.uri.clone(),
        title: state
            .track
            .metadata
            .get("title")
            .cloned()
            .unwrap_or_default(),
        duration_ms: ms(state.duration),
        position_ms: ms(position),
        playing,
        volume: device.map_or(0, |info| u16::try_from(info.volume).unwrap_or(u16::MAX)),
        device_name: device.map(|info| info.name.clone()).unwrap_or_default(),
    })
}

/// How a cluster update moves the app between Local and Remote mode.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Change {
    Stay,
    /// Stop the local player: nothing decodes while another device plays.
    Enter,
    /// Back to Local without resuming.
    Leave,
}

/// One cluster update applied to Remote mode (ADR-009): `previous` is the
/// remote the app follows, `observed` the cluster's other active device.
/// Returns the change, the remote to follow next and the events showing it.
pub(crate) fn remote_change(
    previous: Option<&RemotePlayback>,
    observed: Option<RemotePlayback>,
    active: &str,
) -> (Change, Option<RemotePlayback>, Vec<PlaybackEvent>) {
    let stopped = || vec![PlaybackEvent::Stopped];
    match (previous, observed) {
        (None, Some(next)) if next.playing => {
            let events = remote_events(None, &next);
            (Change::Enter, Some(next), events)
        }
        // A paused device stays active for a long time; it does not take over.
        (None, _) => (Change::Stay, None, Vec::new()),
        (Some(previous), Some(next)) if next.device_id == previous.device_id || next.playing => {
            let events = remote_events(Some(previous), &next);
            (Change::Stay, Some(next), events)
        }
        (Some(_), Some(_)) => (Change::Leave, None, stopped()),
        // This Mac taking over reports through Spirc's player instead.
        (Some(_), None) if active.is_empty() => (Change::Leave, None, stopped()),
        (Some(_), None) => (Change::Leave, None, Vec::new()),
    }
}

/// Only what changed since `previous`, so the bar does not re-render on
/// every cluster update.
fn remote_events(previous: Option<&RemotePlayback>, next: &RemotePlayback) -> Vec<PlaybackEvent> {
    let mut events = Vec::new();
    if next.uri.is_empty() {
        if previous.is_none_or(|p| !p.uri.is_empty()) {
            events.push(PlaybackEvent::Stopped);
        }
    } else {
        if previous.is_none_or(|p| p.uri != next.uri || p.title != next.title) {
            events.push(PlaybackEvent::TrackChanged {
                uri: next.uri.clone(),
                name: next.title.clone(),
                duration_ms: next.duration_ms,
            });
        }
        let moved = |p: &RemotePlayback| {
            (&p.uri, p.playing, p.position_ms) != (&next.uri, next.playing, next.position_ms)
        };
        if previous.is_none_or(moved) {
            let (uri, position_ms) = (next.uri.clone(), next.position_ms);
            events.push(if next.playing {
                PlaybackEvent::Playing { uri, position_ms }
            } else {
                PlaybackEvent::Paused { uri, position_ms }
            });
        }
    }
    if previous.is_none_or(|p| (p.volume, &p.device_name) != (next.volume, &next.device_name)) {
        events.push(PlaybackEvent::RemoteChanged {
            device_name: Some(next.device_name.clone()),
            volume: Some(next.volume),
        });
    }
    events
}

/// Whether a local load leaves Remote mode: it does while the remote is
/// paused, so the Mac plays; a playing remote takes the load.
pub(crate) fn load_leaves_remote(remote: &RemotePlayback) -> bool {
    !remote.playing
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_core::dealer::protocol::{Command, Request};
    use librespot_protocol::connect::{Cluster, DeviceInfo};
    use librespot_protocol::player::{PlayerState, ProvidedTrack};

    const TRACK: &str = "spotify:track:4uLU6hMCjMI75M1A2tKUQA";

    /// Parses `body` the way Spirc does once the server delivers it.
    fn delivered(body: &[u8]) -> Command {
        let mut request: serde_json::Value = serde_json::from_slice(body).unwrap();
        request["message_id"] = 1.into();
        request["sent_by_device_id"] = "mac-connect".into();
        serde_json::from_value::<Request>(request).unwrap().command
    }

    #[test]
    fn transport_commands_parse_as_spirc_reads_them() {
        assert!(matches!(
            delivered(&command_body(&RemoteCommand::Pause)),
            Command::Pause(_)
        ));
        assert!(matches!(
            delivered(&command_body(&RemoteCommand::Resume)),
            Command::Resume(_)
        ));
        assert!(matches!(
            delivered(&command_body(&RemoteCommand::SkipNext)),
            Command::SkipNext(c) if c.track.is_none()
        ));
        assert!(matches!(
            delivered(&command_body(&RemoteCommand::SkipPrev)),
            Command::SkipPrev(_)
        ));
        assert!(matches!(
            delivered(&command_body(&RemoteCommand::SeekTo(42_000))),
            Command::SeekTo(c) if c.value == 42_000
        ));
    }

    #[test]
    fn option_commands_parse_as_spirc_reads_them() {
        assert!(matches!(
            delivered(&command_body(&RemoteCommand::Shuffle(true))),
            Command::SetShufflingContext(c) if c.value
        ));
        assert!(matches!(
            delivered(&command_body(&RemoteCommand::RepeatContext(false))),
            Command::SetRepeatingContext(c) if !c.value
        ));
        assert!(matches!(
            delivered(&command_body(&RemoteCommand::RepeatTrack(true))),
            Command::SetRepeatingTrack(c) if c.value
        ));
    }

    #[test]
    fn play_a_context_parses_with_its_uri_and_options() {
        let request = PlayRequest {
            context_uri: Some("spotify:album:4uLU6hMCjMI75M1A2tKUQB".to_owned()),
            tracks: Vec::new(),
            start_index: 0,
            seek_to: 5_000,
            paused: true,
        };
        let Command::Play(play) = delivered(&command_body(&RemoteCommand::Play(request))) else {
            panic!("not play");
        };
        assert_eq!(play.context.uri(), "spotify:album:4uLU6hMCjMI75M1A2tKUQB");
        assert_eq!(play.options.seek_to, Some(5_000));
        assert_eq!(play.options.initially_paused, Some(true));
    }

    #[test]
    fn play_a_track_list_parses_with_its_tracks_and_start() {
        let request = PlayRequest {
            context_uri: None,
            tracks: vec![
                TRACK.to_owned(),
                "spotify:track:4uLU6hMCjMI75M1A2tKUQB".to_owned(),
            ],
            start_index: 1,
            seek_to: 0,
            paused: false,
        };
        let Command::Play(play) = delivered(&command_body(&RemoteCommand::Play(request))) else {
            panic!("not play");
        };
        assert!(
            play.context.uri.is_none(),
            "Spirc plays the pages when there is no uri"
        );
        let uris: Vec<_> = play.context.pages[0]
            .tracks
            .iter()
            .map(|t| t.uri())
            .collect();
        assert_eq!(uris, [TRACK, "spotify:track:4uLU6hMCjMI75M1A2tKUQB"]);
        let skip_to = play.options.skip_to.unwrap();
        assert_eq!(skip_to.track_index, Some(1));
        assert_eq!(
            skip_to.track_uri.as_deref(),
            Some("spotify:track:4uLU6hMCjMI75M1A2tKUQB"),
            "Spirc starts at the uri before the index"
        );
    }

    #[test]
    fn endpoints_and_volume_body_are_pinned() {
        assert_eq!(
            command_endpoint("mac", "phone"),
            "/connect-state/v1/player/command/from/mac/to/phone"
        );
        assert_eq!(
            volume_endpoint("mac", "phone"),
            "/connect-state/v1/connect/volume/from/mac/to/phone"
        );
        assert_eq!(volume_body(32_768), br#"{"volume":32768}"#);
    }

    #[test]
    fn device_ids_cannot_leave_their_path_segment() {
        assert_eq!(
            command_endpoint("a-b_c.d~e", "../x/y?z#w"),
            "/connect-state/v1/player/command/from/a-b_c.d~e/to/..%2Fx%2Fy%3Fz%23w"
        );
    }

    fn cluster(active: &str, playing: bool) -> ClusterUpdate {
        let mut track = ProvidedTrack {
            uri: TRACK.to_owned(),
            ..Default::default()
        };
        track.metadata.insert("title".to_owned(), "Song".to_owned());
        let state = PlayerState {
            track: Some(track).into(),
            timestamp: 10_000,
            position_as_of_timestamp: 30_000,
            duration: 200_000,
            is_playing: true,
            is_paused: !playing,
            ..Default::default()
        };
        let mut cluster = Cluster {
            active_device_id: active.to_owned(),
            player_state: Some(state).into(),
            server_timestamp_ms: 12_500,
            ..Default::default()
        };
        cluster.device.insert(
            "phone".to_owned(),
            DeviceInfo {
                volume: 6_554,
                name: "Pixel".to_owned(),
                ..Default::default()
            },
        );
        ClusterUpdate {
            cluster: Some(cluster).into(),
            ..Default::default()
        }
    }

    #[test]
    fn remote_playback_extrapolates_position_while_playing() {
        let playing = remote_playback(&cluster("phone", true), "mac").unwrap();
        assert_eq!(
            playing,
            RemotePlayback {
                device_id: "phone".to_owned(),
                uri: TRACK.to_owned(),
                title: "Song".to_owned(),
                duration_ms: 200_000,
                position_ms: 32_500,
                playing: true,
                volume: 6_554,
                device_name: "Pixel".to_owned(),
            }
        );
        let paused = remote_playback(&cluster("phone", false), "mac").unwrap();
        assert_eq!(paused.position_ms, 30_000, "a paused remote stays put");
        assert!(!paused.playing);
    }

    #[test]
    fn remote_playback_needs_another_active_device() {
        assert_eq!(remote_playback(&cluster("", true), "mac"), None);
        assert_eq!(remote_playback(&cluster("mac", true), "mac"), None);
        assert_eq!(remote_playback(&ClusterUpdate::default(), "mac"), None);
    }

    fn playing(active: &str) -> Option<RemotePlayback> {
        remote_playback(&cluster(active, true), "mac")
    }

    fn paused(active: &str) -> Option<RemotePlayback> {
        remote_playback(&cluster(active, false), "mac")
    }

    #[test]
    fn entering_remote_mode_stops_local_playback_and_shows_the_remote() {
        let (change, next, events) = remote_change(None, playing("phone"), "phone");
        assert_eq!(change, Change::Enter);
        assert_eq!(next, playing("phone"));
        assert_eq!(
            events,
            [
                PlaybackEvent::TrackChanged {
                    uri: TRACK.to_owned(),
                    name: "Song".to_owned(),
                    duration_ms: 200_000
                },
                PlaybackEvent::Playing {
                    uri: TRACK.to_owned(),
                    position_ms: 32_500
                },
                PlaybackEvent::RemoteChanged {
                    device_name: Some("Pixel".to_owned()),
                    volume: Some(6_554)
                },
            ]
        );
    }

    #[test]
    fn a_paused_remote_does_not_take_over() {
        assert_eq!(
            remote_change(None, paused("phone"), "phone"),
            (Change::Stay, None, Vec::new())
        );
    }

    #[test]
    fn a_followed_remote_that_pauses_stays_in_control() {
        let (change, next, events) =
            remote_change(playing("phone").as_ref(), paused("phone"), "phone");
        assert_eq!(change, Change::Stay);
        assert_eq!(next, paused("phone"), "the Mac can resume it");
        assert_eq!(
            events,
            [PlaybackEvent::Paused {
                uri: TRACK.to_owned(),
                position_ms: 30_000
            }]
        );
    }

    #[test]
    fn a_renamed_remote_updates_the_label_with_its_volume() {
        let mut renamed = playing("phone").unwrap();
        renamed.device_name = "Kitchen".to_owned();
        let (_, _, events) = remote_change(playing("phone").as_ref(), Some(renamed), "phone");
        assert_eq!(
            events,
            [PlaybackEvent::RemoteChanged {
                device_name: Some("Kitchen".to_owned()),
                volume: Some(6_554)
            }]
        );
    }

    #[test]
    fn an_unchanged_update_reports_nothing() {
        let (_, _, events) = remote_change(paused("phone").as_ref(), paused("phone"), "phone");
        assert!(events.is_empty());
    }

    #[test]
    fn a_remote_without_a_track_shows_nothing_playing() {
        let mut empty = remote_playback(&cluster("phone", true), "mac").unwrap();
        empty.uri.clear();
        let (change, _, events) = remote_change(None, Some(empty), "phone");
        assert_eq!(change, Change::Enter);
        assert_eq!(events[0], PlaybackEvent::Stopped);
    }

    #[test]
    fn leaving_remote_mode_stops_only_when_nothing_plays_here() {
        let remote = playing("phone");
        assert_eq!(
            remote_change(remote.as_ref(), None, ""),
            (Change::Leave, None, vec![PlaybackEvent::Stopped])
        );
        assert_eq!(
            remote_change(remote.as_ref(), None, "mac"),
            (Change::Leave, None, Vec::new()),
            "this Mac's Spirc player reports its own playback"
        );
        assert_eq!(
            remote_change(remote.as_ref(), paused("speaker"), "speaker").0,
            Change::Leave,
            "a different paused device does not keep control"
        );
        assert_eq!(remote_change(None, None, "").0, Change::Stay);
    }

    #[test]
    fn a_local_load_leaves_a_paused_remote_but_not_a_playing_one() {
        assert!(load_leaves_remote(&paused("phone").unwrap()));
        assert!(!load_leaves_remote(&playing("phone").unwrap()));
    }

    #[test]
    fn position_survives_extreme_timestamps() {
        let mut update = cluster("phone", true);
        update.cluster.mut_or_insert_default().server_timestamp_ms = i64::MIN;
        update
            .cluster
            .mut_or_insert_default()
            .player_state
            .mut_or_insert_default()
            .timestamp = i64::MAX;
        assert_eq!(remote_playback(&update, "mac").unwrap().position_ms, 30_000);
        update.cluster.mut_or_insert_default().server_timestamp_ms = i64::MAX;
        update
            .cluster
            .mut_or_insert_default()
            .player_state
            .mut_or_insert_default()
            .timestamp = i64::MIN;
        assert_eq!(
            remote_playback(&update, "mac").unwrap().position_ms,
            200_000,
            "clamped to the duration"
        );
    }
}
