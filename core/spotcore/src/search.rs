//! Search through the Web API with a token from the user's own client ID.
//! spclient's searchview endpoint answers 400 for every request, and the shared
//! librespot client ID is rate limited on the Web API.

use std::sync::Arc;

use librespot_core::SpotifyUri;
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use serde::Deserialize;

use crate::account::{MAX_BODY_BYTES, read_capped, web_api_client};
use crate::metadata::{Artwork, ArtworkSize};

const SEARCH_URL: &str = "https://api.spotify.com/v1/search";
/// Development-mode apps get HTTP 400 above 10 results per type.
const MAX_LIMIT: u32 = 10;
/// The Web API refuses longer queries and offsets past 1000.
const MAX_QUERY_CHARS: usize = 250;
const MAX_OFFSET: u32 = 1000;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SearchError {
    /// The access token expired or was revoked.
    #[error("search was not authorized")]
    Unauthorized,
    /// The app is not allowed to call the Web API for this account, for
    /// example because the user is not on the app's allowlist.
    #[error("search was forbidden")]
    Forbidden,
    #[error("search was rate limited")]
    RateLimited,
    #[error("search request failed: {message}")]
    Request { message: String },
    #[error("malformed search response: {message}")]
    Malformed { message: String },
}

impl From<serde_json::Error> for SearchError {
    fn from(e: serde_json::Error) -> Self {
        Self::Malformed {
            message: e.to_string(),
        }
    }
}

/// Result groups in display order. Shows and episodes are the podcast groups.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SearchKind {
    Track,
    Artist,
    Album,
    Playlist,
    Show,
    Episode,
}

impl SearchKind {
    const ALL: [Self; 6] = [
        Self::Track,
        Self::Artist,
        Self::Album,
        Self::Playlist,
        Self::Show,
        Self::Episode,
    ];

    /// Value in the request's `type` filter.
    fn filter(self) -> &'static str {
        match self {
            Self::Track => "track",
            Self::Artist => "artist",
            Self::Album => "album",
            Self::Playlist => "playlist",
            Self::Show => "show",
            Self::Episode => "episode",
        }
    }

    /// Key of this group in the response object.
    fn key(self) -> &'static str {
        match self {
            Self::Track => "tracks",
            Self::Artist => "artists",
            Self::Album => "albums",
            Self::Playlist => "playlists",
            Self::Show => "shows",
            Self::Episode => "episodes",
        }
    }

    fn accepts(self, uri: &SpotifyUri) -> bool {
        matches!(
            (self, uri),
            (Self::Track, SpotifyUri::Track { .. })
                | (Self::Artist, SpotifyUri::Artist { .. })
                | (Self::Album, SpotifyUri::Album { .. })
                | (Self::Playlist, SpotifyUri::Playlist { .. })
                | (Self::Show, SpotifyUri::Show { .. })
                | (Self::Episode, SpotifyUri::Episode { .. })
        )
    }
}

/// `subtitle` is the artists, playlist owner or show publisher, comma-joined;
/// empty for artists and episodes.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchHit {
    pub uri: String,
    pub name: String,
    pub subtitle: String,
    pub artwork: Vec<Artwork>,
    pub explicit: bool,
}

/// `total` counts every match on the server, so `offset + hits.len() < total`
/// means "See all" has more pages.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchGroup {
    pub kind: SearchKind,
    pub total: u32,
    pub offset: u32,
    pub hits: Vec<SearchHit>,
    /// Where the next page starts: `offset` plus every item the server sent,
    /// also the ones dropped as null or unparseable, which `hits` omits.
    /// 0 from a caller that does not know it; then use `offset + hits.len()`.
    #[uniffi(default = 0)]
    pub next_offset: u32,
}

/// One per access token; the token needs no scope.
#[derive(uniffi::Object)]
pub struct SearchService {
    base: String,
    access_token: String,
}

#[uniffi::export(async_runtime = "tokio")]
impl SearchService {
    #[uniffi::constructor]
    pub fn new(access_token: String) -> Arc<Self> {
        Arc::new(Self::at(SEARCH_URL, access_token))
    }

