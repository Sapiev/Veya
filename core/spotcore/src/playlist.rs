//! The user's playlists through spclient's playlist4 endpoints: the root list
//! with its folders, playlist contents page by page, follower counts, and
//! dealer pushes that report changes made on other devices.

use std::sync::Arc;

use http::Method;
use librespot_core::Session;
use librespot_protocol::playlist4_external::{Item, MetaItem, SelectedListContent};
use percent_encoding::percent_decode_str;
use protobuf::Message as _;

use crate::library::decode_fields;
use crate::metadata::{Artwork, ArtworkSize, image_url_template};
use crate::push::PushWatch;
use crate::session::SpotSession;

const ROOTLIST_PAGE: usize = 120;
const PUSH_URI: &str = "hm://playlist/";
const PLAYLIST_PREFIX: &str = "spotify:playlist:";

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PlaylistError {
    #[error("not a playlist URI: {uri}")]
    InvalidUri { uri: String },
    #[error("playlist request failed: {message}")]
    Request { message: String },
}

impl From<librespot_core::Error> for PlaylistError {
    fn from(e: librespot_core::Error) -> Self {
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
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
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
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlaylistTrack {
    pub uri: String,
    pub added_by: String,
    /// Unix seconds, 0 when unknown.
    pub added_at: i64,
}

/// One window of a playlist. Pages from different `revision`s may not line
/// up, so restart from offset 0 when it changes.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlaylistPage {
    pub uri: String,
    pub revision: String,
    pub name: String,
    pub description: String,
    pub owner: String,
    pub collaborative: bool,
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

#[derive(uniffi::Object)]
pub struct PlaylistService {
    session: Arc<SpotSession>,
    push: PushWatch,
}

#[uniffi::export(async_runtime = "tokio")]
impl PlaylistService {
    #[uniffi::constructor]
    pub fn new(session: Arc<SpotSession>) -> Arc<Self> {
        Arc::new(Self {
            session,
            push: PushWatch::new(PUSH_URI),
        })
    }

    /// The whole root list, folders included, in server order.
    pub async fn rootlist(&self) -> Result<Vec<RootlistEntry>, PlaylistError> {
        let session = self.session.current_session();
        let mut items = Vec::new();
        let mut metas = Vec::new();
        loop {
            let bytes = session
                .spclient()
                .get_rootlist(items.len(), Some(ROOTLIST_PAGE))
                .await?;
            let mut content = SelectedListContent::parse_from_bytes(&bytes)?;
            let total = content.length().max(0) as usize;
            let contents = content.contents.take().unwrap_or_default();
            let received = contents.items.len();
            let mut page_metas = contents.meta_items;
            page_metas.resize_with(received, MetaItem::default);
            items.extend(contents.items);
            metas.extend(page_metas);
            if received == 0 || items.len() >= total {
                break;
            }
        }
        Ok(rootlist_entries(&session.username(), &items, &metas))
    }

    /// Up to `length` tracks starting at `from`, with the list's attributes.
    pub async fn page(
        &self,
        uri: String,
        from: u32,
        length: u32,
    ) -> Result<PlaylistPage, PlaylistError> {
        let id = playlist_id(&uri)?;
        let session = self.session.current_session();
        let endpoint = format!("/playlist/v2/playlist/{id}?from={from}&length={length}");
        let bytes = get(&session, &endpoint).await?;
        let content = SelectedListContent::parse_from_bytes(&bytes)?;
        Ok(page_of(uri, &content, &image_url_template(&session)))
    }

    pub async fn follower_count(&self, uri: String) -> Result<u64, PlaylistError> {
        let id = playlist_id(&uri)?;
        let session = self.session.current_session();
        let bytes = get(&session, &format!("/popcount/v2/playlist/{id}/count")).await?;
        Ok(decode_popcount(&bytes)?)
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

async fn get(session: &Session, endpoint: &str) -> Result<Vec<u8>, PlaylistError> {
    let response = session
        .spclient()
        .request(&Method::GET, endpoint, None, None)
        .await?;
    Ok(response.to_vec())
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
        if let Some(rest) = uri.strip_prefix("spotify:start-group:") {
            let (id, name) = rest.split_once(':').unwrap_or((rest, ""));
            let folder = format!("spotify:user:{username}:folder:{id}");
            entries.push(RootlistEntry::Folder {
                uri: folder.clone(),
                name: decode_folder_name(name),
                parent: folders.last().cloned(),
            });
            folders.push(folder);
        } else if uri.starts_with("spotify:end-group:") {
            folders.pop();
        } else if uri.starts_with(PLAYLIST_PREFIX) {
            entries.push(RootlistEntry::Playlist {
                uri: uri.to_owned(),
                name: meta.attributes.name().to_owned(),
                owner: meta.owner_username().to_owned(),
                track_count: meta.length().max(0) as u32,
                parent: folders.last().cloned(),
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

fn page_of(uri: String, content: &SelectedListContent, image_url: &str) -> PlaylistPage {
    let attributes = &content.attributes;
    let contents = &content.contents;
    PlaylistPage {
        uri,
        revision: content
            .revision()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
        name: attributes.name().to_owned(),
        description: attributes.description().to_owned(),
        owner: content.owner_username().to_owned(),
        collaborative: attributes.collaborative(),
        artwork: artwork(attributes.picture(), &attributes.picture_size, image_url),
        total: content.length().max(0) as u32,
        offset: contents.pos().max(0) as u32,
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
    let id: String = picture.iter().map(|b| format!("{b:02x}")).collect();
    vec![Artwork {
        url: image_url.replace("{file_id}", &id),
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
    Ok(count.max(0) as u64)
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
        let page = page_of("spotify:playlist:x".into(), &decoded, "u/{file_id}");
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
}
