//! On-disk audio cache shared by every session, reconnects included.
//!
//! librespot writes each file as downloaded, still AES-encrypted with a key
//! it never stores, so cached audio cannot be played or exported outside a
//! signed-in session. Its size limiter evicts least recently used files.
//!
//! librespot fixes the limit when a cache opens and a session keeps its
//! cache for life, so a new limit takes effect once sessions reconnect.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use librespot_core::FileId;
use librespot_core::cache::Cache;
use log::warn;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CacheError {
    #[error("cache I/O failed: {message}")]
    Io { message: String },
}

impl From<std::io::Error> for CacheError {
    fn from(e: std::io::Error) -> Self {
        Self::Io {
            message: e.to_string(),
        }
    }
}

impl From<librespot_core::Error> for CacheError {
    fn from(e: librespot_core::Error) -> Self {
        Self::Io {
            message: e.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct AudioCache {
    /// Replaced by `set_limit_bytes`; sessions hold clones of the old one
    /// until they reconnect.
    cache: Mutex<Cache>,
    directory: PathBuf,
}

#[uniffi::export]
impl AudioCache {
    /// Opens or creates the cache in `directory` and evicts files beyond
    /// `limit_bytes`. Create one per directory: each instance tracks sizes
    /// on its own, so two would overrun the limit.
    #[uniffi::constructor]
    pub fn new(directory: String, limit_bytes: u64) -> Result<Arc<Self>, CacheError> {
        let directory = PathBuf::from(directory);
        let cache = Mutex::new(open(&directory, limit_bytes)?);
        Ok(Arc::new(Self { cache, directory }))
    }

    /// Evicts least recently used files down to `limit_bytes` now, and
    /// caps sessions that connect from here on; `SpotSession::reconnect`
    /// moves the current one over.
    pub fn set_limit_bytes(&self, limit_bytes: u64) -> Result<(), CacheError> {
        let mut cache = self.lock();
        *cache = open(&self.directory, limit_bytes)?;
        Ok(())
    }

    /// Deletes every cached file. Goes through librespot so its size
    /// accounting drops them too; safe to repeat after a partial run.
    pub fn clear(&self) -> Result<(), CacheError> {
        let cache = self.lock();
        for shard in fs::read_dir(&self.directory)? {
            let shard = shard?.path();
            if !shard.is_dir() {
                fs::remove_file(&shard)?;
                continue;
            }
            for file in fs::read_dir(&shard)? {
                let file = file?.path();
                match file_id(&shard, &file) {
                    Some(id) => cache.remove_file(id)?,
                    None => remove_any(&file)?,
                }
            }
            if let Err(e) = fs::remove_dir(&shard) {
                warn!("could not remove cache directory: {e}");
            }
        }
        Ok(())
    }
}

impl AudioCache {
    pub(crate) fn librespot_cache(&self) -> Cache {
        self.lock().clone()
    }

    fn lock(&self) -> MutexGuard<'_, Cache> {
        self.cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Scans `directory` and evicts by access time down to `limit_bytes`.
fn open(directory: &Path, limit_bytes: u64) -> Result<Cache, CacheError> {
    Ok(Cache::new(None, None, Some(directory), Some(limit_bytes))?)
}

/// Inverts librespot's layout: `<first 2 hex digits>/<remaining 38>`.
fn file_id(shard: &Path, file: &Path) -> Option<FileId> {
    let name = format!(
        "{}{}",
        shard.file_name()?.to_str()?,
        file.file_name()?.to_str()?
    );
    if name.len() != 40 || !name.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let bytes: Option<Vec<u8>> = (0..40)
        .step_by(2)
        .map(|i| u8::from_str_radix(&name[i..i + 2], 16).ok())
        .collect();
    Some(FileId::from_raw(&bytes?))
}

fn remove_any(path: &Path) -> std::io::Result<()> {
    if path.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("spotcore-cache-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    fn id(n: u8) -> FileId {
        FileId::from_raw(&[n; 20])
    }

    fn open_at(dir: &Path, limit: u64) -> Arc<AudioCache> {
        AudioCache::new(dir.to_str().unwrap().to_owned(), limit).unwrap()
    }

    #[test]
    fn file_id_round_trips_librespot_layout() {
        let dir = temp_dir("layout");
        let cache = open_at(&dir, 1_000);
        let path = cache.librespot_cache().file_path(id(0xab)).unwrap();
        assert_eq!(file_id(path.parent().unwrap(), &path), Some(id(0xab)));
        assert_eq!(file_id(&dir.join("zz"), &dir.join("zz").join("x")), None);
    }

    #[test]
    fn evicts_least_recently_used_beyond_limit() {
        let dir = temp_dir("lru");
        let cache = open_at(&dir, 25);
        let lib = cache.librespot_cache();
        lib.save_file(id(1), &mut Cursor::new([0u8; 10])).unwrap();
        lib.save_file(id(2), &mut Cursor::new([0u8; 10])).unwrap();
        lib.save_file(id(3), &mut Cursor::new([0u8; 10])).unwrap();
        assert!(lib.file(id(1)).is_none());
        assert!(lib.file(id(3)).is_some());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn lowering_the_limit_evicts_now_and_caps_later_saves() {
        let dir = temp_dir("limit");
        let cache = open_at(&dir, 100);
        let old = cache.librespot_cache();
        for n in 1..=4 {
            old.save_file(id(n), &mut Cursor::new([0u8; 10])).unwrap();
        }

        cache.set_limit_bytes(25).unwrap();
        cache.set_limit_bytes(25).unwrap();
        let cached = |c: &Cache| (1..=6).filter(|n| c.file(id(*n)).is_some()).count();
        let new = cache.librespot_cache();
        assert_eq!(cached(&new), 2);

        new.save_file(id(5), &mut Cursor::new([0u8; 10])).unwrap();
        new.save_file(id(6), &mut Cursor::new([0u8; 10])).unwrap();
        assert_eq!(cached(&new), 2);
        assert!(new.file(id(6)).is_some());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn clear_empties_directory_and_frees_the_limit() {
        let dir = temp_dir("clear");
        let cache = open_at(&dir, 25);
        let lib = cache.librespot_cache();
        lib.save_file(id(1), &mut Cursor::new([0u8; 10])).unwrap();
        lib.save_file(id(2), &mut Cursor::new([0u8; 10])).unwrap();
        fs::write(dir.join("stray"), b"x").unwrap();

        cache.clear().unwrap();
        cache.clear().unwrap();
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);

        // Stale accounting would evict one of these on the second save.
        lib.save_file(id(3), &mut Cursor::new([0u8; 10])).unwrap();
        lib.save_file(id(4), &mut Cursor::new([0u8; 10])).unwrap();
        assert!(lib.file(id(3)).is_some());
        assert!(lib.file(id(4)).is_some());
        fs::remove_dir_all(&dir).unwrap();
    }
}
