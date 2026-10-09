//! Search through spclient's internal searchview endpoint, which unlike the
//! Web API does not cap development-mode results at 10 per type.

use std::sync::Arc;

use http::Method;
use librespot_core::Session;
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use serde::Deserialize;

use crate::metadata::{Artwork, ArtworkSize, image_url_template};
use crate::session::SpotSession;

const IMAGE_PREFIX: &str = "spotify:image:";

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SearchError {
    #[error("search request failed: {message}")]
    Request { message: String },
    #[error("malformed search response: {message}")]
    Malformed { message: String },
}

impl From<librespot_core::Error> for SearchError {
    fn from(e: librespot_core::Error) -> Self {
        Self::Request {
            message: e.to_string(),
        }
    }
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

    /// Key of this group in the response's `results` object and `types` filter.
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
}

/// `subtitle` is the artists, album artists, playlist author or show
/// publisher, comma-joined; empty for artists.
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
}

#[derive(uniffi::Object)]
pub struct SearchService {
    session: Arc<SpotSession>,
}

#[uniffi::export(async_runtime = "tokio")]
impl SearchService {
    #[uniffi::constructor]
    pub fn new(session: Arc<SpotSession>) -> Arc<Self> {
        Arc::new(Self { session })
    }

    /// The first `limit` hits of every non-empty group. A blank query returns
    /// no groups without a request.
    pub async fn search(&self, query: String, limit: u32) -> Result<Vec<SearchGroup>, SearchError> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let session = self.session.current_session();
        let body = get(
            &session,
            &endpoint(
                &query,
                &session.country(),
                &session.username(),
                None,
                0,
                limit,
            ),
        )
        .await?;
        groups_of(&body, &SearchKind::ALL, 0, &image_url_template(&session))
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
        };
        if query.trim().is_empty() {
            return Ok(empty);
        }
        let session = self.session.current_session();
        let endpoint = endpoint(
            &query,
            &session.country(),
            &session.username(),
            Some(kind),
            offset,
            limit,
        );
        let body = get(&session, &endpoint).await?;
        let groups = groups_of(&body, &[kind], offset, &image_url_template(&session))?;
        Ok(groups.into_iter().next().unwrap_or(empty))
    }
}

async fn get(session: &Session, endpoint: &str) -> Result<Vec<u8>, SearchError> {
    let response = session
        .spclient()
        .request_as_json(&Method::GET, endpoint, None, None)
        .await?;
    Ok(response.to_vec())
}

/// Every caller-supplied part is percent-encoded since it lands in the path
/// or query string.
fn endpoint(
    query: &str,
    country: &str,
    username: &str,
    kind: Option<SearchKind>,
    offset: u32,
    limit: u32,
) -> String {
    let encode = |s: &str| utf8_percent_encode(s, NON_ALPHANUMERIC).to_string();
    let mut url = format!(
        "/searchview/km/v4/search/{}?entityVersion=2&catalogue=&country={}&locale=en&username={}&offset={offset}&limit={limit}",
        encode(query.trim()),
        encode(country),
        encode(username),
    );
    if let Some(kind) = kind {
        url.push_str("&types=");
        url.push_str(kind.key());
    }
    url
}

#[derive(Deserialize)]
struct Response {
    #[serde(default)]
    results: serde_json::Map<String, serde_json::Value>,
}

#[derive(Deserialize)]
struct Group {
    #[serde(default)]
    hits: Vec<Hit>,
    #[serde(default)]
    total: u32,
}

#[derive(Deserialize)]
struct Hit {
    uri: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    image: String,
    #[serde(default)]
    explicit: bool,
    #[serde(default)]
    artists: Vec<Named>,
    #[serde(default)]
    author: Option<Named>,
    #[serde(default)]
    publisher: Option<String>,
    #[serde(default, rename = "showName")]
    show_name: Option<String>,
}

#[derive(Deserialize)]
struct Named {
    #[serde(default)]
    name: String,
}

/// Groups for `kinds` in that order, skipping empty or absent ones. A group
/// that fails to parse is skipped rather than failing the whole search.
fn groups_of(
    body: &[u8],
    kinds: &[SearchKind],
    offset: u32,
    image_url: &str,
) -> Result<Vec<SearchGroup>, SearchError> {
    let response: Response = serde_json::from_slice(body)?;
    Ok(kinds
        .iter()
        .filter_map(|&kind| {
            let value = response.results.get(kind.key())?;
            let group = Group::deserialize(value).ok()?;
            let hits: Vec<SearchHit> = group
                .hits
                .into_iter()
                .filter(|h| !h.uri.is_empty())
                .map(|h| hit_of(h, image_url))
                .collect();
            (!hits.is_empty()).then_some(SearchGroup {
                kind,
                total: group.total.max(offset + hits.len() as u32),
                offset,
                hits,
            })
        })
        .collect())
}

