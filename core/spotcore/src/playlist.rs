//! The user's playlists through spclient's playlist4 endpoints: the root list
//! with its folders, playlist contents page by page, follower counts, and
//! dealer pushes that report changes made on other devices. Root lists and
//! fetched pages persist in the metadata store.

use std::collections::HashMap;
use std::hash::{BuildHasher, RandomState};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use http::header::{AUTHORIZATION, CONTENT_LENGTH, CONTENT_TYPE};
use http::{HeaderValue, Method, Request, StatusCode};
use librespot_core::Session;
use librespot_core::http_client::HttpClientError;
use librespot_protocol::playlist4_external::{
    Add, CreateListReply, Delta, Item, ItemAttributes, ListAttributeKind, ListAttributes,
    ListChanges, ListUpdateRequest, MetaItem, Mov, Op, RegisterPlaylistImageRequest,
    RegisterPlaylistImageResponse, Rem, SelectedListContent, UpdateItemAttributes,
    UpdateListAttributes, op::Kind,
};
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, percent_decode_str, utf8_percent_encode};
use protobuf::Message as _;
use serde::{Deserialize, Serialize};

use crate::library::decode_fields;
use crate::metadata::{Artwork, ArtworkSize, image_url_template};
use crate::push::PushWatch;
use crate::session::SpotSession;
use crate::store::MetadataStore;
use crate::util::{blocking, lock};

const ROOTLIST_PAGE: usize = 120;
const PUSH_URI: &str = "hm://playlist/";
const PLAYLIST_PREFIX: &str = "spotify:playlist:";
const IMAGE_UPLOAD_URL: &str = "https://image-upload.spotify.com/v4/playlist";
const MAX_PICTURE_BYTES: usize = 256 * 1024;
const PROFILE_PLAYLISTS: u32 = 200;
/// Local file URIs carry artist, album and title, so allow far past 22-char ids.
const MAX_LISTED_URI: usize = 2048;
const START_GROUP: &str = "spotify:start-group:";
const END_GROUP: &str = "spotify:end-group:";
/// Form encoding keeps only the unreserved characters; spaces become `+`.
const FOLDER_NAME: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PlaylistError {
    #[error("not a playlist URI: {uri}")]
    InvalidUri { uri: String },
    #[error("playlist request failed: {message}")]
    Request { message: String },
    #[error("the playlist changed since it was loaded")]
    Conflict,
    #[error("malformed playlist revision")]
    InvalidRevision,
    #[error("a playlist name cannot be empty")]
    InvalidName,
    #[error("the picture must be a JPEG of at most 256 KiB")]
    InvalidImage,
    #[error("not in your library: {uri}")]
    NotInRootlist { uri: String },
    #[error("not a username: {username}")]
    InvalidUsername { username: String },
}

impl From<librespot_core::Error> for PlaylistError {
    fn from(e: librespot_core::Error) -> Self {
        // Only the HTTP status: FailedPrecondition also covers local parse errors.
        let conflict = matches!(
            e.error.downcast_ref::<HttpClientError>(),
            Some(HttpClientError::StatusCode(
                StatusCode::CONFLICT | StatusCode::PRECONDITION_FAILED
            ))
        );
        if conflict {
            return Self::Conflict;
        }
        Self::Request {
            message: e.to_string(),
        }
    }
}

impl From<protobuf::Error> for PlaylistError {
    fn from(e: protobuf::Error) -> Self {
        Self::Request {
            message: format!("malformed playlist response: {e}"),
        }
    }
}

/// One root list row in server order. `parent` is the URI of the enclosing
/// folder, `None` at the top level.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum RootlistEntry {
    Folder {
        uri: String,
        name: String,
        parent: Option<String>,
    },
    Playlist {
        uri: String,
        name: String,
        owner: String,
        track_count: u32,
        parent: Option<String>,
        /// Owned by the user or collaborative.
        #[serde(default)]
        editable: bool,
        #[serde(default)]
        public: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct PlaylistTrack {
    pub uri: String,
    pub added_by: String,
    /// Unix seconds, 0 when unknown.
    pub added_at: i64,
}

/// One window of a playlist. Pages from different `revision`s may not line
/// up, so restart from offset 0 when it changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct PlaylistPage {
    pub uri: String,
    pub revision: String,
    pub name: String,
    pub description: String,
    /// The owner's username, which is an account id for most users.
    pub owner: String,
    /// The owner's display name; `owner` when it can't be looked up.
    #[serde(default)]
    pub owner_name: String,
    pub collaborative: bool,
    /// Owned by the user or collaborative.
    #[serde(default)]
    pub editable: bool,
    /// Spotify's playlist mirror of the user's Liked Songs, which recents list in its place.
    #[serde(default)]
    #[uniffi(default = false)]
    pub liked_songs: bool,
    /// Smallest first; empty when the playlist has no picture.
    pub artwork: Vec<Artwork>,
    pub total: u32,
    pub offset: u32,
    pub tracks: Vec<PlaylistTrack>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PlaylistChange {
    Rootlist,
    Playlist {
        uri: String,
    },
    /// A reconnect replaced the session and a push may have been missed.
    Resync,
}

/// A user's public profile, as anyone signed in can see it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UserProfile {
    pub username: String,
    /// The display name; `username` when the profile has none.
    pub name: String,
    pub artwork: Vec<Artwork>,
    pub followers: u64,
    /// Public playlists in the order the profile shows them.
    pub playlists: Vec<ProfileItem>,
    /// Users and artists they follow; empty when they keep it private.
    pub following: Vec<ProfileItem>,
}

/// A playlist, user or artist on a profile; `uri` is always one of those kinds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProfileItem {
    pub uri: String,
    pub name: String,
    pub artwork: Vec<Artwork>,
}

