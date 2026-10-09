//! The user's library (liked songs, saved albums, followed artists and shows) through
//! spclient's collection v2 endpoints, cached in the metadata store per set
//! and kept fresh by delta syncs that dealer pushes trigger.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use http::{HeaderMap, HeaderValue, Method, header::CONTENT_TYPE};
use indexmap::IndexMap;
use librespot_core::Session;
use protobuf::rt::WireType;
use protobuf::{CodedInputStream, CodedOutputStream};
use serde::{Deserialize, Serialize};

use crate::push::PushWatch;
use crate::session::SpotSession;
use crate::store::MetadataStore;

const PAGE_LIMIT: i32 = 300;
const PUSH_URI: &str = "hm://collection/";

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum LibraryError {
    #[error("not a track, album, artist or show URI: {uri}")]
    UnsupportedUri { uri: String },
    #[error("library request failed: {message}")]
    Request { message: String },
}

impl From<librespot_core::Error> for LibraryError {
    fn from(e: librespot_core::Error) -> Self {
        Self::Request {
            message: e.to_string(),
        }
    }
}

impl From<protobuf::Error> for LibraryError {
    fn from(e: protobuf::Error) -> Self {
        Self::Request {
            message: format!("malformed collection response: {e}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LibraryKind {
    Tracks,
    Albums,
    Artists,
    Shows,
}

impl LibraryKind {
    fn of(uri: &str) -> Option<Self> {
        [Self::Tracks, Self::Albums, Self::Artists, Self::Shows]
            .into_iter()
            .find(|kind| kind.holds(uri))
    }

    fn holds(self, uri: &str) -> bool {
        let prefix = match self {
            Self::Tracks => "spotify:track:",
            Self::Albums => "spotify:album:",
            Self::Artists => "spotify:artist:",
            Self::Shows => "spotify:show:",
        };
        uri.starts_with(prefix)
    }

    /// Tracks and albums share the server's `collection` set.
    fn set(self) -> &'static str {
        match self {
            Self::Tracks | Self::Albums => "collection",
            Self::Artists => "artist",
            Self::Shows => "show",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct LibraryItem {
    pub uri: String,
    /// Unix seconds.
    pub added_at: i64,
}

#[uniffi::export(with_foreign)]
pub trait LibraryObserver: Send + Sync {
    fn on_library_changed(&self);
}

#[derive(uniffi::Object)]
pub struct LibraryService {
    session: Arc<SpotSession>,
    sets: SetCache,
    push: PushWatch,
}

#[uniffi::export(async_runtime = "tokio")]
impl LibraryService {
    /// Without a `store` nothing persists.
    #[uniffi::constructor]
    pub fn new(session: Arc<SpotSession>, store: Option<Arc<MetadataStore>>) -> Arc<Self> {
        Arc::new(Self {
            session,
            sets: SetCache::new(store),
            push: PushWatch::new(PUSH_URI),
        })
    }

    /// What is in memory or in the store, newest first, without a request.
    pub fn cached(&self, kind: LibraryKind) -> Vec<LibraryItem> {
        let username = self.session.current_session().username();
        self.sets.get(kind.set(), &username).items(kind)
    }

    /// Syncs the kind's set with the server (delta when possible, full
    /// paging otherwise), persists it and returns it newest first.
    pub async fn refresh(&self, kind: LibraryKind) -> Result<Vec<LibraryItem>, LibraryError> {
        let session = self.session.current_session();
        let username = session.username();
        let set = kind.set();
        let generation = self.sets.generation();
        let token = self.sets.get(set, &username).sync_token;

        let synced = match sync(&session, &username, set, &token).await? {
            Synced::Delta { items, sync_token } => {
                self.sets.update(set, &username, generation, |state| {
                    state.apply(items);
                    state.sync_token = sync_token;
                })
            }
            Synced::Full(full) => self
                .sets
                .update(set, &username, generation, |state| *state = full),
        };
        Ok(synced.items(kind))
    }

    /// Likes or unlikes a track, saves or removes an album, follows or
    /// unfollows an artist or show. Local state changes only after the server accepts.
    pub async fn set_saved(&self, uri: String, saved: bool) -> Result<(), LibraryError> {
        let kind = LibraryKind::of(&uri)
            .ok_or_else(|| LibraryError::UnsupportedUri { uri: uri.clone() })?;
        let session = self.session.current_session();
        let username = session.username();
        let item = WireItem {
            uri,
            added_at: now(),
            is_removed: !saved,
        };
        let generation = self.sets.generation();
        let request = encode_write(&username, kind.set(), &item, &client_update_id())?;
        post(&session, "/collection/v2/write", request).await?;

        self.sets
            .update(kind.set(), &username, generation, |state| {
                state.apply(vec![item])
            });
        Ok(())
    }

    /// Returns when a dealer push reports a library change, or when a
    /// reconnect replaced the session (a push may have been missed).
    /// Call `refresh` afterwards, then wait again.
    pub async fn wait_for_change(&self) {
        self.push.next(&self.session).await;
    }
}

/// In-memory sets over the store. Each set remembers the user and store
/// generation it was loaded under and reloads when either changes, so a
/// `MetadataStore::clear` empties memory too.
struct SetCache {
    store: Option<Arc<MetadataStore>>,
    sets: Mutex<HashMap<&'static str, Loaded>>,
}

struct Loaded {
    username: String,
    generation: u64,
    state: SetState,
}

impl SetCache {
    fn new(store: Option<Arc<MetadataStore>>) -> Self {
        Self {
            store,
            sets: Mutex::new(HashMap::new()),
        }
    }

    /// Capture before a request and pass to `update`.
    fn generation(&self) -> u64 {
        self.store.as_ref().map_or(0, |store| store.generation())
    }

    fn get(&self, set: &'static str, username: &str) -> SetState {
        let mut sets = self.sets.lock().unwrap();
        self.current(&mut sets, set, username).state.clone()
    }

    /// Applies `change` in memory and persists it, unless the store was
    /// cleared since `generation`: then only the returned copy changes.
    fn update(
        &self,
        set: &'static str,
        username: &str,
        generation: u64,
        change: impl FnOnce(&mut SetState),
    ) -> SetState {
        let snapshot = {
            let mut sets = self.sets.lock().unwrap();
            let loaded = self.current(&mut sets, set, username);
            if loaded.generation != generation {
                let mut stale = loaded.state.clone();
                change(&mut stale);
                return stale;
            }
            change(&mut loaded.state);
            loaded.state.clone()
        };
        if let Some(store) = &self.store {
            snapshot.persist(store, generation, set, username);
        }
        snapshot
    }

    fn current<'a>(
        &self,
        sets: &'a mut HashMap<&'static str, Loaded>,
        set: &'static str,
        username: &str,
    ) -> &'a mut Loaded {
        let generation = self.generation();
        let stale = sets
            .get(set)
            .is_none_or(|loaded| loaded.username != username || loaded.generation != generation);
        if stale {
            let state = self
                .store
                .as_ref()
                .map(|store| SetState::load(store, set, username))
                .unwrap_or_default();
            sets.insert(
                set,
                Loaded {
                    username: username.to_owned(),
                    generation,
                    state,
                },
            );
        }
        sets.get_mut(set).expect("inserted above")
    }
}

enum Synced {
    Delta {
        items: Vec<WireItem>,
        sync_token: String,
    },
    Full(SetState),
}

async fn sync(
    session: &Session,
    username: &str,
    set: &str,
    token: &str,
) -> Result<Synced, LibraryError> {
    if !token.is_empty() {
        let body = post(
            session,
            "/collection/v2/delta",
            encode_delta(username, set, token)?,
        )
        .await?;
        let delta = decode_delta(&body)?;
        if delta.possible {
            return Ok(Synced::Delta {
                items: delta.items,
                sync_token: delta.sync_token,
            });
        }
    }

    let mut state = SetState::default();
    let mut page_token = String::new();
    loop {
        let request = encode_page(username, set, &page_token)?;
        let page = decode_page(&post(session, "/collection/v2/paging", request).await?)?;
        state.apply(page.items);
        // The first page's token covers everything paged after it.
        if state.sync_token.is_empty() {
            state.sync_token = page.sync_token;
        }
        if page.next_page_token.is_empty() {
            return Ok(Synced::Full(state));
        }
        page_token = page.next_page_token;
    }
}

async fn post(session: &Session, endpoint: &str, body: Vec<u8>) -> Result<Vec<u8>, LibraryError> {
    let mut headers = HeaderMap::new();
    headers.insert(
        CONTENT_TYPE,
        HeaderValue::from_static("application/x-protobuf"),
    );
    let response = session
        .spclient()
        .request(&Method::POST, endpoint, Some(headers), Some(&body))
        .await?;
    Ok(response.to_vec())
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn client_update_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    format!("{nanos:032x}")
}

#[derive(Debug, Clone, Default, PartialEq)]
struct SetState {
    sync_token: String,
    items: Vec<LibraryItem>,
}

impl SetState {
    /// Upserts saved items and drops removed ones; a later change to the
    /// same URI wins.
    fn apply(&mut self, changes: Vec<WireItem>) {
        let changes: IndexMap<String, WireItem> = changes
            .into_iter()
            .map(|change| (change.uri.clone(), change))
            .collect();
        self.items.retain(|item| !changes.contains_key(&item.uri));
        self.items.extend(
            changes
                .into_values()
                .filter(|change| !change.is_removed)
                .map(|change| LibraryItem {
                    uri: change.uri,
                    added_at: change.added_at,
                }),
        );
    }

    fn items(&self, kind: LibraryKind) -> Vec<LibraryItem> {
        let mut items: Vec<_> = self
            .items
            .iter()
            .filter(|item| kind.holds(&item.uri))
            .cloned()
            .collect();
        items.sort_by_key(|item| std::cmp::Reverse(item.added_at));
        items
    }

    fn load(store: &MetadataStore, set: &str, username: &str) -> Self {
        store
            .library_set(username, set)
            .map(|(sync_token, items)| Self { sync_token, items })
            .unwrap_or_default()
    }

    fn persist(&self, store: &MetadataStore, generation: u64, set: &str, username: &str) {
        store.put_library_set(generation, username, set, &self.sync_token, &self.items);
    }
}

// Hand-written codec for spotify.collection.proto.v2 (collection2v2.proto),
// which librespot-protocol does not generate. Field numbers:
//   CollectionItem { 1 uri: string, 2 added_at: int32, 3 is_removed: bool }
//   PageRequest    { 1 username, 2 set, 3 pagination_token, 4 limit: int32 }
//   PageResponse   { 1 items: repeated CollectionItem, 2 next_page_token, 3 sync_token }
//   DeltaRequest   { 1 username, 2 set, 3 last_sync_token }
//   DeltaResponse  { 1 delta_update_possible: bool, 2 items: repeated CollectionItem, 3 sync_token }
//   WriteRequest   { 1 username, 2 set, 3 items: repeated CollectionItem, 4 client_update_id }

#[derive(Debug, Clone, PartialEq)]
struct WireItem {
    uri: String,
    added_at: i64,
    is_removed: bool,
}

#[derive(Debug, Default, PartialEq)]
struct Page {
    items: Vec<WireItem>,
    next_page_token: String,
    sync_token: String,
}

#[derive(Debug, Default, PartialEq)]
struct Delta {
    possible: bool,
    items: Vec<WireItem>,
    sync_token: String,
}

fn encode(
    write: impl FnOnce(&mut CodedOutputStream) -> protobuf::Result<()>,
) -> protobuf::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let mut os = CodedOutputStream::vec(&mut bytes);
    write(&mut os)?;
    os.flush()?;
    drop(os);
    Ok(bytes)
}

fn encode_item(item: &WireItem) -> protobuf::Result<Vec<u8>> {
    encode(|os| {
        os.write_string(1, &item.uri)?;
        os.write_int32(2, i32::try_from(item.added_at).unwrap_or(i32::MAX))?;
        os.write_bool(3, item.is_removed)
    })
}

fn encode_page(username: &str, set: &str, page_token: &str) -> protobuf::Result<Vec<u8>> {
    encode(|os| {
        os.write_string(1, username)?;
        os.write_string(2, set)?;
        os.write_string(3, page_token)?;
        os.write_int32(4, PAGE_LIMIT)
    })
}

fn encode_delta(username: &str, set: &str, sync_token: &str) -> protobuf::Result<Vec<u8>> {
    encode(|os| {
        os.write_string(1, username)?;
        os.write_string(2, set)?;
        os.write_string(3, sync_token)
    })
}

fn encode_write(
    username: &str,
    set: &str,
    item: &WireItem,
    client_update_id: &str,
) -> protobuf::Result<Vec<u8>> {
    let item = encode_item(item)?;
    encode(|os| {
        os.write_string(1, username)?;
        os.write_string(2, set)?;
        os.write_bytes(3, &item)?;
        os.write_string(4, client_update_id)
    })
}

/// Calls `field` with each field number; unknown fields are skipped.
pub(crate) fn decode_fields(
    bytes: &[u8],
    mut field: impl FnMut(u32, &mut CodedInputStream) -> protobuf::Result<bool>,
) -> protobuf::Result<()> {
    let mut is = CodedInputStream::from_bytes(bytes);
    while let Some(tag) = is.read_raw_tag_or_eof()? {
        if !field(tag >> 3, &mut is)? {
            let wire_type = WireType::new(tag & 7).ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, format!("bad tag {tag}"))
            })?;
            is.skip_field(wire_type)?;
        }
    }
    Ok(())
}

