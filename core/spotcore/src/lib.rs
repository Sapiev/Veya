//! Thin wrapper crate around librespot. Swift never depends on librespot
//! types directly; everything the app needs crosses the UniFFI boundary
//! through this crate (see ADR-001).

use librespot_core::SpotifyUri;

mod logging;
mod redact;

pub use logging::{LogLevel, LogRecord, LogSink, LoggingConfig};

uniffi::setup_scaffolding!();

/// Errors surfaced to Swift as the `SpotCoreError` enum.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SpotCoreError {
    #[error("invalid Spotify URI: {message}")]
    InvalidUri { message: String },
    #[error("internal error: {message}")]
    Internal { message: String },
}

#[uniffi::export]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

/// Parses a `spotify:` URI and returns it in canonical form.
#[uniffi::export]
pub fn canonical_uri(uri: String) -> Result<String, SpotCoreError> {
    let invalid = |e: librespot_core::Error| SpotCoreError::InvalidUri {
        message: e.to_string(),
    };
    SpotifyUri::from_uri(&uri)
        .and_then(|u| u.to_uri())
        .map_err(invalid)
}

/// Round-trips a task through the tokio runtime that librespot needs,
/// proving async calls work end to end from Swift.
#[uniffi::export(async_runtime = "tokio")]
pub async fn runtime_check() -> Result<String, SpotCoreError> {
    tokio::spawn(async { version() })
        .await
        .map_err(|e| SpotCoreError::Internal {
            message: e.to_string(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_set() {
        assert!(!version().is_empty());
    }

    #[test]
    fn session_config_has_a_device_id() {
        let config = librespot_core::SessionConfig::default();
        assert!(!config.device_id.is_empty());
    }

    #[test]
    fn canonical_uri_accepts_track_uri() {
        let uri = "spotify:track:4uLU6hMCjMI75M1A2tKUQC";
        assert_eq!(canonical_uri(uri.to_owned()).unwrap(), uri);
    }

    #[test]
    fn canonical_uri_rejects_garbage() {
        let err = canonical_uri("not-a-uri".to_owned()).unwrap_err();
        assert!(matches!(err, SpotCoreError::InvalidUri { .. }));
    }

    #[tokio::test]
    async fn runtime_check_returns_version() {
        assert_eq!(runtime_check().await.unwrap(), version());
    }
}
