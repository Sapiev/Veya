//! Typed metadata for tracks, albums, artists, episodes and shows, fetched in
//! batches through extended metadata, cached in memory and in the metadata
//! store.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

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
use serde::{Deserialize, Serialize};

use crate::lyrics::Lyrics;
use crate::session::SpotSession;
use crate::store::MetadataStore;

const BATCH_SIZE: usize = 100;
const CACHE_CAPACITY: usize = 5_000;
/// Older stored items count as misses, so playability changes reconcile.
const STORE_MAX_AGE: i64 = 7 * 24 * 60 * 60;
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ItemError {
    NotFound,
    Malformed,
    /// HTTP-like status from Spotify; 0 when the item was missing from the reply.
    Failed {
        status: i32,
    },
}

/// Whether the signed-in account may play the item in its country now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum Playability {
    Playable,
    RegionLocked,
    NotYetReleased,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ArtworkSize {
    Small,
    Default,
    Large,
    XLarge,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Artwork {
    pub url: String,
    pub size: ArtworkSize,
    /// 0 when Spotify does not report it; fall back to `size`.
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ItemRef {
    pub uri: String,
    pub name: String,
}

/// Artwork lists run smallest first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct AlbumMetadata {
    pub uri: String,
    pub title: String,
    pub artists: Vec<ItemRef>,
    pub tracks: Vec<String>,
    pub playability: Playability,
    pub artwork: Vec<Artwork>,
    /// `None` when the album carries no release date.
    pub year: Option<i32>,
    pub copyrights: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ArtistMetadata {
    pub uri: String,
    pub name: String,
    pub artwork: Vec<Artwork>,
    /// Top tracks for the account's country, falling back to the global list.
    pub top_tracks: Vec<String>,
    pub albums: Vec<String>,
    pub singles: Vec<String>,
    pub compilations: Vec<String>,
    pub related: Vec<ItemRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct EpisodeMetadata {
    pub uri: String,
    pub title: String,
    pub show_name: String,
    pub description: String,
    pub duration_ms: u32,
    pub explicit: bool,
    pub playability: Playability,
    pub artwork: Vec<Artwork>,
    /// Release time in Unix seconds; `None` when the episode carries no date.
    pub published_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct ShowMetadata {
    pub uri: String,
    pub name: String,
    pub publisher: String,
    pub description: String,
    pub artwork: Vec<Artwork>,
    /// Episode URIs in server order.
    pub episodes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
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
    store: Option<Arc<MetadataStore>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl MetadataService {
    #[uniffi::constructor]
    pub fn new(session: Arc<SpotSession>, store: Option<Arc<MetadataStore>>) -> Arc<Self> {
        Arc::new(Self {
            session,
            cache: Mutex::new(Lru::new(CACHE_CAPACITY)),
            store,
        })
    }

    /// One entry per URI, in input order. Items in memory or stored within
    /// the last 7 days cost no request; the rest go out in batches of up to
    /// 100. Failed items are not cached.
    pub async fn items(&self, uris: Vec<String>) -> Result<Vec<MetadataItem>, MetadataError> {
        let requested = uris
            .iter()
            .map(|uri| Requested::parse(uri))
            .collect::<Result<Vec<_>, _>>()?;

        let mut found = HashMap::new();
        let mut missing = Vec::new();
        let generation = self.generation();
        {
            let mut cache = self.hot();
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
        if let Some(store) = &self.store {
            let hits = from_store(store, &mut missing, now());
            let mut cache = self.hot();
            for (key, item) in hits {
                if cache.generation == generation {
                    cache.insert(key.clone(), item.clone());
                }
                found.insert(key, item);
            }
        }

        for batch in missing.chunks(BATCH_SIZE) {
            let generation = self.generation();
            let session = self.session.current_session();
            let response = session
                .spclient()
                .get_extended_metadata(request(batch))
                .await
                .map_err(|e| MetadataError::Request {
                    message: e.to_string(),
                })?;
            let decoded = decode(&response, batch, &Context::of(&session));
            if let Some(store) = &self.store {
                to_store(store, generation, &decoded, now());
            }
            let mut cache = self.hot();
            for (key, item) in decoded {
                // Items fetched across a clear are returned but not kept.
                if cache.generation == generation
                    && !matches!(item, MetadataItem::Unavailable { .. })
                {
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

    /// Lyrics of the track at `track_uri`, or `None` when it has none. Not cached.
    pub async fn lyrics(&self, track_uri: String) -> Result<Option<Lyrics>, MetadataError> {
        crate::lyrics::fetch(&self.session.current_session(), &track_uri).await
    }
}

impl MetadataService {
    fn generation(&self) -> u64 {
        self.store.as_ref().map_or(0, |store| store.generation())
    }

    fn hot(&self) -> MutexGuard<'_, Lru> {
        hot(&self.cache, self.generation())
    }
}

/// The memory cache, emptied first when the store was cleared since it
/// filled, so a clear drops memory too.
fn hot(cache: &Mutex<Lru>, generation: u64) -> MutexGuard<'_, Lru> {
    let mut lru = cache.lock().unwrap();
    if lru.generation != generation {
        lru.entries.clear();
        lru.generation = generation;
    }
    lru
}

/// Returns the fresh store hits and leaves the rest in `missing`.
fn from_store(
    store: &MetadataStore,
    missing: &mut Vec<Requested>,
    now: i64,
) -> HashMap<String, MetadataItem> {
    let keys: Vec<&str> = missing.iter().map(|item| item.key.as_str()).collect();
    let hits: HashMap<String, MetadataItem> = store.metadata_items(&keys, now - STORE_MAX_AGE);
    missing.retain(|item| !hits.contains_key(&item.key));
    hits
}

fn to_store(
    store: &MetadataStore,
    generation: u64,
    decoded: &HashMap<String, MetadataItem>,
    now: i64,
) {
    let items: Vec<(&str, &MetadataItem)> = decoded
        .iter()
        .filter(|(_, item)| !matches!(item, MetadataItem::Unavailable { .. }))
        .map(|(key, item)| (key.as_str(), item))
        .collect();
    store.put_metadata_items(generation, &items, now);
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
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
                        // librespot turns a missing date into year 0.
                        year: Some(album.date.as_utc().year()).filter(|&year| year > 0),
                        copyrights: album.copyrights.iter().map(|c| c.text.clone()).collect(),
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
                        top_tracks: uris(artist.top_tracks.for_country(&self.user.country).iter()),
                        albums: uris(artist.albums_current()),
                        singles: uris(artist.singles_current()),
                        compilations: uris(artist.compilations_current()),
                        related: artist
                            .related
                            .iter()
                            .map(|a| item_ref(&a.id, &a.name))
                            .collect(),
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
                        // librespot turns a missing date into year 0, like albums.
                        published_at: Some(episode.publish_time.as_utc())
                            .filter(|date| date.year() > 0)
                            .map(|date| date.unix_timestamp()),
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

fn uris<'a>(ids: impl Iterator<Item = &'a SpotifyUri>) -> Vec<String> {
    ids.filter_map(|id| id.to_uri().ok()).collect()
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
    /// Store generation the entries were cached under.
    generation: u64,
}

impl Lru {
    fn new(capacity: usize) -> Self {
        Self {
            entries: IndexMap::with_capacity(capacity),
            capacity,
            generation: 0,
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
    use librespot_metadata::restriction::Restriction;
    use librespot_protocol::entity_extension_data::EntityExtensionData;
    use librespot_protocol::extended_metadata::EntityExtensionDataArray;
    use librespot_protocol::metadata as proto;
    use protobuf::well_known_types::any::Any;

    const TRACK: &str = "spotify:track:4uLU6hMCjMI75M1A2tKUQC";
    const ALBUM: &str = "spotify:album:6akEvsycLGftJxYudPjmqK";
    const SHOW: &str = "spotify:show:4rOoJ6Egrf8K2IrywzwOMk";
    const ARTIST: &str = "spotify:artist:0OdUWJ0sBjDrqHygGUXeCF";
    const RELATED: &str = "spotify:artist:3jOstUTkEu2JkjvRdBA5Gu";
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
    fn decodes_album_year_and_copyrights() {
        let mut copyright = proto::Copyright {
            text: Some("2024 Label".to_owned()),
            ..Default::default()
        };
        copyright.set_type(proto::copyright::Type::C);
        let message = proto::Album {
            gid: Some(gid(ALBUM)),
            name: Some("Album".to_owned()),
            date: Some(proto::Date {
                year: Some(2024),
                ..Default::default()
            })
            .into(),
            copyright: vec![copyright],
            ..Default::default()
        };
        let bytes = message.write_to_bytes().unwrap();
        let MetadataItem::Album { album } = decode_one(ALBUM, entry(ALBUM, 200, Some(bytes)), "US")
        else {
            panic!("expected an album");
        };

        assert_eq!(album.year, Some(2024));
        assert_eq!(album.copyrights, ["2024 Label"]);
    }

    #[test]
    fn album_without_date_has_no_year() {
        let message = proto::Album {
            gid: Some(gid(ALBUM)),
            ..Default::default()
        };
        let bytes = message.write_to_bytes().unwrap();
        let MetadataItem::Album { album } = decode_one(ALBUM, entry(ALBUM, 200, Some(bytes)), "US")
        else {
            panic!("expected an album");
        };

        assert_eq!(album.year, None);
    }

    #[test]
    fn decodes_artist_sections_with_country_top_tracks() {
        let track = |uri| proto::Track {
            gid: Some(gid(uri)),
            ..Default::default()
        };
        let group = |uri| proto::AlbumGroup {
            album: vec![proto::Album {
                gid: Some(gid(uri)),
                ..Default::default()
            }],
            ..Default::default()
        };
        let other_track = "spotify:track:0eGsygTp906u18L0Oimnem";
        let single = "spotify:album:1DFixLWuPkv3KT3TnV35m3";
        let message = proto::Artist {
            gid: Some(gid(ARTIST)),
            name: Some("Band".to_owned()),
            top_track: vec![
                proto::TopTracks {
                    country: Some("".to_owned()),
                    track: vec![track(other_track)],
                    ..Default::default()
                },
                proto::TopTracks {
                    country: Some("PL".to_owned()),
                    track: vec![track(TRACK)],
                    ..Default::default()
                },
            ],
            album_group: vec![group(ALBUM)],
            single_group: vec![group(single)],
            related: vec![proto::Artist {
                gid: Some(gid(RELATED)),
                name: Some("Friends".to_owned()),
                ..Default::default()
            }],
            ..Default::default()
        };
        let bytes = message.write_to_bytes().unwrap();
        let decode =
            |country| match decode_one(ARTIST, entry(ARTIST, 200, Some(bytes.clone())), country) {
                MetadataItem::Artist { artist } => artist,
                other => panic!("expected an artist, got {other:?}"),
            };

        let artist = decode("PL");
        assert_eq!(artist.top_tracks, [TRACK]);
        assert_eq!(artist.albums, [ALBUM]);
        assert_eq!(artist.singles, [single]);
        assert!(artist.compilations.is_empty());
        assert_eq!(
            artist.related,
            [ItemRef {
                uri: RELATED.to_owned(),
                name: "Friends".to_owned()
            }]
        );
        assert_eq!(decode("US").top_tracks, [other_track]);
    }

    fn episode_with(publish_time: Option<proto::Date>) -> EpisodeMetadata {
        let message = proto::Episode {
            gid: Some(gid(EPISODE)),
            name: Some("Episode".to_owned()),
            description: Some("Notes".to_owned()),
            duration: Some(1_800_000),
            publish_time: publish_time.into(),
            ..Default::default()
        };
        let bytes = message.write_to_bytes().unwrap();
        match decode_one(EPISODE, entry(EPISODE, 200, Some(bytes)), "US") {
            MetadataItem::Episode { episode } => episode,
            other => panic!("expected an episode, got {other:?}"),
        }
    }

    #[test]
    fn decodes_episode_description_duration_and_release_time() {
        let episode = episode_with(Some(proto::Date {
            year: Some(2025),
            month: Some(10),
            day: Some(1),
            hour: Some(6),
            minute: Some(30),
            ..Default::default()
        }));

        assert_eq!(episode.title, "Episode");
        assert_eq!(episode.description, "Notes");
        assert_eq!(episode.duration_ms, 1_800_000);
        // 2025-10-01T06:30:00Z
        assert_eq!(episode.published_at, Some(1_759_300_200));
    }

    #[test]
    fn episode_without_date_has_no_release_time() {
        assert_eq!(episode_with(None).published_at, None);
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
    fn playability_honours_forbidden_countries_for_the_account_catalogue_only() {
        let forbidden = |catalogue: &str, countries: &str| {
            let mut message = proto::Restriction {
                catalogue_str: vec![catalogue.to_owned()],
                ..Default::default()
            };
            message.set_countries_forbidden(countries.to_owned());
            Restriction::from(&message)
        };
        let playability = |country, restriction| {
            context(country)
                .playability(&Availabilities::default(), &Restrictions(vec![restriction]))
        };

        assert_eq!(
            playability("PL", forbidden("premium", "DEPL")),
            Playability::RegionLocked
        );
        assert_eq!(
            playability("GB", forbidden("premium", "DEPL")),
            Playability::Playable
        );
        assert_eq!(
            playability("PL", forbidden("free", "PL")),
            Playability::Playable,
            "another catalogue's restriction does not apply"
        );
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

    #[test]
    fn store_keeps_decoded_items_until_they_age_out() {
        let store = crate::store::tests::temp_store("metadata");
        let bytes = track_message(None).write_to_bytes().unwrap();
        let batch = [
            Requested::parse(TRACK).unwrap(),
            Requested::parse(ALBUM).unwrap(),
        ];
        let decoded = decode(
            &response(vec![
                entry(TRACK, 200, Some(bytes)),
                entry(ALBUM, 404, None),
            ]),
            &batch,
            &context("US"),
        );
        to_store(&store, store.generation(), &decoded, 1_000);

        let mut missing = batch.to_vec();
        let hits = from_store(&store, &mut missing, 1_000 + STORE_MAX_AGE);
        assert_eq!(hits[TRACK], decoded[TRACK]);
        assert_eq!(missing.len(), 1, "unavailable items are not stored");
        assert_eq!(missing[0].key, ALBUM);

        let mut missing = batch.to_vec();
        assert!(from_store(&store, &mut missing, 1_001 + STORE_MAX_AGE).is_empty());
        assert_eq!(missing.len(), 2);
    }

    #[test]
    fn memory_cache_empties_when_the_store_generation_moves() {
        let cache = Mutex::new(Lru::new(2));
        let item = MetadataItem::Unavailable {
            uri: "x".into(),
            error: ItemError::NotFound,
        };
        hot(&cache, 0).insert("a".into(), item.clone());
        assert_eq!(hot(&cache, 0).get("a"), Some(item));
        assert_eq!(hot(&cache, 1).get("a"), None);
    }
}