fn decode_item(bytes: &[u8]) -> protobuf::Result<WireItem> {
    let mut item = WireItem {
        uri: String::new(),
        added_at: 0,
        is_removed: false,
    };
    decode_fields(bytes, |number, is| {
        match number {
            1 => item.uri = is.read_string()?,
            2 => item.added_at = i64::from(is.read_int32()?),
            3 => item.is_removed = is.read_bool()?,
            _ => return Ok(false),
        }
        Ok(true)
    })?;
    Ok(item)
}

fn decode_page(bytes: &[u8]) -> protobuf::Result<Page> {
    let mut page = Page::default();
    decode_fields(bytes, |number, is| {
        match number {
            1 => page.items.push(decode_item(&is.read_bytes()?)?),
            2 => page.next_page_token = is.read_string()?,
            3 => page.sync_token = is.read_string()?,
            _ => return Ok(false),
        }
        Ok(true)
    })?;
    Ok(page)
}

fn decode_delta(bytes: &[u8]) -> protobuf::Result<Delta> {
    let mut delta = Delta::default();
    decode_fields(bytes, |number, is| {
        match number {
            1 => delta.possible = is.read_bool()?,
            2 => delta.items.push(decode_item(&is.read_bytes()?)?),
            3 => delta.sync_token = is.read_string()?,
            _ => return Ok(false),
        }
        Ok(true)
    })?;
    Ok(delta)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(uri: &str, added_at: i64, is_removed: bool) -> WireItem {
        WireItem {
            uri: uri.to_owned(),
            added_at,
            is_removed,
        }
    }

    /// Encodes a response the way the server would, field by field.
    fn response(
        flag_field: Option<(u32, bool)>,
        items_field: u32,
        items: &[WireItem],
        strings: &[(u32, &str)],
    ) -> Vec<u8> {
        encode(|os| {
            if let Some((number, value)) = flag_field {
                os.write_bool(number, value)?;
            }
            for item in items {
                os.write_bytes(items_field, &encode_item(item)?)?;
            }
            for (number, value) in strings {
                os.write_string(*number, value)?;
            }
            os.write_string(99, "unknown field is skipped")
        })
        .unwrap()
    }

    #[test]
    fn page_request_bytes_match_the_proto_field_layout() {
        let bytes = encode_page("u", "collection", "t").unwrap();
        assert_eq!(
            bytes,
            [
                &[0x0a, 1][..],
                b"u",
                &[0x12, 10],
                b"collection",
                &[0x1a, 1],
                b"t",
                &[0x20, 0xac, 0x02], // limit 300
            ]
            .concat()
        );
    }

    #[test]
    fn write_request_nests_the_item() {
        let bytes = encode_write("u", "artist", &item("spotify:artist:a", 5, true), "id").unwrap();
        let mut nested = None;
        decode_fields(&bytes, |number, is| {
            if number == 3 {
                nested = Some(decode_item(&is.read_bytes()?)?);
                return Ok(true);
            }
            Ok(false)
        })
        .unwrap();
        assert_eq!(nested, Some(item("spotify:artist:a", 5, true)));
    }

    #[test]
    fn decodes_page_and_delta_responses() {
        let items = [
            item("spotify:track:a", 1, false),
            item("spotify:album:b", 2, false),
        ];
        let page = decode_page(&response(None, 1, &items, &[(2, "next"), (3, "sync")])).unwrap();
        assert_eq!(
            page,
            Page {
                items: items.to_vec(),
                next_page_token: "next".into(),
                sync_token: "sync".into(),
            }
        );

        let removed = [item("spotify:track:a", 0, true)];
        let delta = decode_delta(&response(Some((1, true)), 2, &removed, &[(3, "sync2")])).unwrap();
        assert_eq!(
            delta,
            Delta {
                possible: true,
                items: removed.to_vec(),
                sync_token: "sync2".into(),
            }
        );
    }

    #[test]
    fn truncated_response_is_an_error() {
        let bytes = response(None, 1, &[item("spotify:track:a", 1, false)], &[]);
        assert!(decode_page(&bytes[..bytes.len() / 2]).is_err());
    }

    #[test]
    fn apply_upserts_and_removes_and_kinds_filter_newest_first() {
        let mut state = SetState::default();
        state.apply(vec![
            item("spotify:track:old", 1, false),
            item("spotify:album:x", 2, false),
            item("spotify:track:new", 3, false),
        ]);
        state.apply(vec![
            item("spotify:track:old", 4, false),
            item("spotify:track:new", 0, true),
            item("spotify:track:gone", 0, true),
        ]);

        let uris = |kind| -> Vec<String> { state.items(kind).into_iter().map(|i| i.uri).collect() };
        assert_eq!(uris(LibraryKind::Tracks), ["spotify:track:old"]);
        assert_eq!(uris(LibraryKind::Albums), ["spotify:album:x"]);
        assert!(uris(LibraryKind::Artists).is_empty());
    }

    #[test]
    fn applying_the_same_change_twice_is_idempotent() {
        let change = vec![item("spotify:track:a", 1, false)];
        let mut once = SetState::default();
        once.apply(change.clone());
        let mut twice = once.clone();
        twice.apply(change);
        assert_eq!(once, twice);
    }

    #[test]
    fn kind_routes_uris_to_server_sets() {
        assert_eq!(
            LibraryKind::of("spotify:track:a").map(LibraryKind::set),
            Some("collection")
        );
        assert_eq!(
            LibraryKind::of("spotify:album:a").map(LibraryKind::set),
            Some("collection")
        );
        assert_eq!(
            LibraryKind::of("spotify:artist:a").map(LibraryKind::set),
            Some("artist")
        );
        assert_eq!(
            LibraryKind::of("spotify:show:a").map(LibraryKind::set),
            Some("show")
        );
        assert_eq!(LibraryKind::of("spotify:playlist:a"), None);
        assert_eq!(LibraryKind::of("spotify:episode:a"), None);
    }

    #[test]
    fn clear_empties_memory_and_drops_in_flight_updates() {
        let store = crate::store::tests::temp_store("library-clear");
        let sets = SetCache::new(Some(store.clone()));
        let saved = |state: &mut SetState| {
            state.sync_token = "s".into();
            state.apply(vec![item("spotify:track:a", 1, false)]);
        };
        sets.update("collection", "u", sets.generation(), saved);
        assert_eq!(sets.get("collection", "u").sync_token, "s");

        let in_flight = sets.generation();
        store.clear().unwrap();
        assert_eq!(sets.get("collection", "u"), SetState::default());

        let returned = sets.update("collection", "u", in_flight, saved);
        assert_eq!(returned.sync_token, "s");
        assert_eq!(sets.get("collection", "u"), SetState::default());
        assert_eq!(
            SetState::load(&store, "collection", "u"),
            SetState::default()
        );
    }

    #[test]
    fn memory_reloads_for_another_user() {
        let sets = SetCache::new(None);
        sets.update("collection", "alice", 0, |state| {
            state.apply(vec![item("spotify:track:a", 1, false)])
        });
        assert_eq!(sets.get("collection", "alice").items.len(), 1);
        assert_eq!(sets.get("collection", "bob"), SetState::default());
    }

    #[test]
    fn store_round_trips_per_user() {
        let store = crate::store::tests::temp_store("library");
        let mut state = SetState {
            sync_token: "s".into(),
            items: vec![],
        };
        state.apply(vec![item("spotify:track:a", 1, false)]);
        state.persist(&store, store.generation(), "collection", "alice");

        assert_eq!(SetState::load(&store, "collection", "alice"), state);
        assert_eq!(
            SetState::load(&store, "collection", "bob"),
            SetState::default()
        );
        assert_eq!(
            SetState::load(&store, "artist", "alice"),
            SetState::default()
        );
    }

    #[test]
    fn ten_thousand_cached_tracks_load_well_under_a_second() {
        let mut state = SetState::default();
        state.apply(
            (0..10_000)
                .map(|n| item(&format!("spotify:track:{n:022}"), n, false))
                .collect(),
        );
        let store = crate::store::tests::temp_store("library-10k");
        state.persist(&store, store.generation(), "collection", "u");

        let started = std::time::Instant::now();
        let tracks = SetState::load(&store, "collection", "u").items(LibraryKind::Tracks);
        assert_eq!(tracks.len(), 10_000);
        assert_eq!(tracks[0].added_at, 9_999);
        assert!(
            started.elapsed() < std::time::Duration::from_millis(250),
            "{:?}",
            started.elapsed()
        );
    }
}