    /// The first `limit` (at most 10) hits of every non-empty group. A blank
    /// query returns no groups without a request.
    pub async fn search(&self, query: String, limit: u32) -> Result<Vec<SearchGroup>, SearchError> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let body = self
            .get(&endpoint(&self.base, &query, &SearchKind::ALL, 0, limit))
            .await?;
        let mut groups = groups_of(&body, &SearchKind::ALL, 0)?;
        groups.retain(|group| !group.hits.is_empty());
        Ok(groups)
    }

    /// One "See all" page of a single group.
    pub async fn page(
        &self,
        query: String,
        kind: SearchKind,
        offset: u32,
        limit: u32,
    ) -> Result<SearchGroup, SearchError> {
        let empty = SearchGroup {
            kind,
            total: 0,
            offset,
            hits: Vec::new(),
            next_offset: offset,
        };
        if query.trim().is_empty() {
            return Ok(empty);
        }
        let body = self
            .get(&endpoint(&self.base, &query, &[kind], offset, limit))
            .await?;
        let groups = groups_of(&body, &[kind], offset)?;
        Ok(groups.into_iter().next().unwrap_or(empty))
    }
}

impl SearchService {
    fn at(base: &str, access_token: String) -> Self {
        Self {
            base: base.to_owned(),
            access_token,
        }
    }

    async fn get(&self, url: &str) -> Result<Vec<u8>, SearchError> {
        let http = web_api_client().map_err(network)?;
        let response = http
            .get(url)
            .bearer_auth(&self.access_token)
            .send()
            .await
            .map_err(network)?;
        if let Some(error) = status_error(response.status().as_u16()) {
            return Err(error);
        }
        read_capped(response, MAX_BODY_BYTES, network, || {
            SearchError::Malformed {
                message: "response too large".to_owned(),
            }
        })
        .await
    }
}

fn status_error(status: u16) -> Option<SearchError> {
    match status {
        200..=299 => None,
        401 => Some(SearchError::Unauthorized),
        403 => Some(SearchError::Forbidden),
        429 => Some(SearchError::RateLimited),
        status => Some(SearchError::Request {
            message: format!("HTTP {status}"),
        }),
    }
}

fn network(error: reqwest::Error) -> SearchError {
    SearchError::Request {
        message: error.without_url().to_string(),
    }
}

/// The query is percent-encoded since it lands in the query string.
fn endpoint(base: &str, query: &str, kinds: &[SearchKind], offset: u32, limit: u32) -> String {
    let types: Vec<&str> = kinds.iter().map(|k| k.filter()).collect();
    let clipped: String = query.trim().chars().take(MAX_QUERY_CHARS).collect();
    format!(
        "{base}?q={}&type={}&limit={}&offset={}",
        utf8_percent_encode(&clipped, NON_ALPHANUMERIC),
        types.join(","),
        limit.clamp(1, MAX_LIMIT),
        offset.min(MAX_OFFSET),
    )
}

#[derive(Deserialize)]
struct Group {
    /// Playlist results in particular can hold `null` entries.
    #[serde(default)]
    items: Vec<serde_json::Value>,
    #[serde(default)]
    total: u32,
}

#[derive(Deserialize)]
struct Item {
    uri: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    explicit: Option<bool>,
    #[serde(default)]
    artists: Option<Vec<Named>>,
    #[serde(default)]
    owner: Option<Owner>,
    #[serde(default)]
    publisher: Option<String>,
    #[serde(default)]
    images: Option<Vec<Image>>,
    #[serde(default)]
    album: Option<Album>,
}