fn hit_of(hit: Hit, image_url: &str) -> SearchHit {
    let subtitle = if !hit.artists.is_empty() {
        let names: Vec<&str> = hit.artists.iter().map(|a| a.name.as_str()).collect();
        names.join(", ")
    } else {
        hit.author
            .map(|a| a.name)
            .or(hit.publisher)
            .or(hit.show_name)
            .unwrap_or_default()
    };
    SearchHit {
        uri: hit.uri,
        name: hit.name,
        subtitle,
        artwork: artwork(&hit.image, image_url),
        explicit: hit.explicit,
    }
}

/// Images arrive either as full URLs or as `spotify:image:<file id>`.
fn artwork(image: &str, image_url: &str) -> Vec<Artwork> {
    let url = match image.strip_prefix(IMAGE_PREFIX) {
        Some(id) if !id.is_empty() && id.bytes().all(|b| b.is_ascii_hexdigit()) => {
            image_url.replace("{file_id}", id)
        }
        Some(_) => return Vec::new(),
        None if image.starts_with("https://") => image.to_owned(),
        None => return Vec::new(),
    };
    vec![Artwork {
        url,
        size: ArtworkSize::Default,
        width: 0,
        height: 0,
    }]
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEMPLATE: &str = "https://i.scdn.co/image/{file_id}";

    const BODY: &str = r#"{
      "results": {
        "tracks": {"total": 412, "hits": [
          {"uri": "spotify:track:a", "name": "Song", "image": "https://i.scdn.co/image/ab67",
           "explicit": true, "artists": [{"name": "One"}, {"name": "Two"}]},
          {"uri": "", "name": "no uri"}
        ]},
        "artists": {"total": 3, "hits": [
          {"uri": "spotify:artist:b", "name": "Band", "image": "spotify:image:ab12cd"}
        ]},
        "playlists": {"total": 9, "hits": [
          {"uri": "spotify:playlist:c", "name": "Mix", "author": {"name": "someone"}}
        ]},
        "shows": {"total": 1, "hits": [
          {"uri": "spotify:show:d", "name": "Pod", "publisher": "Studio", "image": "javascript:x"}
        ]},
        "episodes": {"total": 0, "hits": []},
        "albums": "not an object",
        "genres": {"total": 1, "hits": [{"uri": "spotify:genre:x"}]}
      }
    }"#;

    #[test]
    fn groups_follow_display_order_and_skip_empty_or_broken_ones() {
        let groups = groups_of(BODY.as_bytes(), &SearchKind::ALL, 0, TEMPLATE).unwrap();
        let kinds: Vec<SearchKind> = groups.iter().map(|g| g.kind).collect();
        assert_eq!(
            kinds,
            [
                SearchKind::Track,
                SearchKind::Artist,
                SearchKind::Playlist,
                SearchKind::Show
            ]
        );
        assert_eq!(groups[0].total, 412);
        assert_eq!(groups[0].hits.len(), 1, "hits without a URI are dropped");
    }

    #[test]
    fn hits_carry_subtitle_artwork_and_explicit() {
        let groups = groups_of(BODY.as_bytes(), &SearchKind::ALL, 0, TEMPLATE).unwrap();
        let track = &groups[0].hits[0];
        assert_eq!(track.subtitle, "One, Two");
        assert!(track.explicit);
        assert_eq!(track.artwork[0].url, "https://i.scdn.co/image/ab67");
        assert_eq!(groups[1].hits[0].subtitle, "");
        assert_eq!(
            groups[1].hits[0].artwork[0].url,
            "https://i.scdn.co/image/ab12cd"
        );
        assert_eq!(groups[2].hits[0].subtitle, "someone");
        assert_eq!(groups[3].hits[0].subtitle, "Studio");
        assert!(
            groups[3].hits[0].artwork.is_empty(),
            "non-https images are dropped"
        );
    }

    #[test]
    fn page_keeps_offset_and_total_covers_received_hits() {
        let body = r#"{"results": {"tracks": {"hits": [{"uri": "spotify:track:a"}]}}}"#;
        let groups = groups_of(body.as_bytes(), &[SearchKind::Track], 50, TEMPLATE).unwrap();
        assert_eq!(groups[0].offset, 50);
        assert_eq!(groups[0].total, 51);
    }

    #[test]
    fn malformed_body_is_a_typed_error() {
        let err = groups_of(b"<html>", &SearchKind::ALL, 0, TEMPLATE).unwrap_err();
        assert!(matches!(err, SearchError::Malformed { .. }));
    }

    #[test]
    fn endpoint_encodes_query_and_filters_one_type() {
        let url = endpoint(" a/b?c#d é ", "PL", "u&x", Some(SearchKind::Show), 20, 50);
        assert_eq!(
            url,
            "/searchview/km/v4/search/a%2Fb%3Fc%23d%20%C3%A9?entityVersion=2&catalogue=&country=PL&locale=en&username=u%26x&offset=20&limit=50&types=shows"
        );
    }

    #[test]
    fn image_ids_must_be_hex() {
        assert!(artwork("spotify:image:../../x", TEMPLATE).is_empty());
        assert!(artwork("", TEMPLATE).is_empty());
    }
}
