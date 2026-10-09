//! Typed metadata for tracks, albums, artists, episodes and shows, fetched in
//! batches through extended metadata and cached for the service's lifetime.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use indexmap::IndexMap;
use librespot_core::date::Date;
use librespot_core::session::UserData;
use librespot_core::{Session, SpotifyUri};
use librespot_metadata::availability::Availabilities;
use librespot_metadata::image::{ImageSize, Images};
use librespot_metadata::restriction::Restrictions;
use librespot_metadata::{Album, Artist, Episode, Metadata, Show, Track};
use librespot_protocol::extended_metadata::{
    BatchedEntityRequest, BatchedExtensionResponse, EntityRequest, ExtensionQuery,
};
use librespot_protocol::extension_kind::ExtensionKind;
use protobuf::{EnumOrUnknown, Message};

use crate::session::SpotSession;

const BATCH_SIZE: usize = 100;
const CACHE_CAPACITY: usize = 5_000;
const DEFAULT_IMAGE_URL: &str = "https://i.scdn.co/image/{file_id}";

/// Failures of a whole `items` call. Per-item failures are `ItemError`.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum MetadataError {
    #[error("invalid Spotify URI: {message}")]
    InvalidUri { message: String },
    #[error("no metadata for this kind of item: {uri}")]
    UnsupportedKind { uri: String },
    #[error("metadata request failed: {message}")]
    Request { message: String },
}

/// Why one requested item has no metadata.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ItemError {
    NotFound,
    Malformed,
    /// HTTP-like status from Spotify; 0 when the item was missing from the reply.
    Failed {
        status: i32,
    },
}

