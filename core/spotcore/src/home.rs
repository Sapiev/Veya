//! Home page sources: recently played tracks from the Web API, recent
//! contexts and track or artist radio through spclient.

use std::sync::Arc;

use http::Method;
use librespot_core::SpotifyUri;
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use serde::Deserialize;

use crate::account::{MAX_BODY_BYTES, read_capped, web_api_client};
use crate::player::{is_spotify_context, restorable_context};
use crate::session::SpotSession;

const RECENTLY_PLAYED_URL: &str = "https://api.spotify.com/v1/me/player/recently-played";
pub(crate) const PLAYER_URL: &str = "https://api.spotify.com/v1/me/player";
/// The Web API's maximum page size for recently played.
const RECENTLY_PLAYED_LIMIT: u32 = 50;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HomeError {
    #[error("not a track or artist URI: {uri}")]
    InvalidSeed { uri: String },
    /// Tokens from before the scope was added need a fresh sign-in.
    #[error("the access token lacks the user-read-recently-played scope")]
    MissingScope,
    #[error("network error: {message}")]
    Network { message: String },
    #[error("request returned HTTP {status}")]
    Request { status: u16 },
    #[error("spclient request failed: {message}")]
    Spclient { message: String },
    #[error("malformed response: {message}")]
    Malformed { message: String },
}

impl From<librespot_core::Error> for HomeError {
    fn from(e: librespot_core::Error) -> Self {
        Self::Spclient {
            message: e.to_string(),
        }
    }
}

impl From<serde_json::Error> for HomeError {
    fn from(e: serde_json::Error) -> Self {
        Self::Malformed {
            message: e.to_string(),
        }
    }
}

/// Distinct URIs, most recent first. `contexts` are the albums, playlists,
/// artists and shows the tracks were played from ("Jump Back In").
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RecentlyPlayed {
    pub tracks: Vec<String>,
    pub contexts: Vec<String>,
}

#[derive(Deserialize)]
struct History {
    items: Vec<Play>,
}

#[derive(Deserialize)]
struct Play {
    track: Option<UriOnly>,
    context: Option<UriOnly>,
    played_at: Option<String>,
}

#[derive(Deserialize)]
struct UriOnly {
    uri: String,
}

/// The account's last 50 plays; needs the `user-read-recently-played` scope.
#[uniffi::export(async_runtime = "tokio")]
pub async fn recently_played(access_token: String) -> Result<RecentlyPlayed, HomeError> {
    recently_played_at(RECENTLY_PLAYED_URL, &access_token).await
}

async fn recently_played_at(url: &str, access_token: &str) -> Result<RecentlyPlayed, HomeError> {
    Ok(distinct_plays(history_at(url, access_token).await?))
}

/// The newest recorded play with a valid track.
#[derive(Debug, PartialEq)]
pub(crate) struct LastPlay {
    pub track: String,
    /// Only a playable context.
    pub context: Option<String>,
    /// Unix milliseconds; `i64::MIN` when the server sent none or garbage.
    pub played_at_ms: i64,
}

pub(crate) async fn last_play(access_token: &str) -> Result<Option<LastPlay>, HomeError> {
    last_play_at(RECENTLY_PLAYED_URL, access_token).await
}

async fn last_play_at(url: &str, access_token: &str) -> Result<Option<LastPlay>, HomeError> {
    let plays = history_at(url, access_token).await?;
    Ok(plays.into_iter().find_map(|play| {
        Some(LastPlay {
            track: canonical(&play.track?.uri, is_track)?,
            context: play.context.and_then(|c| restorable_context(&c.uri)),
            played_at_ms: play
                .played_at
                .as_deref()
                .and_then(unix_ms)
                .unwrap_or(i64::MIN),
        })
    }))
}

fn unix_ms(rfc3339: &str) -> Option<i64> {
    let at = time::OffsetDateTime::parse(rfc3339, &time::format_description::well_known::Rfc3339)
        .ok()?;
    i64::try_from(at.unix_timestamp_nanos() / 1_000_000).ok()
}

