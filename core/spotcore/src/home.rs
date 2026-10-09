//! Home page sources: recently played from the Web API (librespot has no
//! endpoint for it) and track or artist radio through spclient.

use std::sync::Arc;

use librespot_core::SpotifyUri;
use serde::Deserialize;

use crate::account::web_api_client;
use crate::session::SpotSession;

const RECENTLY_PLAYED_URL: &str = "https://api.spotify.com/v1/me/player/recently-played";
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
    let http = web_api_client().map_err(network)?;
    let response = http
        .get(format!("{url}?limit={RECENTLY_PLAYED_LIMIT}"))
        .bearer_auth(access_token)
        .send()
        .await
        .map_err(network)?;
    match response.status().as_u16() {
        200..=299 => {}
        403 => return Err(HomeError::MissingScope),
        status => return Err(HomeError::Request { status }),
    }
    let body = response.bytes().await.map_err(network)?;
    let history: History = serde_json::from_slice(&body)?;
    Ok(distinct_plays(history.items))
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
            play.context.and_then(|c| canonical(&c.uri, is_context)),
        );
    }
    recent
}

fn push_new(list: &mut Vec<String>, uri: Option<String>) {
    if let Some(uri) = uri.filter(|uri| !list.contains(uri)) {
        list.push(uri);
    }
}

fn canonical(uri: &str, accept: fn(&SpotifyUri) -> bool) -> Option<String> {
    let parsed = SpotifyUri::from_uri(uri).ok().filter(accept)?;
    parsed.to_uri().ok()
}

fn is_track(uri: &SpotifyUri) -> bool {
    matches!(uri, SpotifyUri::Track { .. })
}

fn is_context(uri: &SpotifyUri) -> bool {
    matches!(
        uri,
        SpotifyUri::Album { .. }
            | SpotifyUri::Artist { .. }
            | SpotifyUri::Playlist { .. }
            | SpotifyUri::Show { .. }
    )
}

fn is_radio_seed(uri: &SpotifyUri) -> bool {
    matches!(uri, SpotifyUri::Track { .. } | SpotifyUri::Artist { .. })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Radio {
    media_items: Vec<UriOnly>,
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