#[derive(Deserialize)]
struct Named {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct Owner {
    #[serde(default)]
    display_name: Option<String>,
}

#[derive(Deserialize)]
struct Album {
    #[serde(default)]
    images: Option<Vec<Image>>,
}

#[derive(Deserialize)]
struct Image {
    url: String,
    #[serde(default)]
    width: Option<u32>,
    #[serde(default)]
    height: Option<u32>,
}

/// Groups for `kinds` in that order, skipping empty or absent ones. A group or
/// item that fails to parse is skipped rather than failing the whole search.
fn groups_of(
    body: &[u8],
    kinds: &[SearchKind],
    offset: u32,
) -> Result<Vec<SearchGroup>, SearchError> {
    let response: serde_json::Map<String, serde_json::Value> = serde_json::from_slice(body)?;
    Ok(kinds
        .iter()
        .filter_map(|&kind| {
            let group = Group::deserialize(response.get(kind.key())?).ok()?;
            let sent = u32::try_from(group.items.len()).unwrap_or(u32::MAX);
            let hits: Vec<SearchHit> = group
                .items
                .into_iter()
                .filter_map(|value| hit_of(kind, Item::deserialize(value).ok()?))
                .collect();
            (sent > 0).then_some(SearchGroup {
                kind,
                total: group
                    .total
                    .max(offset.saturating_add(u32::try_from(hits.len()).unwrap_or(u32::MAX))),
                offset,
                hits,
                next_offset: offset.saturating_add(sent),
            })
        })
        .collect())
}

/// Server text is untrusted: only URIs of the group's kind pass, canonicalized.
fn hit_of(kind: SearchKind, item: Item) -> Option<SearchHit> {
    let uri = SpotifyUri::from_uri(&item.uri)
        .ok()
        .filter(|uri| kind.accepts(uri))?
        .to_uri()
        .ok()?;
    let artists: Vec<String> = item
        .artists
        .unwrap_or_default()
        .into_iter()
        .filter_map(|a| a.name)
        .collect();
    let subtitle = if !artists.is_empty() {
        artists.join(", ")
    } else {
        item.owner
            .and_then(|o| o.display_name)
            .or(item.publisher)
            .unwrap_or_default()
    };
    let images = item
        .images
        .or_else(|| item.album.and_then(|a| a.images))
        .unwrap_or_default();
    Some(SearchHit {
        uri,
        name: item.name.unwrap_or_default(),
        subtitle,
        artwork: artwork(images),
        explicit: item.explicit.unwrap_or(false),
    })
}

/// Only `https` images, smallest first like every other artwork list.
fn artwork(images: Vec<Image>) -> Vec<Artwork> {
    let mut artwork: Vec<Artwork> = images
        .into_iter()
        .filter(|i| crate::util::is_artwork_url(&i.url))
        .map(|i| Artwork {
            url: i.url,
            size: ArtworkSize::Default,
            width: i.width.unwrap_or(0),
            height: i.height.unwrap_or(0),
        })
        .collect();
    artwork.sort_by_key(|a| a.width);
    artwork
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account::fake_web_api;

    const TRACK: &str = "spotify:track:4rOoJ6Egrf8K2IrywzwOMk";
    const ARTIST: &str = "spotify:artist:0OdUWJ0sBjDrqHygGUXeCF";
    const PLAYLIST: &str = "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M";
    const SHOW: &str = "spotify:show:5CfCWKI5pZ28U0uOzXkDHe";
    const EPISODE: &str = "spotify:episode:512ojhOuo1ktJprKbVcKyQ";

    fn body() -> String {
        format!(
            r#"{{
          "tracks": {{"total": 412, "limit": 10, "offset": 0, "items": [
            {{"uri": "{TRACK}", "name": "Song", "explicit": true,
             "artists": [{{"name": "One"}}, {{"name": "Two"}}],
             "album": {{"images": [
               {{"url": "https://i.scdn.co/image/big", "width": 640, "height": 640}},
               {{"url": "https://i.scdn.co/image/small", "width": 64, "height": 64}}
             ]}}}},
            {{"uri": "{ARTIST}", "name": "wrong kind in tracks"}},
            {{"uri": "", "name": "no uri"}}
          ]}},
          "artists": {{"total": 3, "items": [
            {{"uri": "{ARTIST}", "name": "Band", "images": [{{"url": "http://insecure", "width": 1, "height": 1}}]}}
          ]}},
          "albums": "not an object",
          "playlists": {{"total": 9, "items": [
            null,
            {{"uri": "{PLAYLIST}", "name": "Mix", "owner": {{"display_name": "someone"}}, "images": null}}
          ]}},
          "shows": {{"total": 1, "items": [
            {{"uri": "{SHOW}", "name": "Pod", "publisher": "Studio", "explicit": false,
             "images": [{{"url": "javascript:x"}}]}}
          ]}},
          "episodes": {{"total": 2, "items": [
            {{"uri": "{EPISODE}", "name": "Ep", "explicit": null,
             "images": [{{"url": "https://i.scdn.co/image/ep", "width": null, "height": null}}]}}
          ]}}
        }}"#
        )
    }

    #[test]
    fn dropped_hits_still_advance_the_next_page() {
        let body = format!(
            r#"{{"playlists": {{"total": 90, "items": [null, null, {{"uri": "{PLAYLIST}", "name": "Mix"}}]}}}}"#
        );
        let groups = groups_of(body.as_bytes(), &[SearchKind::Playlist], 20).unwrap();
        assert_eq!((groups[0].hits.len(), groups[0].next_offset), (1, 23));

        let all_null = br#"{"playlists": {"total": 90, "items": [null, null]}}"#;
        let groups = groups_of(all_null, &[SearchKind::Playlist], 20).unwrap();
        assert_eq!((groups[0].hits.len(), groups[0].next_offset), (0, 22));
    }

    #[test]
    fn long_queries_and_deep_offsets_are_clamped() {
        let query = "a".repeat(400);
        let url = endpoint("https://x", &query, &[SearchKind::Track], 5000, 10);
        assert!(url.contains(&format!("q={}&", "a".repeat(250))));
        assert!(url.ends_with("&offset=1000"));
    }

    #[test]
    fn groups_follow_display_order_and_skip_empty_or_broken_ones() {
        let groups = groups_of(body().as_bytes(), &SearchKind::ALL, 0).unwrap();
        let kinds: Vec<SearchKind> = groups.iter().map(|g| g.kind).collect();
        assert_eq!(
            kinds,
            [
                SearchKind::Track,
                SearchKind::Artist,
                SearchKind::Playlist,
                SearchKind::Show,
                SearchKind::Episode
            ]
        );
        assert_eq!(groups[0].total, 412);
        assert_eq!(
            groups[0].hits.len(),
            1,
            "hits of another kind or without a URI are dropped"
        );
        assert_eq!(groups[2].hits.len(), 1, "null playlist items are skipped");
    }

    #[test]
    fn hits_carry_subtitle_artwork_and_explicit() {
        let groups = groups_of(body().as_bytes(), &SearchKind::ALL, 0).unwrap();
        let track = &groups[0].hits[0];
        assert_eq!(track.uri, TRACK);
        assert_eq!(track.name, "Song");
        assert_eq!(track.subtitle, "One, Two");
        assert!(track.explicit);
        let urls: Vec<&str> = track.artwork.iter().map(|a| a.url.as_str()).collect();
        assert_eq!(
            urls,
            [
                "https://i.scdn.co/image/small",
                "https://i.scdn.co/image/big"
            ],
            "album art, smallest first"
        );
        assert_eq!(track.artwork[0].width, 64);

        let artist = &groups[1].hits[0];
        assert_eq!(artist.subtitle, "");
        assert!(artist.artwork.is_empty(), "non-https images are dropped");

        let playlist = &groups[2].hits[0];
        assert_eq!(playlist.subtitle, "someone");
        assert!(playlist.artwork.is_empty());

        let show = &groups[3].hits[0];
        assert_eq!(show.subtitle, "Studio");
        assert!(show.artwork.is_empty());

        let episode = &groups[4].hits[0];
        assert!(!episode.explicit);
        assert_eq!(episode.artwork[0].width, 0);
    }

    #[test]
    fn page_keeps_offset_and_total_covers_received_hits() {
        let body = format!(r#"{{"tracks": {{"total": 0, "items": [{{"uri": "{TRACK}"}}]}}}}"#);
        let groups = groups_of(body.as_bytes(), &[SearchKind::Track], 50).unwrap();
        assert_eq!(groups[0].offset, 50);
        assert_eq!(groups[0].total, 51);
    }

    #[test]
    fn total_saturates_at_the_largest_offset() {
        let body = format!(r#"{{"tracks": {{"total": 0, "items": [{{"uri": "{TRACK}"}}]}}}}"#);
        let groups = groups_of(body.as_bytes(), &[SearchKind::Track], u32::MAX).unwrap();
        assert_eq!(groups[0].total, u32::MAX);
    }

    #[test]
    fn malformed_body_is_a_typed_error() {
        let err = groups_of(b"<html>", &SearchKind::ALL, 0).unwrap_err();
        assert!(matches!(err, SearchError::Malformed { .. }));
    }

    #[test]
    fn endpoint_encodes_query_lists_types_and_clamps_limit() {
        assert_eq!(
            endpoint(SEARCH_URL, " a&b/ ", &SearchKind::ALL, 0, 20),
            "https://api.spotify.com/v1/search?q=a%26b%2F&type=track,artist,album,playlist,show,episode&limit=10&offset=0"
        );
        assert_eq!(
            endpoint("http://x", "q", &[SearchKind::Show], 30, 0),
            "http://x?q=q&type=show&limit=1&offset=30"
        );
    }

    #[test]
    fn statuses_map_to_typed_errors() {
        assert!(status_error(200).is_none());
        assert!(matches!(status_error(401), Some(SearchError::Unauthorized)));
        assert!(matches!(status_error(403), Some(SearchError::Forbidden)));
        assert!(matches!(status_error(429), Some(SearchError::RateLimited)));
        assert!(matches!(
            status_error(400),
            Some(SearchError::Request { message }) if message == "HTTP 400"
        ));
    }

    #[tokio::test]
    async fn search_sends_the_bearer_token_and_maps_the_response() {
        let (base, server) = fake_web_api(vec![("200 OK", body())]).await;
        let service = SearchService::at(&base, "at-1".to_owned());

        let groups = service.search("abba".to_owned(), 5).await.unwrap();

        assert_eq!(groups.len(), 5);
        let head = server.await.unwrap().remove(0).to_lowercase();
        assert!(head.starts_with("get /?q=abba&type=track,"), "{head}");
        assert!(head.contains("&limit=5&offset=0 "), "{head}");
        assert!(head.contains("authorization: bearer at-1"), "{head}");
    }

    #[tokio::test]
    async fn page_requests_one_type_and_rate_limit_is_typed() {
        let (base, server) = fake_web_api(vec![
            (
                "200 OK",
                format!(r#"{{"shows": {{"total": 12, "items": [{{"uri": "{SHOW}"}}]}}}}"#),
            ),
            ("429 Too Many Requests", "{}".to_owned()),
        ])
        .await;
        let service = SearchService::at(&base, "at".to_owned());

        let page = service
            .page("pod".to_owned(), SearchKind::Show, 10, 10)
            .await
            .unwrap();
        let error = service.search("pod".to_owned(), 10).await.unwrap_err();

        assert_eq!((page.offset, page.total, page.hits.len()), (10, 12, 1));
        assert!(matches!(error, SearchError::RateLimited), "{error:?}");
        let heads = server.await.unwrap();
        assert!(
            heads[0].starts_with("GET /?q=pod&type=show&limit=10&offset=10 "),
            "{}",
            heads[0]
        );
    }

    #[tokio::test]
    async fn blank_query_makes_no_request() {
        let service = SearchService::at("http://127.0.0.1:1", "at".to_owned());
        assert!(
            service
                .search("  ".to_owned(), 10)
                .await
                .unwrap()
                .is_empty()
        );
        let page = service
            .page(" ".to_owned(), SearchKind::Track, 0, 10)
            .await
            .unwrap();
        assert!(page.hits.is_empty());
    }
}