async fn history_at(url: &str, access_token: &str) -> Result<Vec<Play>, HomeError> {
    let body = web_api_get(
        &format!("{url}?limit={RECENTLY_PLAYED_LIMIT}"),
        access_token,
    )
    .await?;
    let history: History = serde_json::from_slice(&body)?;
    Ok(history.items)
}

pub(crate) async fn web_api_get(url: &str, access_token: &str) -> Result<Vec<u8>, HomeError> {
    let http = web_api_client().map_err(network)?;
    let response = http
        .get(url)
        .bearer_auth(access_token)
        .send()
        .await
        .map_err(network)?;
    match response.status().as_u16() {
        200..=299 => {}
        403 => return Err(HomeError::MissingScope),
        status => return Err(HomeError::Request { status }),
    }
    read_capped(response, MAX_BODY_BYTES, network, || HomeError::Malformed {
        message: "response too large".to_owned(),
    })
    .await
}

/// The account's playback state per `GET /me/player`, validated.
#[derive(Debug, PartialEq)]
pub(crate) struct CurrentPlayback {
    pub device_id: Option<String>,
    pub is_playing: bool,
    /// A track or episode.
    pub item: Option<String>,
    pub context: Option<String>,
    /// Within the item's duration.
    pub progress_ms: u32,
}

#[derive(Deserialize)]
struct PlayerJson {
    device: Option<DeviceJson>,
    #[serde(default)]
    is_playing: bool,
    progress_ms: Option<i64>,
    item: Option<ItemJson>,
    context: Option<UriOnly>,
}

#[derive(Deserialize)]
struct DeviceJson {
    id: Option<String>,
}

#[derive(Deserialize)]
struct ItemJson {
    uri: Option<String>,
    duration_ms: Option<i64>,
}

/// Needs the `user-read-playback-state` scope; `None` when the account has no
/// playback session.
pub(crate) async fn current_playback(
    access_token: &str,
) -> Result<Option<CurrentPlayback>, HomeError> {
    current_playback_from(&web_api_get(PLAYER_URL, access_token).await?)
}

/// Server text is untrusted: URIs must parse as the expected kinds, and the
/// progress is clamped to the item.
fn current_playback_from(body: &[u8]) -> Result<Option<CurrentPlayback>, HomeError> {
    // 204 No Content: no playback session.
    if body.iter().all(u8::is_ascii_whitespace) {
        return Ok(None);
    }
    let json: PlayerJson = serde_json::from_slice(body)?;
    let item = json
        .item
        .as_ref()
        .and_then(|item| canonical(item.uri.as_deref()?, is_playable_item));
    let end = json
        .item
        .and_then(|item| item.duration_ms)
        .filter(|&ms| ms > 0)
        .unwrap_or(i64::from(u32::MAX));
    let progress_ms = json.progress_ms.unwrap_or(0).clamp(0, end);
    Ok(Some(CurrentPlayback {
        device_id: json.device.and_then(|d| d.id).filter(|id| !id.is_empty()),
        is_playing: json.is_playing,
        item,
        context: json.context.and_then(|c| restorable_context(&c.uri)),
        progress_ms: u32::try_from(progress_ms).unwrap_or(u32::MAX),
    }))
}

/// Server text is untrusted: only URIs that parse as the expected kinds pass.
fn distinct_plays(plays: Vec<Play>) -> RecentlyPlayed {
    let mut recent = RecentlyPlayed {
        tracks: Vec::new(),
        contexts: Vec::new(),
    };
    for play in plays {
        push_new(
            &mut recent.tracks,
            play.track.and_then(|t| canonical(&t.uri, is_track)),
        );
        push_new(
            &mut recent.contexts,
            play.context
                .and_then(|c| canonical(&c.uri, is_spotify_context)),
        );
    }
    recent
}

fn push_new(list: &mut Vec<String>, uri: Option<String>) {
    if let Some(uri) = uri.filter(|uri| !list.contains(uri)) {
        list.push(uri);
    }
}

pub(crate) fn canonical(uri: &str, accept: fn(&SpotifyUri) -> bool) -> Option<String> {
    let parsed = SpotifyUri::from_uri(uri).ok().filter(accept)?;
    Some(parsed.to_uri())
}

fn is_track(uri: &SpotifyUri) -> bool {
    matches!(uri, SpotifyUri::Track { .. })
}