#[derive(uniffi::Object)]
pub struct PlaylistService {
    session: Arc<SpotSession>,
    store: Option<Arc<MetadataStore>>,
    push: PushWatch,
    /// Display names by username; they rarely change, so one lookup per run.
    owner_names: Mutex<HashMap<String, String>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl PlaylistService {
    #[uniffi::constructor]
    pub fn new(session: Arc<SpotSession>, store: Option<Arc<MetadataStore>>) -> Arc<Self> {
        Arc::new(Self {
            session,
            store,
            push: PushWatch::new(PUSH_URI),
            owner_names: Mutex::default(),
        })
    }

    /// The stored root list from the last `rootlist` call, empty when none.
    pub fn cached_rootlist(&self) -> Vec<RootlistEntry> {
        let username = self.session.current_session().username();
        self.store
            .as_ref()
            .and_then(|store| store.rootlist(&username))
            .unwrap_or_default()
    }

    /// The whole root list, folders included, in server order.
    pub async fn rootlist(&self) -> Result<Vec<RootlistEntry>, PlaylistError> {
        let generation = self.generation();
        let session = self.session.current_session();
        let raw = raw_rootlist(&session).await?;
        let username = session.username();
        let entries = rootlist_entries(&username, &raw.items, &raw.metas);
        let Some(store) = self.store.clone() else {
            return Ok(entries);
        };
        Ok(blocking(move || {
            store.put_rootlist(generation, &username, &entries);
            entries
        })
        .await)
    }

    /// The stored window when every track in it is stored, without a request.
    pub fn cached_page(&self, uri: String, from: u32, length: u32) -> Option<PlaylistPage> {
        cached_page(self.store.as_deref()?, uri, from, length)
    }

    /// Up to `length` tracks starting at `from`, with the list's attributes.
    pub async fn page(
        &self,
        uri: String,
        from: u32,
        length: u32,
    ) -> Result<PlaylistPage, PlaylistError> {
        let id = playlist_id(&uri)?;
        let generation = self.generation();
        let session = self.session.current_session();
        let endpoint = format!("/playlist/v2/playlist/{id}?from={from}&length={length}");
        let bytes = get(&session, &endpoint).await?;
        let content = SelectedListContent::parse_from_bytes(&bytes)?;
        let mut page = page_of(
            uri,
            &content,
            &image_url_template(&session),
            &session.username(),
        );
        page.owner_name = self.owner_name(&session, &page.owner).await;
        let Some(store) = self.store.clone() else {
            return Ok(page);
        };
        Ok(blocking(move || {
            persist_page(&store, generation, &page);
            page
        })
        .await)
    }

    pub async fn follower_count(&self, uri: String) -> Result<u64, PlaylistError> {
        let id = playlist_id(&uri)?;
        let session = self.session.current_session();
        let bytes = get(&session, &format!("/popcount/v2/playlist/{id}/count")).await?;
        Ok(decode_popcount(&bytes)?)
    }

    /// Appends tracks or episodes; returns the new revision.
    pub async fn add_tracks(
        &self,
        uri: String,
        track_uris: Vec<String>,
        revision: String,
    ) -> Result<String, PlaylistError> {
        validate_track_uris(&track_uris)?;
        self.change_playlist(&uri, &revision, add_op(None, &track_uris)?)
            .await
    }

    /// Removes the `track_uris` at `from..from + len`; the server checks they match.
    pub async fn remove_tracks(
        &self,
        uri: String,
        from: u32,
        track_uris: Vec<String>,
        revision: String,
    ) -> Result<String, PlaylistError> {
        validate_listed_uris(&track_uris)?;
        self.change_playlist(&uri, &revision, rem_op(from, &track_uris)?)
            .await
    }

    /// `to` is the index the block is inserted before, counted in the list
    /// before the move (`to == total` moves it to the end).
    pub async fn move_tracks(
        &self,
        uri: String,
        from: u32,
        length: u32,
        to: u32,
        revision: String,
    ) -> Result<String, PlaylistError> {
        self.change_playlist(&uri, &revision, mov_op(from, length, to)?)
            .await
    }

    /// Sets the name and description against the current revision; an empty
    /// description clears it.
    pub async fn update_details(
        &self,
        uri: String,
        name: String,
        description: String,
    ) -> Result<(), PlaylistError> {
        let name = valid_name(&name)?;
        let revision = self.current_revision(&uri).await?;
        self.change_playlist(&uri, &revision, details_op(name, &description))
            .await?;
        Ok(())
    }

    /// Uploads `jpeg` and makes it the playlist's cover.
    pub async fn set_picture(&self, uri: String, jpeg: Vec<u8>) -> Result<(), PlaylistError> {
        validate_jpeg(&jpeg)?;
        let id = playlist_id(&uri)?;
        let session = self.session.current_session();
        let reply = post(&session, IMAGE_UPLOAD_URL, "image/jpeg", jpeg).await?;
        let token = upload_token(&reply)?;
        let reply = spclient_post(
            &session,
            &format!("/playlist/v2/playlist/{id}/register-image"),
            register_request(token).write_to_bytes()?,
        )
        .await?;
        let picture = registered_picture(&reply)?;
        let revision = self.current_revision(&uri).await?;
        self.change_playlist(&uri, &revision, picture_op(picture))
            .await?;
        Ok(())
    }

    /// Creates a playlist at the top of the root list or of `folder`; returns its URI.
    pub async fn create_playlist(
        &self,
        name: String,
        description: String,
        folder: Option<String>,
    ) -> Result<String, PlaylistError> {
        let name = valid_name(&name)?;
        let session = self.session.current_session();
        let raw = raw_rootlist(&session).await?;
        let folder = folder.as_deref();
        insert_index(&raw.items, folder)?;
        let reply = spclient_post(
            &session,
            "/playlist/v2/playlist",
            create_request(name, &description).write_to_bytes()?,
        )
        .await?;
        let uri = CreateListReply::parse_from_bytes(&reply)?.uri().to_owned();
        playlist_id(&uri)?;
        let added = std::slice::from_ref(&uri);
        let op = insert_op(&raw.items, folder, added)?;
        // The playlist exists now; one retry on a fresh root list keeps it from orphaning.
        if let Err(PlaylistError::Conflict) = send_rootlist(&session, raw.revision, op).await {
            let raw = raw_rootlist(&session).await?;
            let op = insert_op(&raw.items, folder, added)?;
            send_rootlist(&session, raw.revision, op).await?;
        }
        Ok(uri)
    }

    /// Creates a folder at the top of the root list or of `folder`; returns its URI.
    pub async fn create_folder(
        &self,
        name: String,
        folder: Option<String>,
    ) -> Result<String, PlaylistError> {
        let name = valid_name(&name)?;
        let session = self.session.current_session();
        let raw = raw_rootlist(&session).await?;
        let id = random_folder_id();
        let op = insert_op(&raw.items, folder.as_deref(), &folder_markers(&id, name))?;
        send_rootlist(&session, raw.revision, op).await?;
        Ok(format!("spotify:user:{}:folder:{id}", session.username()))
    }

    /// Adds the playlist to the top of the root list (follows it); a no-op when it's there already.
    pub async fn follow_playlist(&self, uri: String) -> Result<(), PlaylistError> {
        playlist_id(&uri)?;
        let session = self.session.current_session();
        let raw = raw_rootlist(&session).await?;
        if raw.items.iter().any(|item| item.uri() == uri) {
            return Ok(());
        }
        let op = insert_op(&raw.items, None, std::slice::from_ref(&uri))?;
        send_rootlist(&session, raw.revision, op).await
    }

    /// `username`'s public profile, or the signed-in user's when `None`; who they
    /// follow stays empty when it can't be read.
    pub async fn user_profile(
        &self,
        username: Option<String>,
    ) -> Result<UserProfile, PlaylistError> {
        let session = self.session.current_session();
        let username = username.unwrap_or_else(|| session.username());
        if !is_username(&username) {
            return Err(PlaylistError::InvalidUsername { username });
        }
        let spclient = session.spclient();
        let (profile, following) = tokio::join!(
            spclient.get_user_profile(&username, Some(PROFILE_PLAYLISTS), Some(0)),
            spclient.get_user_following(&username),
        );
        let following = following
            .inspect_err(|error| log::debug!("following lookup failed: {error}"))
            .ok();
        profile_of(&username, &profile?, following.as_deref())
    }

    /// Removes the playlist from the root list (unfollows it).
    pub async fn delete_playlist(&self, uri: String) -> Result<(), PlaylistError> {
        playlist_id(&uri)?;
        let session = self.session.current_session();
        let raw = raw_rootlist(&session).await?;
        let index = rootlist_index(&raw.items, &uri)?;
        let op = rem_op(index, std::slice::from_ref(&uri))?;
        send_rootlist(&session, raw.revision, op).await
    }

    pub async fn set_public(&self, uri: String, public: bool) -> Result<(), PlaylistError> {
        playlist_id(&uri)?;
        let session = self.session.current_session();
        let raw = raw_rootlist(&session).await?;
        let index = rootlist_index(&raw.items, &uri)?;
        send_rootlist(&session, raw.revision, public_op(index, &uri, public)?).await
    }

    /// Returns at the next root list or playlist change pushed by the dealer.
    pub async fn wait_for_change(&self) -> PlaylistChange {
        loop {
            let Some(message) = self.push.next(&self.session).await else {
                return PlaylistChange::Resync;
            };
            if let Some(change) = change_of(&message.uri) {
                return change;
            }
        }
    }
}

impl PlaylistService {
    /// Falls back to the username when the profile can't be read; a failure isn't remembered.
    async fn owner_name(&self, session: &Session, owner: &str) -> String {
        if let Some(name) = lock(&self.owner_names).get(owner) {
            return name.clone();
        }
        if !is_username(owner) {
            return owner.to_owned();
        }
        let name = match session
            .spclient()
            .get_user_profile(owner, Some(0), Some(0))
            .await
        {
            Ok(bytes) => profile_name(&bytes),
            Err(error) => {
                log::debug!("owner profile lookup failed: {error}");
                None
            }
        };
        match name {
            Some(name) => {
                lock(&self.owner_names).insert(owner.to_owned(), name.clone());
                name
            }
            None => owner.to_owned(),
        }
    }

    fn generation(&self) -> u64 {
        self.store.as_ref().map_or(0, |store| store.generation())
    }

    async fn current_revision(&self, uri: &str) -> Result<String, PlaylistError> {
        let id = playlist_id(uri)?;
        let session = self.session.current_session();
        let endpoint = format!("/playlist/v2/playlist/{id}?from=0&length=0");
        let bytes = get(&session, &endpoint).await?;
        Ok(hex(
            SelectedListContent::parse_from_bytes(&bytes)?.revision()
        ))
    }

