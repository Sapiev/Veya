//! Persistent metadata cache: one SQLite file shared by the library,
//! metadata and playlist services. Everything in it can be refetched, so a
//! file this build cannot use is deleted and recreated rather than repaired.
//!
//! Schema v1 (`PRAGMA user_version = 1`), bodies are serde_json:
//!   library_set(username, name, sync_token, body: [LibraryItem])  PK(username, name)
//!   metadata_item(uri PK, body: MetadataItem, fetched_at: unix secs)
//!   rootlist(username PK, body: [RootlistEntry])
//!   playlist(uri PK, revision: hex, body: PlaylistPage without tracks)
//!   playlist_track(uri, position, body: PlaylistTrack)  PK(uri, position)

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use log::warn;
use rusqlite::{
    Connection, ErrorCode, OptionalExtension, Transaction, TransactionBehavior, params,
};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::cache::CacheError;

const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// Index `i` upgrades a database from `user_version` i to i + 1.
const MIGRATIONS: &[&str] = &["
    CREATE TABLE library_set (
        username TEXT NOT NULL,
        name TEXT NOT NULL,
        sync_token TEXT NOT NULL,
        body TEXT NOT NULL,
        PRIMARY KEY (username, name)
    );
    CREATE TABLE metadata_item (
        uri TEXT PRIMARY KEY,
        body TEXT NOT NULL,
        fetched_at INTEGER NOT NULL
    );
    CREATE TABLE rootlist (
        username TEXT PRIMARY KEY,
        body TEXT NOT NULL
    );
    CREATE TABLE playlist (
        uri TEXT PRIMARY KEY,
        revision TEXT NOT NULL,
        body TEXT NOT NULL
    );
    CREATE TABLE playlist_track (
        uri TEXT NOT NULL,
        position INTEGER NOT NULL,
        body TEXT NOT NULL,
        PRIMARY KEY (uri, position)
    );
"];

impl From<rusqlite::Error> for CacheError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Io {
            message: e.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct MetadataStore {
    connection: Mutex<Connection>,
    /// Bumped by `clear`; writes carry the value seen before their request.
    generation: AtomicU64,
}

#[uniffi::export]
impl MetadataStore {
    /// Opens or creates the database at `path`. A corrupt file, or one
    /// written by a newer build, is replaced by an empty one.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, CacheError> {
        Self::open_at(Path::new(&path), BUSY_TIMEOUT)
    }

    /// Deletes every row. Refreshes already in flight write nothing.
    pub fn clear(&self) -> Result<(), CacheError> {
        let connection = self.lock();
        // Before the delete, so a failed clear still drops in-flight writes.
        self.generation.fetch_add(1, Ordering::SeqCst);
        let mut connection = connection.ok_or_else(|| CacheError::Io {
            message: "metadata store lock poisoned".into(),
        })?;
        let tx = connection.transaction()?;
        tx.execute_batch(
            "DELETE FROM library_set; DELETE FROM metadata_item; DELETE FROM rootlist;
             DELETE FROM playlist; DELETE FROM playlist_track;",
        )?;
        tx.commit()?;
        Ok(())
    }
}

impl MetadataStore {
    fn open_at(path: &Path, busy_timeout: Duration) -> Result<Arc<Self>, CacheError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let connection = match connect(path, busy_timeout) {
            Ok(connection) => connection,
            Err(OpenError::Unusable(reason)) => {
                warn!("metadata store unusable, recreating: {reason}");
                remove_database(path)?;
                connect(path, busy_timeout)?
            }
            Err(OpenError::Failed(e)) => return Err(e),
        };
        Ok(Arc::new(Self {
            connection: Mutex::new(connection),
            generation: AtomicU64::new(0),
        }))
    }

    /// Capture before a network request and pass to the write that follows.
    pub(crate) fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    pub(crate) fn library_set<T: DeserializeOwned>(
        &self,
        username: &str,
        name: &str,
    ) -> Option<(String, T)> {
        self.read(|c| {
            c.query_row(
                "SELECT sync_token, body FROM library_set WHERE username = ?1 AND name = ?2",
                params![username, name],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
        })
        .flatten()
        .and_then(|(token, body)| Some((token, decode(&body)?)))
    }

    pub(crate) fn put_library_set<T: Serialize>(
        &self,
        generation: u64,
        username: &str,
        name: &str,
        sync_token: &str,
        body: &T,
    ) {
        self.write(generation, |tx| {
            tx.execute(
                "INSERT OR REPLACE INTO library_set (username, name, sync_token, body)
                 VALUES (?1, ?2, ?3, ?4)",
                params![username, name, sync_token, encode(body)],
            )
            .map(drop)
        });
    }

    /// Items fetched at or after `fetched_since` (unix secs), keyed by URI.
    pub(crate) fn metadata_items<T: DeserializeOwned>(
        &self,
        uris: &[&str],
        fetched_since: i64,
    ) -> HashMap<String, T> {
        self.read(|c| {
            let mut statement = c.prepare_cached(
                "SELECT body FROM metadata_item WHERE uri = ?1 AND fetched_at >= ?2",
            )?;
            let mut found = HashMap::new();
            for uri in uris {
                let body: Option<String> = statement
                    .query_row(params![uri, fetched_since], |row| row.get(0))
                    .optional()?;
                if let Some(item) = body.as_deref().and_then(decode) {
                    found.insert((*uri).to_owned(), item);
                }
            }
            Ok(found)
        })
        .unwrap_or_default()
    }

    pub(crate) fn put_metadata_items<T: Serialize>(
        &self,
        generation: u64,
        items: &[(&str, &T)],
        fetched_at: i64,
    ) {
        self.write(generation, |tx| {
            let mut statement = tx.prepare_cached(
                "INSERT OR REPLACE INTO metadata_item (uri, body, fetched_at) VALUES (?1, ?2, ?3)",
            )?;
            for (uri, item) in items {
                statement.execute(params![uri, encode(item), fetched_at])?;
            }
            Ok(())
        });
    }

    pub(crate) fn rootlist<T: DeserializeOwned>(&self, username: &str) -> Option<T> {
        self.read(|c| {
            c.query_row(
                "SELECT body FROM rootlist WHERE username = ?1",
                [username],
                |row| row.get::<_, String>(0),
            )
            .optional()
        })
        .flatten()
        .and_then(|body| decode(&body))
    }

    pub(crate) fn put_rootlist<T: Serialize>(&self, generation: u64, username: &str, body: &T) {
        self.write(generation, |tx| {
            tx.execute(
                "INSERT OR REPLACE INTO rootlist (username, body) VALUES (?1, ?2)",
                params![username, encode(body)],
            )
            .map(drop)
        });
    }

    /// The playlist's attributes and the stored tracks at positions in
    /// `positions`, in position order.
    pub(crate) fn playlist<A: DeserializeOwned, T: DeserializeOwned>(
        &self,
        uri: &str,
        positions: std::ops::Range<u32>,
    ) -> Option<(A, Vec<(u32, T)>)> {
        self.read(|c| {
            let Some(body) = c
                .query_row("SELECT body FROM playlist WHERE uri = ?1", [uri], |row| {
                    row.get::<_, String>(0)
                })
                .optional()?
            else {
                return Ok(None);
            };
            let mut statement = c.prepare_cached(
                "SELECT position, body FROM playlist_track
                 WHERE uri = ?1 AND position >= ?2 AND position < ?3 ORDER BY position",
            )?;
            let tracks = statement
                .query_map(params![uri, positions.start, positions.end], |row| {
                    Ok((row.get::<_, u32>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?
                .into_iter()
                .filter_map(|(position, body)| Some((position, decode(&body)?)))
                .collect();
            Ok(decode(&body).map(|attributes| (attributes, tracks)))
        })
        .flatten()
    }

    /// Upserts attributes and the tracks from `offset` on; a new revision
    /// first drops every stored track, since positions may have shifted.
    pub(crate) fn put_playlist<A: Serialize, T: Serialize>(
        &self,
        generation: u64,
        uri: &str,
        revision: &str,
        attributes: &A,
        offset: u32,
        tracks: &[T],
    ) {
        self.write(generation, |tx| {
            let stored: Option<String> = tx
                .query_row(
                    "SELECT revision FROM playlist WHERE uri = ?1",
                    [uri],
                    |row| row.get(0),
                )
                .optional()?;
            if stored.as_deref() != Some(revision) {
                tx.execute("DELETE FROM playlist_track WHERE uri = ?1", [uri])?;
            }
            tx.execute(
                "INSERT OR REPLACE INTO playlist (uri, revision, body) VALUES (?1, ?2, ?3)",
                params![uri, revision, encode(attributes)],
            )?;
            let mut statement = tx.prepare_cached(
                "INSERT OR REPLACE INTO playlist_track (uri, position, body) VALUES (?1, ?2, ?3)",
            )?;
            for (position, track) in (offset..).zip(tracks) {
                statement.execute(params![uri, position, encode(track)])?;
            }
            Ok(())
        });
    }

    fn read<R>(&self, query: impl FnOnce(&Connection) -> rusqlite::Result<R>) -> Option<R> {
        let connection = self.lock()?;
        query(&connection)
            .inspect_err(|e| warn!("metadata store read failed: {e}"))
            .ok()
    }

    /// Best effort: failures are logged, and writes started before the last
    /// `clear` are dropped. The check runs under the lock `clear` takes.
    fn write(&self, generation: u64, apply: impl FnOnce(&Transaction) -> rusqlite::Result<()>) {
        let Some(mut connection) = self.lock() else {
            return;
        };
        if generation != self.generation() {
            return;
        }
        let result = connection.transaction().and_then(|tx| {
            apply(&tx)?;
            tx.commit()
        });
        if let Err(e) = result {
            warn!("metadata store write failed: {e}");
        }
    }

    /// Stalls every read and write until dropped, as a slow disk would.
    #[cfg(test)]
    pub(crate) fn stall(&self) -> MutexGuard<'_, Connection> {
        self.connection.lock().unwrap()
    }

    /// `None` after a panic while locked, so FFI callers see a miss, not a panic.
    fn lock(&self) -> Option<MutexGuard<'_, Connection>> {
        self.connection
            .lock()
            .inspect_err(|_| warn!("metadata store lock poisoned"))
            .ok()
    }
}

/// `Unusable` files are disposable and get recreated; anything else (busy,
/// disk full, permissions) is returned so a live database is never deleted.
enum OpenError {
    Unusable(String),
    Failed(CacheError),
}

impl From<rusqlite::Error> for OpenError {
    fn from(e: rusqlite::Error) -> Self {
        match e.sqlite_error_code() {
            Some(ErrorCode::NotADatabase | ErrorCode::DatabaseCorrupt) => {
                Self::Unusable(e.to_string())
            }
            _ => Self::Failed(e.into()),
        }
    }
}

impl From<OpenError> for CacheError {
    fn from(e: OpenError) -> Self {
        match e {
            OpenError::Unusable(message) => Self::Io { message },
            OpenError::Failed(e) => e,
        }
    }
}

fn connect(path: &Path, busy_timeout: Duration) -> Result<Connection, OpenError> {
    let mut connection = Connection::open(path)?;
    connection.busy_timeout(busy_timeout)?;
    connection.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))?;
    migrate(&mut connection)?;
    Ok(connection)
}

/// One immediate transaction, so a crash mid-migration leaves the old
/// version and a concurrent opener waits instead of migrating twice. A
/// current database takes no write lock.
fn migrate(connection: &mut Connection) -> Result<(), OpenError> {
    let latest = MIGRATIONS.len() as u32;
    if checked_version(connection, latest)? == latest {
        return Ok(());
    }
    let tx = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let version = checked_version(&tx, latest)?;
    for migration in &MIGRATIONS[version as usize..] {
        tx.execute_batch(migration)?;
    }
    tx.pragma_update(None, "user_version", latest)?;
    tx.commit()?;
    Ok(())
}

fn checked_version(connection: &Connection, latest: u32) -> Result<u32, OpenError> {
    let version: u32 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version > latest {
        return Err(OpenError::Unusable(format!(
            "schema version {version} is newer than this build"
        )));
    }
    Ok(version)
}

fn remove_database(path: &Path) -> std::io::Result<()> {
    for suffix in ["", "-wal", "-shm"] {
        let mut file = path.as_os_str().to_owned();
        file.push(suffix);
        match fs::remove_file(file) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
    }
    Ok(())
}

fn encode<T: Serialize>(value: &T) -> String {
    serde_json::to_string(value).expect("cached records serialize")
}

/// A body from an older layout of the same schema version reads as a miss.
fn decode<T: DeserializeOwned>(body: &str) -> Option<T> {
    serde_json::from_str(body).ok()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn temp_store(name: &str) -> Arc<MetadataStore> {
        MetadataStore::open(temp_path(name).to_string_lossy().into_owned()).unwrap()
    }

    use std::path::PathBuf;

    fn temp_path(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("spotcore-store-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir.join("nested").join("metadata.sqlite")
    }

    fn open(path: &Path) -> Arc<MetadataStore> {
        MetadataStore::open(path.to_string_lossy().into_owned()).unwrap()
    }

    fn user_version(path: &Path) -> i64 {
        Connection::open(path)
            .unwrap()
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap()
    }

    #[test]
    fn opens_migrates_and_reopens_with_data() {
        let path = temp_path("reopen");
        let store = open(&path);
        store.put_rootlist(store.generation(), "u", &vec!["a".to_owned()]);
        drop(store);
        assert_eq!(user_version(&path), MIGRATIONS.len() as i64);

        let store = open(&path);
        assert_eq!(store.rootlist::<Vec<String>>("u"), Some(vec!["a".into()]));
    }

    #[test]
    fn newer_schema_is_recreated_empty() {
        let path = temp_path("newer");
        let store = open(&path);
        store.put_rootlist(store.generation(), "u", &1);
        drop(store);
        Connection::open(&path)
            .unwrap()
            .pragma_update(None, "user_version", 99)
            .unwrap();

        let store = open(&path);
        assert_eq!(store.rootlist::<i32>("u"), None);
        assert_eq!(user_version(&path), MIGRATIONS.len() as i64);
    }

    /// A raw connection holding the write lock on a WAL database at
    /// `user_version` 0 that contains a `marker` table.
    fn locked_old_database(path: &Path) -> Connection {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let connection = Connection::open(path).unwrap();
        connection
            .query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))
            .unwrap();
        connection
            .execute_batch("CREATE TABLE marker (x); BEGIN IMMEDIATE;")
            .unwrap();
        connection
    }

    fn has_marker(path: &Path) -> bool {
        Connection::open(path)
            .unwrap()
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name = 'marker'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
            == 1
    }

    #[test]
    fn busy_database_is_an_error_and_kept() {
        let path = temp_path("busy");
        let holder = locked_old_database(&path);

        let opened = MetadataStore::open_at(&path, Duration::from_millis(50));
        assert!(opened.is_err());
        holder.execute_batch("COMMIT").unwrap();
        assert!(has_marker(&path));
    }

    #[test]
    fn current_database_opens_without_the_write_lock() {
        let path = temp_path("current-locked");
        let store = open(&path);
        store.put_rootlist(store.generation(), "u", &1);
        drop(store);
        let holder = Connection::open(&path).unwrap();
        holder.execute_batch("BEGIN IMMEDIATE").unwrap();

        let store = MetadataStore::open_at(&path, Duration::from_millis(50)).unwrap();
        assert_eq!(store.rootlist::<i32>("u"), Some(1));
    }

    #[test]
    fn failed_clear_still_drops_writes_from_before_it() {
        let path = temp_path("failed-clear");
        let store = MetadataStore::open_at(&path, Duration::from_millis(50)).unwrap();
        let before = store.generation();
        let holder = Connection::open(&path).unwrap();
        holder.execute_batch("BEGIN IMMEDIATE").unwrap();
        assert!(store.clear().is_err());
        holder.execute_batch("COMMIT").unwrap();

        store.put_rootlist(before, "u", &1);
        assert_eq!(store.rootlist::<i32>("u"), None);
    }

    #[test]
    fn garbage_file_is_recreated_empty() {
        let path = temp_path("garbage");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, vec![0xAB; 8192]).unwrap();

        let store = open(&path);
        store.put_rootlist(store.generation(), "u", &1);
        assert_eq!(store.rootlist::<i32>("u"), Some(1));
    }

    #[test]
    fn clear_empties_every_table_and_is_idempotent() {
        let store = temp_store("clear");
        let generation = store.generation();
        store.put_library_set(generation, "u", "collection", "t", &1);
        store.put_metadata_items(generation, &[("spotify:track:a", &1)], 0);
        store.put_rootlist(generation, "u", &1);
        store.put_playlist(generation, "p", "r", &1, 0, &[1]);

        store.clear().unwrap();
        store.clear().unwrap();
        assert_eq!(store.library_set::<i32>("u", "collection"), None);
        assert!(
            store
                .metadata_items::<i32>(&["spotify:track:a"], 0)
                .is_empty()
        );
        assert_eq!(store.rootlist::<i32>("u"), None);
        assert_eq!(store.playlist::<i32, i32>("p", 0..1), None);
    }

    #[test]
    fn write_from_before_clear_is_skipped() {
        let store = temp_store("stale");
        let before = store.generation();
        store.clear().unwrap();
        store.put_rootlist(before, "u", &1);
        assert_eq!(store.rootlist::<i32>("u"), None);

        store.put_rootlist(store.generation(), "u", &2);
        assert_eq!(store.rootlist::<i32>("u"), Some(2));
    }

    #[test]
    fn metadata_older_than_cutoff_is_a_miss() {
        let store = temp_store("age");
        let generation = store.generation();
        store.put_metadata_items(generation, &[("old", &1)], 100);
        store.put_metadata_items(generation, &[("new", &2)], 200);

        let found = store.metadata_items::<i32>(&["old", "new", "absent"], 150);
        assert_eq!(found, HashMap::from([("new".to_owned(), 2)]));
    }

    #[test]
    fn new_playlist_revision_drops_old_tracks() {
        let store = temp_store("revision");
        let generation = store.generation();
        store.put_playlist(generation, "p", "r1", &"a1", 0, &[10, 11]);
        store.put_playlist(generation, "p", "r1", &"a1", 2, &[12]);
        assert_eq!(
            store.playlist::<String, i32>("p", 0..3),
            Some(("a1".into(), vec![(0, 10), (1, 11), (2, 12)]))
        );

        store.put_playlist(generation, "p", "r2", &"a2", 1, &[21]);
        assert_eq!(
            store.playlist::<String, i32>("p", 0..3),
            Some(("a2".into(), vec![(1, 21)]))
        );
    }
}