pub(crate) fn is_playable_item(uri: &SpotifyUri) -> bool {
    matches!(uri, SpotifyUri::Track { .. } | SpotifyUri::Episode { .. })
}

fn is_radio_seed(uri: &SpotifyUri) -> bool {
    matches!(uri, SpotifyUri::Track { .. } | SpotifyUri::Artist { .. })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Radio {
    media_items: Vec<UriOnly>,
}

/// spclient's recently played contexts, newest first.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlayContexts {
    #[serde(default)]
    play_contexts: Vec<UriOnly>,
}

#[derive(uniffi::Object)]
pub struct HomeService {
    session: Arc<SpotSession>,
}

#[uniffi::export(async_runtime = "tokio")]
impl HomeService {
    #[uniffi::constructor]
    pub fn new(session: Arc<SpotSession>) -> Arc<Self> {
        Arc::new(Self { session })
    }

    /// The radio playlist URI seeded by a track or artist, to load like any
    /// other playlist context.
    pub async fn radio(&self, seed_uri: String) -> Result<String, HomeError> {
        let seed = SpotifyUri::from_uri(&seed_uri)
            .ok()
            .filter(is_radio_seed)
            .ok_or_else(|| HomeError::InvalidSeed {
                uri: seed_uri.clone(),
            })?;
        let body = self
            .session
            .current_session()
            .spclient()
            .get_radio_for_track(&seed)
            .await?;
        radio_playlist(&body)
    }

    /// Distinct albums, playlists, artists and shows played from, newest
    /// first. Unlike the Web API's last 50 tracks, this spans many contexts.
    pub async fn recent_contexts(&self) -> Result<Vec<String>, HomeError> {
        let session = self.session.current_session();
        let user = utf8_percent_encode(&session.username(), NON_ALPHANUMERIC).to_string();
        let endpoint = format!(
            "/recently-played/v3/user/{user}/recently-played?format=json&offset=0&limit=50&filter=default,collection-new-episodes&market=from_token"
        );
        let body = session
            .spclient()
            .request_as_json(&Method::GET, &endpoint, None, None)
            .await?;
        recent_contexts(&body)
    }
}

/// Server text is untrusted: only URIs that parse as contexts pass.
fn recent_contexts(body: &[u8]) -> Result<Vec<String>, HomeError> {
    let history: PlayContexts = serde_json::from_slice(body)?;
    let mut contexts = Vec::new();
    for context in history.play_contexts {
        push_new(&mut contexts, canonical(&context.uri, is_spotify_context));
    }
    Ok(contexts)
}

fn radio_playlist(body: &[u8]) -> Result<String, HomeError> {
    let radio: Radio = serde_json::from_slice(body)?;
    radio
        .media_items
        .iter()
        .find_map(|item| canonical(&item.uri, |u| matches!(u, SpotifyUri::Playlist { .. })))
        .ok_or_else(|| HomeError::Malformed {
            message: "no radio playlist".to_owned(),
        })
}