    async fn change_playlist(
        &self,
        uri: &str,
        revision: &str,
        op: Op,
    ) -> Result<String, PlaylistError> {
        let id = playlist_id(uri)?;
        let body = changes(revision_bytes(revision)?, op).write_to_bytes()?;
        let session = self.session.current_session();
        let reply = spclient_post(
            &session,
            &format!("/playlist/v2/playlist/{id}/changes"),
            body,
        )
        .await?;
        new_revision(&SelectedListContent::parse_from_bytes(&reply)?)
    }
}

/// The root list's raw items, group markers included, with its revision.
struct RawRootlist {
    revision: Vec<u8>,
    items: Vec<Item>,
    metas: Vec<MetaItem>,
}

async fn raw_rootlist(session: &Session) -> Result<RawRootlist, PlaylistError> {
    let mut raw = RawRootlist {
        revision: Vec::new(),
        items: Vec::new(),
        metas: Vec::new(),
    };
    loop {
        let bytes = session
            .spclient()
            .get_rootlist(raw.items.len(), Some(ROOTLIST_PAGE))
            .await?;
        let mut content = SelectedListContent::parse_from_bytes(&bytes)?;
        if raw.items.is_empty() {
            raw.revision = content.revision().to_vec();
        }
        let total = usize::try_from(content.length()).unwrap_or(0);
        let contents = content.contents.take().unwrap_or_default();
        let received = contents.items.len();
        let mut page_metas = contents.meta_items;
        page_metas.resize_with(received, MetaItem::default);
        raw.items.extend(contents.items);
        raw.metas.extend(page_metas);
        if received == 0 || raw.items.len() >= total {
            break;
        }
    }
    Ok(raw)
}

async fn send_rootlist(session: &Session, revision: Vec<u8>, op: Op) -> Result<(), PlaylistError> {
    let endpoint = format!("/playlist/v2/user/{}/rootlist/changes", session.username());
    spclient_post(session, &endpoint, changes(revision, op).write_to_bytes()?).await?;
    Ok(())
}

async fn spclient_post(
    session: &Session,
    endpoint: &str,
    body: Vec<u8>,
) -> Result<Vec<u8>, PlaylistError> {
    let url = format!("{}{endpoint}", session.spclient().base_url().await?);
    post(session, &url, "application/x-protobuf", body).await
}

/// One try only: spclient retries up to 10 times on timeouts and 5xx, which
/// could resend a write the server already applied.
async fn post(
    session: &Session,
    url: &str,
    content_type: &'static str,
    body: Vec<u8>,
) -> Result<Vec<u8>, PlaylistError> {
    let spclient = session.spclient();
    let token = session.login5().auth_token().await?;
    let authorization =
        HeaderValue::try_from(format!("{} {}", token.token_type, token.access_token)).map_err(
            |_| PlaylistError::Request {
                message: "malformed access token".into(),
            },
        )?;
    let mut request = Request::builder()
        .method(Method::POST)
        .uri(url)
        .header(CONTENT_TYPE, content_type)
        .header(CONTENT_LENGTH, body.len())
        .body(body.into())
        .map_err(|e| PlaylistError::Request {
            message: e.to_string(),
        })?;
    let headers = request.headers_mut();
    headers.insert(AUTHORIZATION, authorization);
    // spclient also goes on without a client token when it cannot get one.
    if let Some(value) = spclient
        .client_token()
        .await
        .ok()
        .and_then(|token| HeaderValue::try_from(token).ok())
    {
        headers.insert("client-token", value);
    }
    Ok(session.http_client().request_body(request).await?.to_vec())
}

fn changes(base_revision: Vec<u8>, op: Op) -> ListChanges {
    let mut changes = ListChanges::new();
    changes.set_base_revision(base_revision);
    changes.set_want_resulting_revisions(true);
    let mut delta = Delta::new();
    delta.ops.push(op);
    changes.deltas.push(delta);
    changes
}

fn items(uris: &[String]) -> Vec<Item> {
    uris.iter()
        .map(|uri| {
            let mut item = Item::new();
            item.set_uri(uri.clone());
            item
        })
        .collect()
}

/// The wire format's indexes are `i32`; a larger one addresses no real list.
fn wire_index(value: impl TryInto<i32>) -> Result<i32, PlaylistError> {
    value.try_into().map_err(|_| PlaylistError::Request {
        message: "playlist index out of range".to_owned(),
    })
}

/// Appends when `index` is None, otherwise inserts before raw index `index`.
fn add_op(index: Option<usize>, uris: &[String]) -> Result<Op, PlaylistError> {
    let mut add = Add::new();
    match index {
        Some(index) => add.set_from_index(wire_index(index)?),
        None => add.set_add_last(true),
    }
    add.items = items(uris);
    let mut op = Op::new();
    op.set_kind(Kind::ADD);
    op.add = Some(add).into();
    Ok(op)
}

fn rem_op(from: impl TryInto<i32>, uris: &[String]) -> Result<Op, PlaylistError> {
    let mut rem = Rem::new();
    rem.set_from_index(wire_index(from)?);
    rem.set_length(wire_index(uris.len())?);
    rem.items = items(uris);
    let mut op = Op::new();
    op.set_kind(Kind::REM);
    op.rem = Some(rem).into();
    Ok(op)
}

fn mov_op(from: u32, length: u32, to: u32) -> Result<Op, PlaylistError> {
    let mut mov = Mov::new();
    mov.set_from_index(wire_index(from)?);
    mov.set_length(wire_index(length)?);
    mov.set_to_index(wire_index(to)?);
    let mut op = Op::new();
    op.set_kind(Kind::MOV);
    op.mov = Some(mov).into();
    Ok(op)
}

fn details_op(name: &str, description: &str) -> Op {
    let mut update = UpdateListAttributes::new();
    let state = update.new_attributes.mut_or_insert_default();
    let values = state.values.mut_or_insert_default();
    values.set_name(name.to_owned());
    if description.is_empty() {
        state
            .no_value
            .push(ListAttributeKind::LIST_DESCRIPTION.into());
    } else {
        values.set_description(description.to_owned());
    }
    let mut op = Op::new();
    op.set_kind(Kind::UPDATE_LIST_ATTRIBUTES);
    op.update_list_attributes = Some(update).into();
    op
}

fn public_op(index: usize, uri: &str, public: bool) -> Result<Op, PlaylistError> {
    let mut update = UpdateItemAttributes::new();
    update.set_index(wire_index(index)?);
    update.item = items(&[uri.to_owned()]).pop().into();
    let mut values = ItemAttributes::new();
    values.set_public(public);
    update.new_attributes.mut_or_insert_default().values = Some(values).into();
    let mut op = Op::new();
    op.set_kind(Kind::UPDATE_ITEM_ATTRIBUTES);
    op.update_item_attributes = Some(update).into();
    Ok(op)
}

fn create_request(name: &str, description: &str) -> ListUpdateRequest {
    let mut attributes = ListAttributes::new();
    attributes.set_name(name.to_owned());
    let description = description.trim();
    if !description.is_empty() {
        attributes.set_description(description.to_owned());
    }
    let mut request = ListUpdateRequest::new();
    request.attributes = Some(attributes).into();
    request
}

fn picture_op(picture: Vec<u8>) -> Op {
    let mut update = UpdateListAttributes::new();
    update
        .new_attributes
        .mut_or_insert_default()
        .values
        .mut_or_insert_default()
        .set_picture(picture);
    let mut op = Op::new();
    op.set_kind(Kind::UPDATE_LIST_ATTRIBUTES);
    op.update_list_attributes = Some(update).into();
    op
}

fn validate_jpeg(jpeg: &[u8]) -> Result<(), PlaylistError> {
    let valid = jpeg.starts_with(&[0xFF, 0xD8, 0xFF]) && jpeg.len() <= MAX_PICTURE_BYTES;
    valid.then_some(()).ok_or(PlaylistError::InvalidImage)
}

/// No Debug, so the token cannot end up in a log.
#[derive(Deserialize)]
struct UploadReply {
    #[serde(rename = "uploadToken")]
    upload_token: String,
}

/// The message never echoes the reply, which carries the upload token.
fn upload_token(reply: &[u8]) -> Result<String, PlaylistError> {
    serde_json::from_slice::<UploadReply>(reply)
        .ok()
        .map(|reply| reply.upload_token)
        .filter(|token| !token.is_empty())
        .ok_or_else(|| PlaylistError::Request {
            message: "malformed image upload reply".into(),
        })
}

fn register_request(upload_token: String) -> RegisterPlaylistImageRequest {
    let mut request = RegisterPlaylistImageRequest::new();
    request.set_upload_token(upload_token);
    request
}

fn registered_picture(reply: &[u8]) -> Result<Vec<u8>, PlaylistError> {
    let picture = RegisterPlaylistImageResponse::parse_from_bytes(reply)?
        .picture
        .unwrap_or_default();
    if picture.is_empty() {
        return Err(PlaylistError::Request {
            message: "image registration returned no picture".into(),
        });
    }
    Ok(picture)
}

/// The last resulting revision, else the reply's own revision.
fn new_revision(reply: &SelectedListContent) -> Result<String, PlaylistError> {
    let revision = reply
        .resulting_revisions
        .last()
        .map(Vec::as_slice)
        .unwrap_or(reply.revision());
    if revision.is_empty() {
        return Err(PlaylistError::Request {
            message: "change reply carried no revision".into(),
        });
    }
    Ok(hex(revision))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn revision_bytes(revision: &str) -> Result<Vec<u8>, PlaylistError> {
    if revision.is_empty() || revision.len() % 2 != 0 {
        return Err(PlaylistError::InvalidRevision);
    }
    (0..revision.len())
        .step_by(2)
        .map(|i| {
            revision
                .get(i..i + 2)
                .filter(|pair| pair.bytes().all(|b| b.is_ascii_hexdigit()))
                .and_then(|pair| u8::from_str_radix(pair, 16).ok())
                .ok_or(PlaylistError::InvalidRevision)
        })
        .collect()
}

fn validate_track_uris(uris: &[String]) -> Result<(), PlaylistError> {
    uris.iter().try_for_each(|uri| validate_track_uri(uri))
}

/// Looser than `validate_track_uri`: a removal names rows a page listed,
/// local files (`spotify:local:...`) included.
fn validate_listed_uris(uris: &[String]) -> Result<(), PlaylistError> {
    uris.iter().try_for_each(|uri| {
        let listed = uri.starts_with("spotify:")
            && uri.len() <= MAX_LISTED_URI
            && !uri.chars().any(char::is_control);
        listed
            .then_some(())
            .ok_or_else(|| PlaylistError::InvalidUri {
                uri: uri.to_owned(),
            })
    })
}

fn validate_track_uri(uri: &str) -> Result<(), PlaylistError> {
    let valid = ["spotify:track:", "spotify:episode:"]
        .iter()
        .filter_map(|prefix| uri.strip_prefix(prefix))
        .any(|id| id.len() == 22 && id.bytes().all(|b| b.is_ascii_alphanumeric()));
    valid
        .then_some(())
        .ok_or_else(|| PlaylistError::InvalidUri {
            uri: uri.to_owned(),
        })
}

fn valid_name(name: &str) -> Result<&str, PlaylistError> {
    let name = name.trim();
    (!name.is_empty())
        .then_some(name)
        .ok_or(PlaylistError::InvalidName)
}

/// `spotify:user:<username>:folder:<id>` as produced by `rootlist_entries`.
fn folder_id(uri: &str) -> Option<&str> {
    uri.strip_prefix("spotify:user:")?
        .rsplit_once(":folder:")
        .map(|(_, id)| id)
}

/// Raw item index, group markers counted; a folder is found by its start marker.
fn rootlist_index(items: &[Item], uri: &str) -> Result<usize, PlaylistError> {
    let folder = folder_id(uri);
    items
        .iter()
        .position(|item| match folder {
            Some(id) => item
                .uri()
                .strip_prefix(START_GROUP)
                .is_some_and(|rest| rest.split(':').next() == Some(id)),
            None => item.uri() == uri,
        })
        .ok_or_else(|| PlaylistError::NotInRootlist {
            uri: uri.to_owned(),
        })
}

/// The top of the root list, or just inside `folder`'s start marker.
fn insert_index(items: &[Item], folder: Option<&str>) -> Result<usize, PlaylistError> {
    let Some(folder) = folder else {
        return Ok(0);
    };
    if folder_id(folder).is_none() {
        return Err(PlaylistError::NotInRootlist {
            uri: folder.to_owned(),
        });
    }
    Ok(rootlist_index(items, folder)? + 1)
}

fn insert_op(items: &[Item], folder: Option<&str>, uris: &[String]) -> Result<Op, PlaylistError> {
    add_op(Some(insert_index(items, folder)?), uris)
}

fn folder_markers(id: &str, name: &str) -> [String; 2] {
    let encoded = name
        .split(' ')
        .map(|word| utf8_percent_encode(word, FOLDER_NAME).to_string())
        .collect::<Vec<_>>()
        .join("+");
    [
        format!("{START_GROUP}{id}:{encoded}"),
        format!("{END_GROUP}{id}"),
    ]
}

/// 16 hex chars; uniqueness within one root list is all that is needed.
fn random_folder_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("{:016x}", RandomState::new().hash_one(nanos))
}

/// Stores the attributes as a page without tracks; tracks go in by position.
fn persist_page(store: &MetadataStore, generation: u64, page: &PlaylistPage) {
    let attributes = PlaylistPage {
        offset: 0,
        tracks: Vec::new(),
        ..page.clone()
    };
    store.put_playlist(
        generation,
        &page.uri,
        &page.revision,
        &attributes,
        page.offset,
        &page.tracks,
    );
}

/// Some only when the playlist is stored with every position in
/// `[from, min(from + length, total))`.
fn cached_page(store: &MetadataStore, uri: String, from: u32, length: u32) -> Option<PlaylistPage> {
    let (mut attributes, tracks): (PlaylistPage, Vec<(u32, PlaylistTrack)>) =
        store.playlist(&uri, from..from.saturating_add(length))?;
    // Pages stored before display names have none.
    if attributes.owner_name.is_empty() {
        attributes.owner_name = attributes.owner.clone();
    }
    let end = from.saturating_add(length).min(attributes.total);
    // Positions are unique and in range, so a full count means no gaps.
    let tracks: Vec<_> = tracks
        .into_iter()
        .filter(|(position, _)| *position < end)
        .map(|(_, track)| track)
        .collect();
    (u32::try_from(tracks.len()).ok() == Some(end.saturating_sub(from))).then_some(PlaylistPage {
        offset: from,
        tracks,
        ..attributes
    })
}

async fn get(session: &Session, endpoint: &str) -> Result<Vec<u8>, PlaylistError> {
    let response = session
        .spclient()
        .request(&Method::GET, endpoint, None, None)
        .await?;
    Ok(response.to_vec())
}

/// Usernames land in a path; real ones are ids or legacy names of these characters.
fn is_username(owner: &str) -> bool {
    !owner.is_empty()
        && owner
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// The `name` of a `user-profile-view` response, when present and not blank.
fn profile_name(json: &[u8]) -> Option<String> {
    #[derive(Deserialize)]
    struct Profile {
        name: Option<String>,
    }
    let name = serde_json::from_slice::<Profile>(json).ok()?.name?;
    let name = name.trim();
    (!name.is_empty()).then(|| name.to_owned())
}

#[derive(Deserialize)]
struct ProfileJson {
    name: Option<String>,
    image_url: Option<String>,
    #[serde(default)]
    followers_count: u64,
    #[serde(default)]
    public_playlists: Vec<ProfileItemJson>,
}

#[derive(Deserialize)]
struct FollowingJson {
    #[serde(default)]
    profiles: Vec<ProfileItemJson>,
}

#[derive(Deserialize)]
struct ProfileItemJson {
    uri: String,
    name: Option<String>,
    image_url: Option<String>,
}

/// Untrusted JSON: rows whose URI isn't a playlist, user or artist the app can open are dropped.
fn profile_of(
    username: &str,
    profile: &[u8],
    following: Option<&[u8]>,
) -> Result<UserProfile, PlaylistError> {
    let profile: ProfileJson =
        serde_json::from_slice(profile).map_err(|e| PlaylistError::Request {
            message: format!("malformed profile: {e}"),
        })?;
    let following = following
        .and_then(|json| serde_json::from_slice::<FollowingJson>(json).ok())
        .map(|json| json.profiles)
        .unwrap_or_default();
    let items = |rows: Vec<ProfileItemJson>, opens: fn(&str) -> bool| {
        rows.into_iter()
            .filter(|row| opens(&row.uri))
            .map(|row| ProfileItem {
                name: row.name.unwrap_or_default(),
                artwork: profile_artwork(row.image_url),
                uri: row.uri,
            })
            .collect()
    };
    Ok(UserProfile {
        username: username.to_owned(),
        name: profile
            .name
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| username.to_owned()),
        artwork: profile_artwork(profile.image_url),
        followers: profile.followers_count,
        playlists: items(profile.public_playlists, |uri| playlist_id(uri).is_ok()),
        following: items(following, |uri| {
            uri.strip_prefix("spotify:user:").is_some_and(is_username)
                || uri.strip_prefix("spotify:artist:").is_some_and(|id| {
                    id.len() == 22 && id.bytes().all(|b| b.is_ascii_alphanumeric())
                })
        }),
    })
}

/// Only web images load; profiles also carry `spotify:` image URIs.
fn profile_artwork(url: Option<String>) -> Vec<Artwork> {
    url.filter(|url| url.starts_with("https://"))
        .map(|url| Artwork {
            url,
            size: ArtworkSize::Default,
            width: 0,
            height: 0,
        })
        .into_iter()
        .collect()
}

/// Rejects anything that is not a bare base62 id, since it lands in a path.
fn playlist_id(uri: &str) -> Result<&str, PlaylistError> {
    uri.strip_prefix(PLAYLIST_PREFIX)
        .filter(|id| id.len() == 22 && id.bytes().all(|b| b.is_ascii_alphanumeric()))
        .ok_or_else(|| PlaylistError::InvalidUri {
            uri: uri.to_owned(),
        })
}

/// Folders arrive as `spotify:start-group:<id>:<url-encoded name>` ...
/// `spotify:end-group:<id>` brackets around their contents.
fn rootlist_entries(username: &str, items: &[Item], metas: &[MetaItem]) -> Vec<RootlistEntry> {
    let mut entries = Vec::new();
    let mut folders: Vec<String> = Vec::new();
    for (item, meta) in items.iter().zip(metas) {
        let uri = item.uri();
        if let Some(rest) = uri.strip_prefix(START_GROUP) {
            let (id, name) = rest.split_once(':').unwrap_or((rest, ""));
            let folder = format!("spotify:user:{username}:folder:{id}");
            entries.push(RootlistEntry::Folder {
                uri: folder.clone(),
                name: decode_folder_name(name),
                parent: folders.last().cloned(),
            });
            folders.push(folder);
        } else if uri.starts_with(END_GROUP) {
            folders.pop();
        } else if uri.starts_with(PLAYLIST_PREFIX) {
            let owner = meta.owner_username();
            entries.push(RootlistEntry::Playlist {
                uri: uri.to_owned(),
                name: meta.attributes.name().to_owned(),
                owner: owner.to_owned(),
                track_count: u32::try_from(meta.length()).unwrap_or(0),
                parent: folders.last().cloned(),
                editable: owner == username || meta.attributes.collaborative(),
                public: item.attributes.public(),
            });
        }
    }
    entries
}

/// Form encoding: `+` is a space; a literal `+` arrives as `%2B`.
fn decode_folder_name(name: &str) -> String {
    percent_decode_str(&name.replace('+', " "))
        .decode_utf8_lossy()
        .into_owned()
}

const LIKED_SONGS_FORMAT: &str = "liked-songs";

fn page_of(
    uri: String,
    content: &SelectedListContent,
    image_url: &str,
    username: &str,
) -> PlaylistPage {
    let attributes = &content.attributes;
    let contents = &content.contents;
    PlaylistPage {
        uri,
        revision: hex(content.revision()),
        name: attributes.name().to_owned(),
        description: attributes.description().to_owned(),
        owner: content.owner_username().to_owned(),
        owner_name: content.owner_username().to_owned(),
        collaborative: attributes.collaborative(),
        editable: content.owner_username() == username || attributes.collaborative(),
        liked_songs: attributes.format() == LIKED_SONGS_FORMAT,
        artwork: artwork(attributes.picture(), &attributes.picture_size, image_url),
        total: u32::try_from(content.length()).unwrap_or(0),
        offset: u32::try_from(contents.pos()).unwrap_or(0),
        tracks: contents
            .items
            .iter()
            .map(|item| PlaylistTrack {
                uri: item.uri().to_owned(),
                added_by: item.attributes.added_by().to_owned(),
                added_at: item.attributes.timestamp() / 1000,
            })
            .collect(),
    }
}

/// Spotify-made and mosaic covers come as sized URLs; uploaded covers only
/// as a picture file id.
fn artwork(
    picture: &[u8],
    sizes: &[librespot_protocol::playlist4_external::PictureSize],
    image_url: &str,
) -> Vec<Artwork> {
    let sized: Vec<Artwork> = [
        ("small", ArtworkSize::Small),
        ("default", ArtworkSize::Default),
        ("large", ArtworkSize::Large),
        ("xlarge", ArtworkSize::XLarge),
    ]
    .into_iter()
    .filter_map(|(target, size)| {
        let found = sizes.iter().find(|s| s.target_name() == target)?;
        Some(Artwork {
            url: found.url().to_owned(),
            size,
            width: 0,
            height: 0,
        })
    })
    .collect();
    if !sized.is_empty() || picture.is_empty() {
        return sized;
    }
    vec![Artwork {
        url: image_url.replace("{file_id}", &hex(picture)),
        size: ArtworkSize::Default,
        width: 0,
        height: 0,
    }]
}

fn change_of(push_uri: &str) -> Option<PlaylistChange> {
    let path = push_uri.strip_prefix("hm://playlist/v2/")?;
    if let Some(id) = path.strip_prefix("playlist/") {
        let id = id.split(['/', '?']).next().unwrap_or_default();
        return (!id.is_empty()).then(|| PlaylistChange::Playlist {
            uri: format!("{PLAYLIST_PREFIX}{id}"),
        });
    }
    (path.starts_with("user/") && path.ends_with("/rootlist")).then_some(PlaylistChange::Rootlist)
}

/// `PopcountResult.count` is field 1, a zigzag `sint64`.
fn decode_popcount(bytes: &[u8]) -> protobuf::Result<u64> {
    let mut count = 0;
    decode_fields(bytes, |number, is| {
        if number != 1 {
            return Ok(false);
        }
        count = is.read_sint64()?;
        Ok(true)
    })?;
    Ok(u64::try_from(count).unwrap_or(0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_protocol::playlist4_external::{ListItems, PictureSize};

    const ID: &str = "37i9dQZF1DXcBWIGoYBM5M";

    fn item(uri: &str) -> Item {
        let mut item = Item::new();
        item.set_uri(uri.to_owned());
        item
    }

    fn meta(name: &str, owner: &str, length: i32) -> MetaItem {
        let mut meta = MetaItem::new();
        meta.attributes
            .mut_or_insert_default()
            .set_name(name.to_owned());
        meta.set_owner_username(owner.to_owned());
        meta.set_length(length);
        meta
    }

    #[test]
    fn rootlist_nests_playlists_under_folders() {
        let uris = [
            format!("spotify:playlist:{ID}"),
            "spotify:start-group:aa:Road+trips%2B".to_owned(),
            "spotify:playlist:p2".to_owned(),
            "spotify:start-group:bb:Inner".to_owned(),
            "spotify:end-group:bb".to_owned(),
            "spotify:end-group:aa".to_owned(),
            "spotify:collection".to_owned(),
        ];
        let items: Vec<Item> = uris.iter().map(|u| item(u)).collect();
        let metas = vec![
            meta("Top", "me", 3),
            MetaItem::new(),
            meta("Nested", "friend", 9),
            MetaItem::new(),
            MetaItem::new(),
            MetaItem::new(),
            MetaItem::new(),
        ];
        let outer = "spotify:user:me:folder:aa".to_owned();
        assert_eq!(
            rootlist_entries("me", &items, &metas),
            vec![
                RootlistEntry::Playlist {
                    uri: format!("spotify:playlist:{ID}"),
                    name: "Top".into(),
                    owner: "me".into(),
                    track_count: 3,
                    parent: None,
                    editable: true,
                    public: false,
                },
                RootlistEntry::Folder {
                    uri: outer.clone(),
                    name: "Road trips+".into(),
                    parent: None,
                },
                RootlistEntry::Playlist {
                    uri: "spotify:playlist:p2".into(),
                    name: "Nested".into(),
                    owner: "friend".into(),
                    track_count: 9,
                    parent: Some(outer.clone()),
                    editable: false,
                    public: false,
                },
                RootlistEntry::Folder {
                    uri: "spotify:user:me:folder:bb".into(),
                    name: "Inner".into(),
                    parent: Some(outer),
                },
            ]
        );
    }

    #[test]
    fn stray_end_group_does_not_panic() {
        let items = [item("spotify:end-group:zz"), item("spotify:playlist:p")];
        let entries = rootlist_entries("me", &items, &[MetaItem::new(), MetaItem::new()]);
        assert!(matches!(
            &entries[..],
            [RootlistEntry::Playlist { parent: None, .. }]
        ));
    }

    #[test]
    fn liked_songs_mirror_is_flagged_by_its_format() {
        let mut content = SelectedListContent::new();
        content
            .attributes
            .mut_or_insert_default()
            .set_format(LIKED_SONGS_FORMAT.into());
        assert!(page_of("u".into(), &content, "", "me").liked_songs);
    }

    #[test]
    fn page_maps_attributes_window_and_tracks() {
        let mut content = SelectedListContent::new();
        content.set_revision(vec![0x01, 0xab]);
        content.set_length(250);
        content.set_owner_username("spotify".into());
        let attributes = content.attributes.mut_or_insert_default();
        attributes.set_name("Hits".into());
        attributes.set_description("Big ones".into());
        let mut contents = ListItems::new();
        contents.set_pos(100);
        contents.set_truncated(true);
        let mut track = item("spotify:track:t1");
        let attrs = track.attributes.mut_or_insert_default();
        attrs.set_added_by("alice".into());
        attrs.set_timestamp(1_700_000_000_123);
        contents.items.push(track);
        content.contents = Some(contents).into();

        let bytes = content.write_to_bytes().unwrap();
        let decoded = SelectedListContent::parse_from_bytes(&bytes).unwrap();
        let page = page_of("spotify:playlist:x".into(), &decoded, "u/{file_id}", "me");
        assert_eq!(page.revision, "01ab");
        assert_eq!(
            (page.name.as_str(), page.description.as_str()),
            ("Hits", "Big ones")
        );
        assert_eq!(
            (page.owner.as_str(), page.total, page.offset),
            ("spotify", 250, 100)
        );
        assert!(page.artwork.is_empty());
        assert!(!page.liked_songs);
        assert_eq!(
            page.tracks,
            vec![PlaylistTrack {
                uri: "spotify:track:t1".into(),
                added_by: "alice".into(),
                added_at: 1_700_000_000,
            }]
        );
    }

    #[test]
    fn artwork_prefers_sized_urls_then_picture_id() {
        let mut large = PictureSize::new();
        large.set_target_name("large".into());
        large.set_url("https://mosaic/640".into());
        let mut small = PictureSize::new();
        small.set_target_name("small".into());
        small.set_url("https://mosaic/60".into());
        let sized = artwork(&[0xff], &[large, small], "u/{file_id}");
        assert_eq!(
            sized
                .iter()
                .map(|a| (a.url.as_str(), a.size))
                .collect::<Vec<_>>(),
            vec![
                ("https://mosaic/60", ArtworkSize::Small),
                ("https://mosaic/640", ArtworkSize::Large)
            ]
        );
        assert_eq!(artwork(&[0x0f, 0xa0], &[], "u/{file_id}")[0].url, "u/0fa0");
    }

    #[test]
    fn playlist_ids_must_be_base62() {
        assert_eq!(playlist_id(&format!("spotify:playlist:{ID}")).unwrap(), ID);
        for bad in [
            "spotify:album:37i9dQZF1DXcBWIGoYBM5M",
            "spotify:playlist:../../user/x/rootlist",
            "spotify:playlist:short",
        ] {
            assert!(matches!(
                playlist_id(bad),
                Err(PlaylistError::InvalidUri { .. })
            ));
        }
    }

    #[test]
    fn push_uris_map_to_changes() {
        assert_eq!(
            change_of(&format!("hm://playlist/v2/playlist/{ID}")),
            Some(PlaylistChange::Playlist {
                uri: format!("spotify:playlist:{ID}")
            })
        );
        assert_eq!(
            change_of("hm://playlist/v2/user/me/rootlist"),
            Some(PlaylistChange::Rootlist)
        );
        assert_eq!(change_of("hm://playlist/v2/other"), None);
        assert_eq!(change_of("hm://collection/x"), None);
    }

    #[test]
    fn popcount_reads_zigzag_count_and_skips_other_fields() {
        let mut bytes = Vec::new();
        let mut out = protobuf::CodedOutputStream::vec(&mut bytes);
        out.write_string(3, "someone").unwrap();
        out.write_sint64(1, 1234).unwrap();
        out.write_bool(2, false).unwrap();
        out.flush().unwrap();
        drop(out);
        assert_eq!(decode_popcount(&bytes).unwrap(), 1234);
        assert!(decode_popcount(&[0x08]).is_err());
    }

    #[test]
    fn profile_name_reads_a_non_blank_name() {
        assert_eq!(
            profile_name(br#"{"uri":"spotify:user:31abc","name":"Jakub"}"#).as_deref(),
            Some("Jakub")
        );
        assert_eq!(profile_name(br#"{"name":"  "}"#), None);
        assert_eq!(profile_name(br#"{"uri":"spotify:user:31abc"}"#), None);
        assert_eq!(profile_name(b"not json"), None);
    }

    #[test]
    fn profile_keeps_openable_rows_and_survives_hidden_following() {
        let profile = br#"{"uri":"spotify:user:friend","name":"Friend","image_url":"https://i.scdn.co/image/a",
            "followers_count":7,"public_playlists":[
                {"uri":"spotify:playlist:0123456789abcdefghijkl","name":"Mix","image_url":"spotify:mosaic:x"},
                {"uri":"spotify:playlist:../../x","name":"Bad"}]}"#;
        let following = br#"{"profiles":[
            {"uri":"spotify:user:pal","name":"Pal"},
            {"uri":"spotify:artist:0123456789abcdefghijkl","name":"Band"},
            {"uri":"spotify:user:a/b","name":"Bad"},
            {"uri":"spotify:show:0123456789abcdefghijkl","name":"Show"}]}"#;

        let user = profile_of("friend", profile, Some(following)).unwrap();
        assert_eq!((user.name.as_str(), user.followers), ("Friend", 7));
        assert_eq!(user.artwork.len(), 1);
        let uris = |items: &[ProfileItem]| items.iter().map(|i| i.uri.clone()).collect::<Vec<_>>();
        assert_eq!(
            uris(&user.playlists),
            ["spotify:playlist:0123456789abcdefghijkl"]
        );
        assert!(
            user.playlists[0].artwork.is_empty(),
            "spotify: images don't load"
        );
        assert_eq!(
            uris(&user.following),
            ["spotify:user:pal", "spotify:artist:0123456789abcdefghijkl"]
        );

        let hidden = profile_of("friend", br#"{"name":" "}"#, Some(b"forbidden")).unwrap();
        assert_eq!(hidden.name, "friend");
        assert!(hidden.following.is_empty() && hidden.playlists.is_empty());
        assert!(profile_of("friend", b"not json", None).is_err());
    }

    #[test]
    fn only_plain_usernames_are_looked_up() {
        for owner in ["31abcdefghijklmnopqrstuvwxyz", "spotify", "first.last_1-2"] {
            assert!(is_username(owner), "{owner}");
        }
        for owner in ["", "../me", "a/b", "a?b=c", "a b", "jos\u{e9}"] {
            assert!(!is_username(owner), "{owner}");
        }
    }

    fn stored_page(revision: &str, total: u32, offset: u32, uris: &[&str]) -> PlaylistPage {
        PlaylistPage {
            uri: format!("{PLAYLIST_PREFIX}{ID}"),
            revision: revision.into(),
            name: "List".into(),
            description: String::new(),
            owner: "o".into(),
            owner_name: "Owner".into(),
            collaborative: false,
            editable: false,
            liked_songs: false,
            artwork: Vec::new(),
            total,
            offset,
            tracks: uris
                .iter()
                .map(|uri| PlaylistTrack {
                    uri: (*uri).into(),
                    added_by: String::new(),
                    added_at: 0,
                })
                .collect(),
        }
    }

    #[test]
    fn cached_page_needs_every_position_up_to_total() {
        let store = crate::store::tests::temp_store("playlist-window");
        let uri = format!("{PLAYLIST_PREFIX}{ID}");
        assert_eq!(cached_page(&store, uri.clone(), 0, 2), None);

        persist_page(
            &store,
            store.generation(),
            &stored_page("r", 5, 0, &["a", "b"]),
        );
        persist_page(
            &store,
            store.generation(),
            &stored_page("r", 5, 3, &["d", "e"]),
        );

        let page = cached_page(&store, uri.clone(), 0, 2).unwrap();
        assert_eq!((page.offset, page.tracks.len()), (0, 2));
        assert_eq!(cached_page(&store, uri.clone(), 1, 2), None, "gap at 2");
        let tail = cached_page(&store, uri.clone(), 3, 10).unwrap();
        assert_eq!(tail, stored_page("r", 5, 3, &["d", "e"]));
        assert_eq!(cached_page(&store, uri, 5, 10).unwrap().tracks, vec![]);
    }

    #[test]
    fn page_stored_without_a_display_name_shows_the_username() {
        let store = crate::store::tests::temp_store("playlist-owner-name");
        let uri = format!("{PLAYLIST_PREFIX}{ID}");
        let old = PlaylistPage {
            owner_name: String::new(),
            ..stored_page("r", 1, 0, &["a"])
        };
        persist_page(&store, store.generation(), &old);

        assert_eq!(cached_page(&store, uri, 0, 1).unwrap().owner_name, "o");
    }

    #[test]
    fn new_revision_drops_stored_tracks() {
        let store = crate::store::tests::temp_store("playlist-revision");
        let uri = format!("{PLAYLIST_PREFIX}{ID}");
        persist_page(
            &store,
            store.generation(),
            &stored_page("r1", 4, 0, &["a", "b"]),
        );
        persist_page(
            &store,
            store.generation(),
            &stored_page("r2", 4, 2, &["c", "d"]),
        );

        assert_eq!(cached_page(&store, uri.clone(), 0, 2), None);
        let page = cached_page(&store, uri, 2, 2).unwrap();
        assert_eq!(page.revision, "r2");
    }

    #[test]
    fn rootlist_round_trips_per_user() {
        let store = crate::store::tests::temp_store("rootlist");
        let entries = vec![
            RootlistEntry::Folder {
                uri: "spotify:user:u:folder:f".into(),
                name: "F".into(),
                parent: None,
            },
            RootlistEntry::Playlist {
                uri: format!("{PLAYLIST_PREFIX}{ID}"),
                name: "P".into(),
                owner: "u".into(),
                track_count: 3,
                parent: Some("spotify:user:u:folder:f".into()),
                editable: true,
                public: true,
            },
        ];
        store.put_rootlist(store.generation(), "u", &entries);
        assert_eq!(store.rootlist::<Vec<RootlistEntry>>("u"), Some(entries));
        assert_eq!(store.rootlist::<Vec<RootlistEntry>>("other"), None);
    }

    fn decode(changes: ListChanges) -> (Vec<u8>, Op) {
        let bytes = changes.write_to_bytes().unwrap();
        let mut decoded = ListChanges::parse_from_bytes(&bytes).unwrap();
        assert!(decoded.want_resulting_revisions());
        assert_eq!(decoded.deltas.len(), 1);
        let mut ops = decoded.deltas.remove(0).ops;
        assert_eq!(ops.len(), 1);
        (decoded.base_revision().to_vec(), ops.remove(0))
    }

    fn uris(items: &[Item]) -> Vec<&str> {
        items.iter().map(Item::uri).collect()
    }

    #[test]
    fn add_appends_or_inserts_at_raw_index() {
        let tracks = vec![format!("spotify:track:{ID}")];
        let (base, op) = decode(changes(vec![0x01, 0xab], add_op(None, &tracks).unwrap()));
        assert_eq!(base, vec![0x01, 0xab]);
        assert_eq!(op.kind(), Kind::ADD);
        assert!(op.add.add_last());
        assert!(!op.add.has_from_index());
        assert_eq!(uris(&op.add.items), vec![tracks[0].as_str()]);

        let (_, op) = decode(changes(vec![1], add_op(Some(3), &tracks).unwrap()));
        assert_eq!((op.add.from_index(), op.add.add_last()), (3, false));
    }

    #[test]
    fn rem_carries_index_length_and_items() {
        let tracks = vec!["spotify:track:a".to_owned(), "spotify:local:x".to_owned()];
        let (base, op) = decode(changes(vec![0xff], rem_op(7, &tracks).unwrap()));
        assert_eq!(base, vec![0xff]);
        assert_eq!(op.kind(), Kind::REM);
        assert_eq!((op.rem.from_index(), op.rem.length()), (7, 2));
        assert_eq!(
            uris(&op.rem.items),
            vec!["spotify:track:a", "spotify:local:x"]
        );
    }

    #[test]
    fn mov_carries_range_and_target() {
        let (_, op) = decode(changes(vec![2], mov_op(4, 2, 0).unwrap()));
        assert_eq!(op.kind(), Kind::MOV);
        assert_eq!(
            (op.mov.from_index(), op.mov.length(), op.mov.to_index()),
            (4, 2, 0)
        );
    }

    #[test]
    fn details_set_name_and_clear_empty_description() {
        let (_, op) = decode(changes(vec![2], details_op("Mix", "Notes")));
        assert_eq!(op.kind(), Kind::UPDATE_LIST_ATTRIBUTES);
        let state = &op.update_list_attributes.new_attributes;
        assert_eq!(
            (state.values.name(), state.values.description()),
            ("Mix", "Notes")
        );
        assert!(state.no_value.is_empty());

        let (_, op) = decode(changes(vec![2], details_op("Mix", "")));
        let state = &op.update_list_attributes.new_attributes;
        assert!(!state.values.has_description());
        assert_eq!(
            state.no_value,
            vec![ListAttributeKind::LIST_DESCRIPTION.into()]
        );
    }

    #[test]
    fn public_updates_the_root_list_item() {
        let uri = format!("{PLAYLIST_PREFIX}{ID}");
        let (_, op) = decode(changes(vec![3], public_op(5, &uri, true).unwrap()));
        assert_eq!(op.kind(), Kind::UPDATE_ITEM_ATTRIBUTES);
        let update = &op.update_item_attributes;
        assert_eq!((update.index(), update.item.uri()), (5, uri.as_str()));
        assert!(update.new_attributes.values.public());
    }

    #[test]
    fn create_request_names_the_list() {
        let bytes = create_request("New", "  About it ")
            .write_to_bytes()
            .unwrap();
        let decoded = ListUpdateRequest::parse_from_bytes(&bytes).unwrap();
        assert_eq!(decoded.attributes.name(), "New");
        assert_eq!(decoded.attributes.description(), "About it");

        let bytes = create_request("New", "  ").write_to_bytes().unwrap();
        let decoded = ListUpdateRequest::parse_from_bytes(&bytes).unwrap();
        assert!(!decoded.attributes.has_description());
    }

    #[test]
    fn pictures_must_be_jpegs_within_the_size_limit() {
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0];
        assert!(validate_jpeg(&jpeg).is_ok());
        jpeg.resize(MAX_PICTURE_BYTES, 0);
        assert!(validate_jpeg(&jpeg).is_ok());
        jpeg.push(0);
        assert!(matches!(
            validate_jpeg(&jpeg),
            Err(PlaylistError::InvalidImage)
        ));
        for bad in [
            &[][..],
            &[0xFF, 0xD8],
            &[0x89, b'P', b'N', b'G'],
            &[0xFF, 0xD8, 0x00],
        ] {
            assert!(matches!(
                validate_jpeg(bad),
                Err(PlaylistError::InvalidImage)
            ));
        }
    }

    #[test]
    fn upload_token_requires_a_non_empty_string() {
        assert_eq!(
            upload_token(br#"{"uploadToken":"tok","other":1}"#).unwrap(),
            "tok"
        );
        for bad in [
            &br#"{}"#[..],
            br#"{"uploadToken":""}"#,
            br#"{"uploadToken":5}"#,
            b"not json",
        ] {
            match upload_token(bad) {
                Err(PlaylistError::Request { message }) => assert!(!message.contains("tok")),
                other => panic!("expected Request, got {other:?}"),
            }
        }
    }

    #[test]
    fn register_request_carries_the_token_and_reply_needs_a_picture() {
        let bytes = register_request("tok".into()).write_to_bytes().unwrap();
        let decoded = RegisterPlaylistImageRequest::parse_from_bytes(&bytes).unwrap();
        assert_eq!(decoded.upload_token(), "tok");

        let mut reply = RegisterPlaylistImageResponse::new();
        reply.set_picture(vec![0xab, 0xcd]);
        let bytes = reply.write_to_bytes().unwrap();
        assert_eq!(registered_picture(&bytes).unwrap(), vec![0xab, 0xcd]);
        assert!(registered_picture(&[]).is_err());
    }

    #[test]
    fn picture_op_sets_only_the_picture() {
        let (_, op) = decode(changes(vec![4], picture_op(vec![0x01, 0x02])));
        assert_eq!(op.kind(), Kind::UPDATE_LIST_ATTRIBUTES);
        let state = &op.update_list_attributes.new_attributes;
        assert_eq!(state.values.picture(), &[0x01, 0x02]);
        assert!(!state.values.has_name() && !state.values.has_description());
        assert!(state.no_value.is_empty());
    }

    #[test]
    fn revision_hex_round_trips_and_rejects_malformed() {
        let bytes = vec![0x00, 0x01, 0xab, 0xff];
        assert_eq!(revision_bytes(&hex(&bytes)).unwrap(), bytes);
        assert_eq!(revision_bytes("0A").unwrap(), vec![0x0a]);
        for bad in ["", "abc", "zz", "+1", "é0"] {
            assert!(matches!(
                revision_bytes(bad),
                Err(PlaylistError::InvalidRevision)
            ));
        }
    }

    #[test]
    fn new_revision_prefers_last_resulting_revision() {
        let mut reply = SelectedListContent::new();
        reply.set_revision(vec![0x01]);
        assert_eq!(new_revision(&reply).unwrap(), "01");
        reply.resulting_revisions = vec![vec![0x02], vec![0x0a, 0xbc]];
        assert_eq!(new_revision(&reply).unwrap(), "0abc");
        assert!(new_revision(&SelectedListContent::new()).is_err());
    }

    #[test]
    fn folder_markers_round_trip_through_rootlist_entries() {
        let name = "Road trips + more: 100% / ok";
        let [start, end] = folder_markers("0123456789abcdef", name);
        assert!(!start.contains(' '));
        let items = [item(&start), item(&end)];
        let entries = rootlist_entries("me", &items, &[MetaItem::new(), MetaItem::new()]);
        assert_eq!(
            entries,
            vec![RootlistEntry::Folder {
                uri: "spotify:user:me:folder:0123456789abcdef".into(),
                name: name.into(),
                parent: None,
            }]
        );
        let id = random_folder_id();
        assert!(id.len() == 16 && id.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    #[test]
    fn rootlist_index_counts_group_markers_across_nesting() {
        let items = [
            item("spotify:playlist:p0"),
            item("spotify:start-group:aa:Outer"),
            item("spotify:start-group:bb:Inner"),
            item("spotify:playlist:p3"),
            item("spotify:end-group:bb"),
            item("spotify:playlist:p5"),
            item("spotify:end-group:aa"),
        ];
        assert_eq!(rootlist_index(&items, "spotify:playlist:p3").unwrap(), 3);
        assert_eq!(rootlist_index(&items, "spotify:playlist:p5").unwrap(), 5);
        assert_eq!(
            rootlist_index(&items, "spotify:user:me:folder:bb").unwrap(),
            2
        );
        assert_eq!(insert_index(&items, None).unwrap(), 0);
        assert_eq!(
            insert_index(&items, Some("spotify:user:me:folder:aa")).unwrap(),
            2
        );
        for missing in ["spotify:playlist:gone", "spotify:user:me:folder:zz"] {
            assert!(matches!(
                rootlist_index(&items, missing),
                Err(PlaylistError::NotInRootlist { .. })
            ));
        }
        assert!(matches!(
            insert_index(&items, Some("spotify:playlist:p0")),
            Err(PlaylistError::NotInRootlist { .. })
        ));
    }

    #[test]
    fn insert_op_lands_inside_the_folder_on_the_given_items() {
        let uri = vec![format!("{PLAYLIST_PREFIX}{ID}")];
        let before = [
            item("spotify:start-group:aa:F"),
            item("spotify:end-group:aa"),
        ];
        let op = insert_op(&before, Some("spotify:user:me:folder:aa"), &uri).unwrap();
        assert_eq!(op.add.from_index(), 1);
        let after = [
            item("spotify:playlist:new"),
            item("spotify:start-group:aa:F"),
            item("spotify:end-group:aa"),
        ];
        let op = insert_op(&after, Some("spotify:user:me:folder:aa"), &uri).unwrap();
        assert_eq!(
            (op.add.from_index(), uris(&op.add.items)),
            (2, vec![uri[0].as_str()])
        );
        assert!(matches!(
            insert_op(&before, Some("spotify:user:me:folder:zz"), &uri),
            Err(PlaylistError::NotInRootlist { .. })
        ));
    }

    #[test]
    fn track_uris_must_be_tracks_or_episodes() {
        assert!(validate_track_uri(&format!("spotify:track:{ID}")).is_ok());
        assert!(validate_track_uri(&format!("spotify:episode:{ID}")).is_ok());
        for bad in [
            format!("spotify:album:{ID}"),
            "spotify:track:short".into(),
            "spotify:local:a:b:c:1".into(),
            format!("spotify:track:{}", "x".repeat(21) + "/"),
        ] {
            assert!(matches!(
                validate_track_uri(&bad),
                Err(PlaylistError::InvalidUri { .. })
            ));
        }
    }

    #[test]
    fn one_bad_uri_fails_a_whole_add() {
        let good = format!("spotify:track:{ID}");
        assert!(validate_track_uris(std::slice::from_ref(&good)).is_ok());
        assert!(matches!(
            validate_track_uris(&[good, "spotify:local:a:b:c:1".into()]),
            Err(PlaylistError::InvalidUri { .. })
        ));
    }

    #[test]
    fn a_removal_accepts_listed_local_files_but_not_garbage() {
        let good = format!("spotify:track:{ID}");
        assert!(validate_listed_uris(&[good.clone(), "spotify:local:a:b:c:1".into()]).is_ok());
        for bad in [
            "https://evil".to_owned(),
            "spotify:track:a\nb".to_owned(),
            format!("spotify:{}", "x".repeat(MAX_LISTED_URI)),
        ] {
            assert!(
                matches!(
                    validate_listed_uris(&[good.clone(), bad.clone()]),
                    Err(PlaylistError::InvalidUri { .. })
                ),
                "{bad}"
            );
        }
    }

    #[test]
    fn indexes_past_i32_are_rejected_not_wrapped() {
        assert!(mov_op(u32::MAX, 1, 0).is_err());
        assert!(mov_op(0, 1, u32::MAX).is_err());
        assert!(rem_op(u32::MAX, &[]).is_err());
        assert!(add_op(Some(usize::MAX), &[]).is_err());
        assert!(public_op(usize::MAX, "spotify:playlist:x", true).is_err());
        assert!(mov_op(i32::MAX.unsigned_abs(), 1, 0).is_ok());
    }

    #[test]
    fn names_are_trimmed_and_must_not_be_empty() {
        assert_eq!(valid_name("  Mix ").unwrap(), "Mix");
        assert!(matches!(valid_name(" \t"), Err(PlaylistError::InvalidName)));
    }

    #[test]
    fn conflict_and_precondition_statuses_map_to_conflict() {
        for status in [StatusCode::CONFLICT, StatusCode::PRECONDITION_FAILED] {
            let error = librespot_core::Error::from(HttpClientError::StatusCode(status));
            assert!(matches!(
                PlaylistError::from(error),
                PlaylistError::Conflict
            ));
        }
        let error =
            librespot_core::Error::from(HttpClientError::StatusCode(StatusCode::BAD_REQUEST));
        assert!(matches!(
            PlaylistError::from(error),
            PlaylistError::Request { .. }
        ));
        let parse = librespot_core::Error::failed_precondition("bad token json");
        assert!(matches!(
            PlaylistError::from(parse),
            PlaylistError::Request { .. }
        ));
    }

    #[test]
    fn editable_means_owned_or_collaborative_and_public_comes_from_item() {
        let mut shared = meta("Shared", "friend", 1);
        shared
            .attributes
            .mut_or_insert_default()
            .set_collaborative(true);
        let mut public = item("spotify:playlist:a");
        public.attributes.mut_or_insert_default().set_public(true);
        let items = [
            public,
            item("spotify:playlist:b"),
            item("spotify:playlist:c"),
        ];
        let metas = [meta("Mine", "me", 1), shared, meta("Theirs", "friend", 1)];
        let flags: Vec<_> = rootlist_entries("me", &items, &metas)
            .into_iter()
            .map(|entry| match entry {
                RootlistEntry::Playlist {
                    editable, public, ..
                } => (editable, public),
                RootlistEntry::Folder { .. } => unreachable!(),
            })
            .collect();
        assert_eq!(flags, vec![(true, true), (true, false), (false, false)]);

        let mut content = SelectedListContent::new();
        content.set_owner_username("friend".into());
        assert!(!page_of("u".into(), &content, "", "me").editable);
        assert!(page_of("u".into(), &content, "", "friend").editable);
        content
            .attributes
            .mut_or_insert_default()
            .set_collaborative(true);
        assert!(page_of("u".into(), &content, "", "me").editable);
    }
}