/// Whether the signed-in account may play the item in its country now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Playability {
    Playable,
    RegionLocked,
    NotYetReleased,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ArtworkSize {
    Small,
    Default,
    Large,
    XLarge,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Artwork {
    pub url: String,
    pub size: ArtworkSize,
    /// 0 when Spotify does not report it; fall back to `size`.
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ItemRef {
    pub uri: String,
    pub name: String,
}

/// Artwork lists run smallest first.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TrackMetadata {
    pub uri: String,
    pub title: String,
    pub artists: Vec<ItemRef>,
    pub album: ItemRef,
    pub duration_ms: u32,
    pub explicit: bool,
    pub playability: Playability,
    pub artwork: Vec<Artwork>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AlbumMetadata {
    pub uri: String,
    pub title: String,
    pub artists: Vec<ItemRef>,
    pub tracks: Vec<String>,
    pub playability: Playability,
    pub artwork: Vec<Artwork>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArtistMetadata {
    pub uri: String,
    pub name: String,
    pub artwork: Vec<Artwork>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EpisodeMetadata {
    pub uri: String,
    pub title: String,
    pub show_name: String,
    pub description: String,
    pub duration_ms: u32,
    pub explicit: bool,
    pub playability: Playability,
    pub artwork: Vec<Artwork>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShowMetadata {
    pub uri: String,
    pub name: String,
    pub publisher: String,
    pub description: String,
    pub artwork: Vec<Artwork>,
    /// Episode URIs in server order.
    pub episodes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MetadataItem {
    Track { track: TrackMetadata },
    Album { album: AlbumMetadata },
    Artist { artist: ArtistMetadata },
    Episode { episode: EpisodeMetadata },
    Show { show: ShowMetadata },
    Unavailable { uri: String, error: ItemError },
}

#[derive(uniffi::Object)]
pub struct MetadataService {
    session: Arc<SpotSession>,
    cache: Mutex<Lru>,
}

#[uniffi::export(async_runtime = "tokio")]
impl MetadataService {
    #[uniffi::constructor]
    pub fn new(session: Arc<SpotSession>) -> Arc<Self> {
        Arc::new(Self {
            session,
            cache: Mutex::new(Lru::new(CACHE_CAPACITY)),
        })
    }

    /// One entry per URI, in input order. Cached items cost no request; the
    /// rest go out in batches of up to 100. Failed items are not cached.
    pub async fn items(&self, uris: Vec<String>) -> Result<Vec<MetadataItem>, MetadataError> {
        let requested = uris
            .iter()
            .map(|uri| Requested::parse(uri))
            .collect::<Result<Vec<_>, _>>()?;

        let mut found = HashMap::new();
        let mut missing = Vec::new();
        {
            let mut cache = self.cache.lock().unwrap();
            let mut seen = HashSet::new();
            for item in requested.iter().filter(|i| seen.insert(i.key.as_str())) {
                match cache.get(&item.key) {
                    Some(hit) => {
                        found.insert(item.key.clone(), hit);
                    }
                    None => missing.push(item.clone()),
                }
            }
        }

        for batch in missing.chunks(BATCH_SIZE) {
            let session = self.session.current_session();
            let response = session
                .spclient()
                .get_extended_metadata(request(batch))
                .await
                .map_err(|e| MetadataError::Request {
                    message: e.to_string(),
                })?;
            let decoded = decode(&response, batch, &Context::of(&session));
            let mut cache = self.cache.lock().unwrap();
            for (key, item) in decoded {
                if !matches!(item, MetadataItem::Unavailable { .. }) {
                    cache.insert(key.clone(), item.clone());
                }
                found.insert(key, item);
            }
        }

        Ok(requested
            .into_iter()
            .map(|item| found[&item.key].clone())
            .collect())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Track,
    Album,
    Artist,
    Episode,
    Show,
}

#[derive(Debug, Clone)]
struct Requested {
    key: String,
    uri: SpotifyUri,
    kind: Kind,
}

impl Requested {
    fn parse(raw: &str) -> Result<Self, MetadataError> {
        let invalid = |e: librespot_core::Error| MetadataError::InvalidUri {
            message: e.to_string(),
        };
        let uri = SpotifyUri::from_uri(raw).map_err(invalid)?;
        let kind = match uri {
            SpotifyUri::Track { .. } => Kind::Track,
            SpotifyUri::Album { .. } => Kind::Album,
            SpotifyUri::Artist { .. } => Kind::Artist,
            SpotifyUri::Episode { .. } => Kind::Episode,
            SpotifyUri::Show { .. } => Kind::Show,
            _ => {
                return Err(MetadataError::UnsupportedKind {
                    uri: raw.to_owned(),
                });
            }
        };
        let key = uri.to_uri().map_err(invalid)?;
        Ok(Self { key, uri, kind })
    }

    fn extension(&self) -> ExtensionKind {
        match self.kind {
            Kind::Track => ExtensionKind::TRACK_V4,
            Kind::Album => ExtensionKind::ALBUM_V4,
            Kind::Artist => ExtensionKind::ARTIST_V4,
            Kind::Episode => ExtensionKind::EPISODE_V4,
            Kind::Show => ExtensionKind::SHOW_V4,
        }
    }
}

fn request(batch: &[Requested]) -> BatchedEntityRequest {
    BatchedEntityRequest {
        entity_request: batch
            .iter()
            .map(|item| EntityRequest {
                entity_uri: item.key.clone(),
                query: vec![ExtensionQuery {
                    extension_kind: EnumOrUnknown::new(item.extension()),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .collect(),
        ..Default::default()
    }
}

/// Returns an entry for every item in `batch`, keyed by canonical URI.
fn decode(
    response: &BatchedExtensionResponse,
    batch: &[Requested],
    context: &Context,
) -> HashMap<String, MetadataItem> {
    let replies: HashMap<&str, _> = response
        .extended_metadata
        .iter()
        .flat_map(|array| &array.extension_data)
        .map(|data| (data.entity_uri.as_str(), data))
        .collect();

    batch
        .iter()
        .map(|item| {
            let unavailable = |error| MetadataItem::Unavailable {
                uri: item.key.clone(),
                error,
            };
            let decoded = match replies.get(item.key.as_str()) {
                None => unavailable(ItemError::Failed { status: 0 }),
                Some(data) => match (data.header.status_code, data.extension_data.as_ref()) {
                    (0 | 200, Some(any)) => context
                        .item(item, &any.value)
                        .unwrap_or_else(|_| unavailable(ItemError::Malformed)),
                    (404, _) => unavailable(ItemError::NotFound),
                    (status, _) => unavailable(ItemError::Failed { status }),
                },
            };
            (item.key.clone(), decoded)
        })
        .collect()
}

fn parse<T: Metadata>(uri: &SpotifyUri, bytes: &[u8]) -> Result<T, librespot_core::Error> {
    T::parse(&T::Message::parse_from_bytes(bytes)?, uri)
}

/// Image URL with a `{file_id}` placeholder, as the account reports it.
pub(crate) fn image_url_template(session: &Session) -> String {
    session
        .get_user_attribute("image-url")
        .unwrap_or_else(|| DEFAULT_IMAGE_URL.to_owned())
}

struct Context {
    user: UserData,
    image_url: String,
}

impl Context {
    fn of(session: &Session) -> Self {
        Self {
            user: session.user_data(),
            image_url: image_url_template(session),
        }
    }

    fn item(&self, item: &Requested, bytes: &[u8]) -> Result<MetadataItem, librespot_core::Error> {
        let uri = item.key.clone();
        Ok(match item.kind {
            Kind::Track => {
                let track: Track = parse(&item.uri, bytes)?;
                let playability = if Date::now_utc() < track.earliest_live_timestamp {
                    Playability::NotYetReleased
                } else {
                    self.playability(&track.availability, &track.restrictions)
                };
                MetadataItem::Track {
                    track: TrackMetadata {
                        uri,
                        title: track.name,
                        artists: track
                            .artists
                            .iter()
                            .map(|a| item_ref(&a.id, &a.name))
                            .collect(),
                        album: item_ref(&track.album.id, &track.album.name),
                        duration_ms: track.duration.max(0) as u32,
                        explicit: track.is_explicit,
                        playability,
                        artwork: self.artwork(&track.album.covers),
                    },
                }
            }
            Kind::Album => {
                let album: Album = parse(&item.uri, bytes)?;
                MetadataItem::Album {
                    album: AlbumMetadata {
                        uri,
                        artists: album
                            .artists
                            .iter()
                            .map(|a| item_ref(&a.id, &a.name))
                            .collect(),
                        tracks: album.tracks().filter_map(|t| t.to_uri().ok()).collect(),
                        playability: self.playability(&album.availability, &album.restrictions),
                        artwork: self.artwork(&album.covers),
                        title: album.name,
                    },
                }
            }
            Kind::Artist => {
                let artist: Artist = parse(&item.uri, bytes)?;
                let portraits = if artist.portrait_group.is_empty() {
                    &artist.portraits
                } else {
                    &artist.portrait_group
                };
                MetadataItem::Artist {
                    artist: ArtistMetadata {
                        uri,
                        artwork: self.artwork(portraits),
                        name: artist.name,
                    },
                }
            }
            Kind::Episode => {
                let episode: Episode = parse(&item.uri, bytes)?;
                MetadataItem::Episode {
                    episode: EpisodeMetadata {
                        uri,
                        duration_ms: episode.duration.max(0) as u32,
                        explicit: episode.is_explicit,
                        playability: self.playability(&episode.availability, &episode.restrictions),
                        artwork: self.artwork(&episode.covers),
                        title: episode.name,
                        show_name: episode.show_name,
                        description: episode.description,
                    },
                }
            }
            Kind::Show => {
                let show: Show = parse(&item.uri, bytes)?;
                MetadataItem::Show {
                    show: ShowMetadata {
                        uri,
                        artwork: self.artwork(&show.covers),
                        episodes: show
                            .episodes
                            .iter()
                            .filter_map(|e| e.to_uri().ok())
                            .collect(),
                        name: show.name,
                        publisher: show.publisher,
                        description: show.description,
                    },
                }
            }
        })
    }

    /// Mirrors librespot's private `available_for_user`, which decides what
    /// the player refuses, so the UI greys out exactly those items.
    fn playability(
        &self,
        availability: &Availabilities,
        restrictions: &Restrictions,
    ) -> Playability {
        let now = Date::now_utc();
        if !availability.is_empty() && !availability.iter().any(|a| now >= a.start) {
            return Playability::NotYetReleased;
        }
        let catalogue = self
            .user
            .attributes
            .get("catalogue")
            .map_or("premium", String::as_str);
        let country = &self.user.country;
        let applicable = restrictions.iter().find(|r| {
            r.catalogue_strs.iter().any(|c| c == catalogue)
                && (r.countries_allowed.is_some() || r.countries_forbidden.is_some())
        });
        let locked =
            applicable.is_some_and(|r| match (&r.countries_allowed, &r.countries_forbidden) {
                (Some(allowed), _) => !allowed.contains(country),
                (None, Some(forbidden)) => forbidden.contains(country),
                (None, None) => false,
            });
        if locked {
            Playability::RegionLocked
        } else {
            Playability::Playable
        }
    }

    fn artwork(&self, images: &Images) -> Vec<Artwork> {
        let mut artwork: Vec<Artwork> = images
            .iter()
            .map(|image| (image.id.to_string(), image))
            .filter(|(id, _)| !id.is_empty())
            .map(|(id, image)| Artwork {
                url: self.image_url.replace("{file_id}", &id),
                size: match image.size {
                    ImageSize::SMALL => ArtworkSize::Small,
                    ImageSize::DEFAULT => ArtworkSize::Default,
                    ImageSize::LARGE => ArtworkSize::Large,
                    ImageSize::XLARGE => ArtworkSize::XLarge,
                },
                width: image.width.max(0) as u32,
                height: image.height.max(0) as u32,
            })
            .collect();
        artwork.sort_by_key(|a| (a.width, size_rank(a.size)));
        artwork
    }
}

fn size_rank(size: ArtworkSize) -> u8 {
    match size {
        ArtworkSize::Small => 0,
        ArtworkSize::Default => 1,
        ArtworkSize::Large => 2,
        ArtworkSize::XLarge => 3,
    }
}

fn item_ref(id: &SpotifyUri, name: &str) -> ItemRef {
    ItemRef {
        uri: id.to_uri().unwrap_or_default(),
        name: name.to_owned(),
    }
}

/// Least recently used entries go first once `capacity` is reached.
struct Lru {
    entries: IndexMap<String, MetadataItem>,
    capacity: usize,
}

impl Lru {
    fn new(capacity: usize) -> Self {
        Self {
            entries: IndexMap::with_capacity(capacity),
            capacity,
        }
    }

    fn get(&mut self, key: &str) -> Option<MetadataItem> {
        let index = self.entries.get_index_of(key)?;
        let last = self.entries.len() - 1;
        self.entries.move_index(index, last);
        Some(self.entries[last].clone())
    }

    fn insert(&mut self, key: String, item: MetadataItem) {
        self.entries.shift_remove(&key);
        self.entries.insert(key, item);
        if self.entries.len() > self.capacity {
            self.entries.shift_remove_index(0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_protocol::entity_extension_data::EntityExtensionData;
    use librespot_protocol::extended_metadata::EntityExtensionDataArray;
    use librespot_protocol::metadata as proto;
    use protobuf::well_known_types::any::Any;

    const TRACK: &str = "spotify:track:4uLU6hMCjMI75M1A2tKUQC";
    const ALBUM: &str = "spotify:album:6akEvsycLGftJxYudPjmqK";
    const SHOW: &str = "spotify:show:4rOoJ6Egrf8K2IrywzwOMk";
    const EPISODE: &str = "spotify:episode:512ojhOuo1ktJprKbVcKyQ";

    fn context(country: &str) -> Context {
        Context {
            user: UserData {
                country: country.to_owned(),
                ..UserData::default()
            },
            image_url: DEFAULT_IMAGE_URL.to_owned(),
        }
    }

    fn gid(uri: &str) -> Vec<u8> {
        let base62 = uri.rsplit(':').next().unwrap();
        librespot_core::SpotifyId::from_base62(base62)
            .unwrap()
            .to_raw()
            .to_vec()
    }

    fn image(byte: u8, size: proto::image::Size, width: i32) -> proto::Image {
        proto::Image {
            file_id: Some(vec![byte; 20]),
            size: Some(size.into()),
            width: Some(width),
            height: Some(width),
            ..Default::default()
        }
    }

    fn track_message(countries_allowed: Option<&str>) -> proto::Track {
        let album = proto::Album {
            gid: Some(gid(ALBUM)),
            name: Some("Album".to_owned()),
            cover_group: Some(proto::ImageGroup {
                image: vec![
                    image(2, proto::image::Size::LARGE, 640),
                    image(1, proto::image::Size::SMALL, 64),
                ],
                ..Default::default()
            })
            .into(),
            ..Default::default()
        };
        proto::Track {
            gid: Some(gid(TRACK)),
            name: Some("Song".to_owned()),
            album: Some(album).into(),
            duration: Some(215_000),
            explicit: Some(true),
            restriction: countries_allowed
                .map(|c| {
                    let mut restriction = proto::Restriction {
                        catalogue_str: vec!["premium".to_owned()],
                        ..Default::default()
                    };
                    restriction.set_countries_allowed(c.to_owned());
                    restriction
                })
                .into_iter()
                .collect(),
            ..Default::default()
        }
    }

    fn entry(uri: &str, status: i32, value: Option<Vec<u8>>) -> EntityExtensionData {
        let mut data = EntityExtensionData {
            entity_uri: uri.to_owned(),
            extension_data: value
                .map(|value| Any {
                    value,
                    ..Default::default()
                })
                .into(),
            ..Default::default()
        };
        data.header.mut_or_insert_default().status_code = status;
        data
    }

    fn response(entries: Vec<EntityExtensionData>) -> BatchedExtensionResponse {
        BatchedExtensionResponse {
            extended_metadata: vec![EntityExtensionDataArray {
                extension_data: entries,
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    fn decode_one(uri: &str, data: EntityExtensionData, country: &str) -> MetadataItem {
        let batch = [Requested::parse(uri).unwrap()];
        decode(&response(vec![data]), &batch, &context(country))
            .remove(uri)
            .unwrap()
    }

    fn track(item: MetadataItem) -> TrackMetadata {
        match item {
            MetadataItem::Track { track } => track,
            other => panic!("expected a track, got {other:?}"),
        }
    }

    #[test]
    fn decodes_track_into_flat_record_with_artwork_smallest_first() {
        let bytes = track_message(None).write_to_bytes().unwrap();
        let track = track(decode_one(TRACK, entry(TRACK, 200, Some(bytes)), "US"));

        assert_eq!(track.uri, TRACK);
        assert_eq!(track.title, "Song");
        assert_eq!(
            track.album,
            ItemRef {
                uri: ALBUM.to_owned(),
                name: "Album".to_owned()
            }
        );
        assert_eq!(track.duration_ms, 215_000);
        assert!(track.explicit);
        assert_eq!(track.playability, Playability::Playable);
        let sizes: Vec<_> = track.artwork.iter().map(|a| (a.size, a.width)).collect();
        assert_eq!(sizes, [(ArtworkSize::Small, 64), (ArtworkSize::Large, 640)]);
        assert_eq!(
            track.artwork[0].url,
            format!("https://i.scdn.co/image/{}", "01".repeat(20))
        );
    }

    #[test]
    fn decodes_show_with_episodes_in_server_order() {
        let episode = |uri| proto::Episode {
            gid: Some(gid(uri)),
            ..Default::default()
        };
        let message = proto::Show {
            gid: Some(gid(SHOW)),
            name: Some("Podcast".to_owned()),
            publisher: Some("Studio".to_owned()),
            description: Some("About".to_owned()),
            cover_image: Some(proto::ImageGroup {
                image: vec![image(1, proto::image::Size::SMALL, 64)],
                ..Default::default()
            })
            .into(),
            episode: vec![
                episode(EPISODE),
                episode("spotify:episode:4rOoJ6Egrf8K2IrywzwOMk"),
            ],
            ..Default::default()
        };
        let bytes = message.write_to_bytes().unwrap();
        let MetadataItem::Show { show } = decode_one(SHOW, entry(SHOW, 200, Some(bytes)), "US")
        else {
            panic!("expected a show");
        };

        assert_eq!(show.uri, SHOW);
        assert_eq!(show.name, "Podcast");
        assert_eq!(show.publisher, "Studio");
        assert_eq!(show.description, "About");
        assert_eq!(show.artwork.len(), 1);
        assert_eq!(
            show.episodes,
            [EPISODE, "spotify:episode:4rOoJ6Egrf8K2IrywzwOMk"]
        );
    }

    #[test]
    fn track_outside_allowed_countries_is_region_locked() {
        let bytes = track_message(Some("USGB")).write_to_bytes().unwrap();
        let locked = track(decode_one(
            TRACK,
            entry(TRACK, 200, Some(bytes.clone())),
            "PL",
        ));
        let open = track(decode_one(TRACK, entry(TRACK, 200, Some(bytes)), "GB"));

        assert_eq!(locked.playability, Playability::RegionLocked);
        assert_eq!(open.playability, Playability::Playable);
    }

    #[test]
    fn item_failures_are_typed() {
        let cases = [
            (entry(TRACK, 404, None), ItemError::NotFound),
            (entry(TRACK, 500, None), ItemError::Failed { status: 500 }),
            (
                entry(TRACK, 200, Some(vec![0xff, 0xff])),
                ItemError::Malformed,
            ),
            (entry(ALBUM, 200, None), ItemError::Failed { status: 0 }),
        ];
        for (data, error) in cases {
            assert_eq!(
                decode_one(TRACK, data, "US"),
                MetadataItem::Unavailable {
                    uri: TRACK.to_owned(),
                    error
                }
            );
        }
    }

    #[test]
    fn request_asks_for_each_uri_with_its_extension_kind() {
        let batch = [
            Requested::parse(TRACK).unwrap(),
            Requested::parse(ALBUM).unwrap(),
            Requested::parse(SHOW).unwrap(),
        ];
        let request = request(&batch);
        let asked: Vec<_> = request
            .entity_request
            .iter()
            .map(|e| {
                (
                    e.entity_uri.as_str(),
                    e.query[0].extension_kind.enum_value().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            asked,
            [
                (TRACK, ExtensionKind::TRACK_V4),
                (ALBUM, ExtensionKind::ALBUM_V4),
                (SHOW, ExtensionKind::SHOW_V4)
            ]
        );
    }

    #[test]
    fn parse_rejects_invalid_and_unsupported_uris() {
        assert!(matches!(
            Requested::parse("nope"),
            Err(MetadataError::InvalidUri { .. })
        ));
        assert!(matches!(
            Requested::parse("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
            Err(MetadataError::UnsupportedKind { .. })
        ));
    }

    #[test]
    fn lru_evicts_least_recently_used() {
        let item = |n: u8| MetadataItem::Unavailable {
            uri: n.to_string(),
            error: ItemError::NotFound,
        };
        let mut lru = Lru::new(2);
        lru.insert("a".into(), item(1));
        lru.insert("b".into(), item(2));
        assert!(lru.get("a").is_some());
        lru.insert("c".into(), item(3));

        assert!(lru.get("b").is_none());
        assert_eq!(lru.get("a"), Some(item(1)));
        assert_eq!(lru.get("c"), Some(item(3)));
    }

    #[test]
    fn lru_reinsert_replaces_without_growing() {
        let mut lru = Lru::new(2);
        let item = |error| MetadataItem::Unavailable {
            uri: "x".into(),
            error,
        };
        lru.insert("a".into(), item(ItemError::NotFound));
        lru.insert("a".into(), item(ItemError::Malformed));
        assert_eq!(lru.entries.len(), 1);
        assert_eq!(lru.get("a"), Some(item(ItemError::Malformed)));
    }
}
