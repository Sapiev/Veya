//! Small helpers shared across the crate's modules.

use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use librespot_core::SpotifyUri;

/// A panic while a lock was held leaves plain data that is still usable.
pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Seconds since the Unix epoch; 0 if the clock is before it.
pub(crate) fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// An id safe to put in a URL path segment unescaped: ASCII letters, digits,
/// `.`, `_` and `-`, at most `max` bytes, and not `.` or `..`.
pub(crate) fn is_path_id(id: &str, max: usize) -> bool {
    (1..=max).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        && id.bytes().any(|b| b != b'.')
}

/// Creates `dir` and missing parents owner-only (0700), which shields the
/// files in it that other code creates with the default umask. An existing
/// directory keeps its mode.
pub(crate) fn create_private_dir(dir: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
}

/// Best effort: tightens a file an earlier version created with the umask.
pub(crate) fn make_private(file: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600));
}

/// Artwork loads only from Spotify's image CDNs over https, whatever URL a
/// server response or template supplies.
pub(crate) fn is_artwork_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    // Userinfo or a port makes the host ambiguous; real CDN URLs have neither.
    if authority.contains(['@', ':']) {
        return false;
    }
    let host = authority.to_ascii_lowercase();
    ["scdn.co", "spotifycdn.com"]
        .iter()
        .any(|domain| host.strip_suffix(domain).is_some_and(|h| h.ends_with('.')))
}

pub(crate) fn canonical(uri: &SpotifyUri) -> String {
    uri.to_uri().unwrap_or_else(|_| "<unprintable>".to_owned())
}

/// Drops `value` on a blocking thread when this is its last reference:
/// dropping a librespot `Player` joins its thread, which must not stall an
/// async worker. Drops in place outside a tokio runtime.
fn release_off_runtime<T: Send + 'static>(value: Arc<T>) {
    let Some(value) = Arc::into_inner(value) else {
        return;
    };
    match tokio::runtime::Handle::try_current() {
        Ok(runtime) => drop(runtime.spawn_blocking(move || drop(value))),
        Err(_) => drop(value),
    }
}

/// The client in `cell`, built on first success; clones share its pool.
pub(crate) fn shared_client(
    cell: &'static OnceLock<reqwest::Client>,
    build: impl FnOnce() -> reqwest::Result<reqwest::Client>,
) -> reqwest::Result<reqwest::Client> {
    if let Some(client) = cell.get() {
        return Ok(client.clone());
    }
    let client = build()?;
    Ok(cell.get_or_init(|| client).clone())
}

/// Runs blocking work such as store I/O off the async workers; a panic in
/// `work` resumes here.
pub(crate) async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    match tokio::task::spawn_blocking(work).await {
        Ok(value) => value,
        Err(e) => std::panic::resume_unwind(e.into_panic()),
    }
}

/// A strong reference released through `release_off_runtime` on drop.
pub(crate) struct OffRuntime<T: Send + Sync + 'static>(Option<Arc<T>>);

impl<T: Send + Sync + 'static> OffRuntime<T> {
    pub(crate) fn new(value: Arc<T>) -> Self {
        Self(Some(value))
    }

    pub(crate) fn arc(&self) -> &Arc<T> {
        self.0.as_ref().expect("taken only on drop")
    }
}

impl<T: Send + Sync + 'static> std::ops::Deref for OffRuntime<T> {
    type Target = T;

    fn deref(&self) -> &T {
        self.arc()
    }
}

impl<T: Send + Sync + 'static> Drop for OffRuntime<T> {
    fn drop(&mut self) {
        if let Some(value) = self.0.take() {
            release_off_runtime(value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artwork_urls_must_be_https_on_spotify_cdns() {
        for ok in [
            "https://i.scdn.co/image/ab67616d",
            "https://mosaic.scdn.co/640/x",
            "https://image-cdn-ak.spotifycdn.com/image/x?y=1",
        ] {
            assert!(is_artwork_url(ok), "{ok}");
        }
        for bad in [
            "http://i.scdn.co/image/x",
            "https://scdn.co.evil.com/x",
            "https://evilscdn.co/x",
            "https://i.scdn.co@evil.com/x",
            "https://i.scdn.co:8443/x",
            "https://evil.com/i.scdn.co/x",
            "https://scdn.co/x",
            "spotify:image:abc",
            "",
        ] {
            assert!(!is_artwork_url(bad), "{bad}");
        }
    }

    #[test]
    fn path_ids_reject_traversal_and_oversize() {
        for ok in ["a", "A-b_c.d", &"x".repeat(128)] {
            assert!(is_path_id(ok, 128), "{ok}");
        }
        for bad in [
            "",
            ".",
            "..",
            "...",
            "a/b",
            "a?b",
            "a%2f",
            "a b",
            &"x".repeat(129),
        ] {
            assert!(!is_path_id(bad, 128), "{bad}");
        }
    }

    #[test]
    fn lock_recovers_a_poisoned_mutex() {
        let mutex = Arc::new(Mutex::new(1));
        let poisoner = Arc::clone(&mutex);
        let _ = std::thread::spawn(move || {
            let _guard = poisoner.lock().unwrap();
            panic!("poison");
        })
        .join();
        assert!(mutex.is_poisoned());
        assert_eq!(*lock(&mutex), 1);
    }

    #[tokio::test]
    async fn release_off_runtime_drops_the_last_reference_on_another_thread() {
        struct Probe(std::sync::mpsc::Sender<std::thread::ThreadId>);
        impl Drop for Probe {
            fn drop(&mut self) {
                let _ = self.0.send(std::thread::current().id());
            }
        }
        let (tx, rx) = std::sync::mpsc::channel();
        let probe = Arc::new(Probe(tx));
        let other = Arc::clone(&probe);
        release_off_runtime(probe);
        assert!(rx.try_recv().is_err(), "not the last reference");
        release_off_runtime(other);
        let dropped_on = tokio::task::spawn_blocking(move || rx.recv().unwrap())
            .await
            .unwrap();
        assert_ne!(dropped_on, std::thread::current().id());
    }
}