fn network(error: reqwest::Error) -> HomeError {
    HomeError::Network {
        message: error.without_url().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account::fake_web_api;

    const T1: &str = "spotify:track:4uLU6hMCjMI75M1A2tKUQC";
    const T2: &str = "spotify:track:512ojhOuo1ktJprKbVcKyQ";
    const ALBUM: &str = "spotify:album:4rOoJ6Egrf8K2IrywzwOMk";
    const LIST: &str = "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M";

    fn play(track: &str, context: Option<&str>) -> String {
        let context = context.map_or("null".to_owned(), |uri| {
            format!(r#"{{"uri":"{uri}","type":"x"}}"#)
        });
        format!(
            r#"{{"track":{{"uri":"{track}","name":"n"}},"played_at":"2026-10-09T10:00:00Z","context":{context}}}"#
        )
    }

    #[tokio::test]
    async fn recently_played_dedupes_in_order_and_keeps_known_contexts() {
        let items = [
            play(T1, Some(LIST)),
            play(T2, Some(ALBUM)),
            play(T1, Some(LIST)),
            play(T2, None),
            play(T2, Some("spotify:user:me:collection")),
            play("spotify:episode:4rOoJ6Egrf8K2IrywzwOMk", Some("garbage")),
        ];
        let body = format!(r#"{{"items":[{}],"limit":50}}"#, items.join(","));
        let (base, server) = fake_web_api(vec![("200 OK", body)]).await;

        let recent = recently_played_at(&base, "at-1").await.unwrap();

        assert_eq!(recent.tracks, [T1, T2]);
        assert_eq!(recent.contexts, [LIST, ALBUM]);
        let head = server.await.unwrap().remove(0).to_lowercase();
        assert!(head.starts_with("get /?limit=50 "), "{head}");
        assert!(head.contains("authorization: bearer at-1"), "{head}");
    }

    #[tokio::test]
    async fn recently_played_failures_are_typed() {
        let (base, _server) = fake_web_api(vec![("403 Forbidden", "{}".to_owned())]).await;
        let error = recently_played_at(&base, "at").await.unwrap_err();
        assert!(matches!(error, HomeError::MissingScope), "{error:?}");

        let (base, _server) = fake_web_api(vec![("401 Unauthorized", "{}".to_owned())]).await;
        let error = recently_played_at(&base, "at").await.unwrap_err();
        assert!(
            matches!(error, HomeError::Request { status: 401 }),
            "{error:?}"
        );

        let (base, _server) = fake_web_api(vec![("200 OK", "<html>".to_owned())]).await;
        let error = recently_played_at(&base, "at").await.unwrap_err();
        assert!(matches!(error, HomeError::Malformed { .. }), "{error:?}");

        let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let error = recently_played_at(&base, "at").await.unwrap_err();
        assert!(matches!(error, HomeError::Network { .. }), "{error:?}");
    }

    #[tokio::test]
    async fn last_play_is_the_newest_valid_track_with_its_context() {
        let items = [
            play("spotify:track:bad id", Some(LIST)),
            play(T2, Some("spotify:user:me:collection")),
            play(T1, Some(ALBUM)),
        ];
        let body = format!(r#"{{"items":[{}]}}"#, items.join(","));
        let (base, _server) = fake_web_api(vec![("200 OK", body)]).await;
        assert_eq!(
            last_play_at(&base, "at").await.unwrap(),
            Some(LastPlay {
                track: T2.to_owned(),
                context: Some(crate::player::LIKED_SONGS.to_owned()),
                played_at_ms: 1_791_540_000_000,
            })
        );
        let undated = r#"{"items":[{"track":{"uri":"spotify:track:4uLU6hMCjMI75M1A2tKUQC"},"played_at":"yesterday"}]}"#;
        let (base, _server) = fake_web_api(vec![("200 OK", undated.to_owned())]).await;
        let play = last_play_at(&base, "at").await.unwrap().unwrap();
        assert_eq!(play.played_at_ms, i64::MIN);

        let (base, _server) = fake_web_api(vec![("200 OK", r#"{"items":[]}"#.to_owned())]).await;
        assert_eq!(last_play_at(&base, "at").await.unwrap(), None);
    }

    #[test]
    fn current_playback_of_no_session_is_none() {
        assert_eq!(current_playback_from(b"").unwrap(), None);
        assert_eq!(current_playback_from(b" \n").unwrap(), None);
    }

    #[test]
    fn current_playback_reads_playing_and_paused_state() {
        let body = |playing: bool, progress: i64| {
            format!(
                r#"{{"device":{{"id":"phone","name":"n"}},"is_playing":{playing},"progress_ms":{progress},"item":{{"uri":"{T1}","duration_ms":200000,"type":"track"}},"context":{{"uri":"{LIST}","type":"playlist"}},"currently_playing_type":"track"}}"#
            )
        };
        let read = |body: String| current_playback_from(body.as_bytes()).unwrap().unwrap();
        assert_eq!(
            read(body(true, 95_000)),
            CurrentPlayback {
                device_id: Some("phone".to_owned()),
                is_playing: true,
                item: Some(T1.to_owned()),
                context: Some(LIST.to_owned()),
                progress_ms: 95_000,
            }
        );
        let paused = read(body(false, 900_000));
        assert!(!paused.is_playing);
        assert_eq!(paused.progress_ms, 200_000, "clamped to the item");
        assert_eq!(read(body(false, -5)).progress_ms, 0);
    }

    #[test]
    fn current_playback_drops_invalid_uris_and_tolerates_missing_fields() {
        let body = format!(
            r#"{{"device":{{"id":null}},"item":{{"uri":"spotify:local:a:b:c:1"}},"context":{{"uri":"{T1}"}}}}"#
        );
        let playback = current_playback_from(body.as_bytes()).unwrap().unwrap();
        assert_eq!(
            playback,
            CurrentPlayback {
                device_id: None,
                is_playing: false,
                item: None,
                context: None,
                progress_ms: 0,
            }
        );
        let episode = r#"{"item":{"uri":"spotify:episode:4rOoJ6Egrf8K2IrywzwOMk"},"item_extra":1}"#;
        let item = current_playback_from(episode.as_bytes())
            .unwrap()
            .unwrap()
            .item;
        assert_eq!(
            item.as_deref(),
            Some("spotify:episode:4rOoJ6Egrf8K2IrywzwOMk")
        );
        let bad = r#"{"item":{"uri":"spotify:track:bad id"},"context":null}"#;
        assert_eq!(
            current_playback_from(bad.as_bytes()).unwrap().unwrap().item,
            None
        );
    }

    #[test]
    fn current_playback_malformed_json_is_malformed() {
        for body in ["<html>", r#"{"is_playing":"yes"}"#, "[]"] {
            let error = current_playback_from(body.as_bytes()).unwrap_err();
            assert!(matches!(error, HomeError::Malformed { .. }), "{body}");
        }
    }

    #[test]
    fn recent_contexts_dedupe_in_order_and_drop_unsupported() {
        let body = format!(
            r#"{{"playContexts":[
                {{"uri":"{LIST}","lastPlayedTime":3,"lastPlayedTrackUri":"{T1}"}},
                {{"uri":"{ALBUM}","lastPlayedTime":2}},
                {{"uri":"{LIST}","lastPlayedTime":1}},
                {{"uri":"spotify:user:me:collection"}},
                {{"uri":"spotify:collection"}},
                {{"uri":"{T2}"}},
                {{"uri":"garbage"}},
                {{"uri":"spotify:artist:0OdUWJ0sBjDrqHygGUXeCF"}}
            ],"extra":true}}"#
        );

        let contexts = recent_contexts(body.as_bytes()).unwrap();

        assert_eq!(
            contexts,
            [LIST, ALBUM, "spotify:artist:0OdUWJ0sBjDrqHygGUXeCF"]
        );
    }

    #[test]
    fn recent_contexts_without_the_field_are_empty() {
        assert!(recent_contexts(b"{}").unwrap().is_empty());
    }

    #[test]
    fn recent_contexts_malformed_json_is_malformed() {
        for body in ["not json", r#"{"playContexts":{}}"#] {
            let error = recent_contexts(body.as_bytes()).unwrap_err();
            assert!(matches!(error, HomeError::Malformed { .. }), "{body}");
        }
    }

    #[test]
    fn radio_playlist_is_the_first_playlist_item() {
        let body = format!(r#"{{"total":2,"mediaItems":[{{"uri":"{T1}"}},{{"uri":"{LIST}"}}]}}"#);
        assert_eq!(radio_playlist(body.as_bytes()).unwrap(), LIST);
    }

    #[test]
    fn radio_without_a_playlist_is_malformed() {
        for body in [
            r#"{"mediaItems":[]}"#,
            r#"{"mediaItems":[{"uri":"x"}]}"#,
            "{}",
        ] {
            let error = radio_playlist(body.as_bytes()).unwrap_err();
            assert!(matches!(error, HomeError::Malformed { .. }), "{body}");
        }
    }

    #[test]
    fn radio_seeds_are_tracks_or_artists() {
        let seed = |uri: &str| {
            SpotifyUri::from_uri(uri)
                .ok()
                .filter(is_radio_seed)
                .is_some()
        };
        assert!(seed(T1));
        assert!(seed("spotify:artist:0OdUWJ0sBjDrqHygGUXeCF"));
        assert!(!seed(ALBUM));
        assert!(!seed(LIST));
        assert!(!seed("not-a-uri"));
    }
}
