//! Access-point session and the reusable credentials Swift keeps in the
//! Keychain to sign in again without a browser.

use std::error::Error as StdError;
use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use librespot_core::authentication::Credentials;
use librespot_core::session::SessionError as CoreSessionError;
use librespot_core::{Error as CoreError, Session, SessionConfig};
use librespot_protocol::authentication::AuthenticationType;
use librespot_protocol::keyexchange::{APLoginFailed, ErrorCode};
use log::info;
use protobuf::Enum;
use serde::{Deserialize, Serialize};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const BLOB_VERSION: u32 = 1;

/// Messages never carry tokens, auth data or usernames.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SessionError {
    #[error("Spotify rejected the credentials")]
    CredentialsRejected,
    #[error("login failed: {reason}")]
    LoginFailed { reason: String },
    #[error("stored credentials are invalid")]
    InvalidStoredCredentials,
    #[error("network error: {message}")]
    Network { message: String },
    #[error("internal error: {message}")]
    Internal { message: String },
}

fn internal(message: impl fmt::Display) -> SessionError {
    SessionError::Internal {
        message: message.to_string(),
    }
}

/// Wire format of the opaque blob, UTF-8 JSON:
/// `{"version":1,"device_id":"<uuid>","credentials":<librespot Credentials serde>}`.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
struct StoredCredentials {
    version: u32,
    device_id: String,
    credentials: Credentials,
}

impl fmt::Debug for StoredCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StoredCredentials")
            .field("version", &self.version)
            .field("device_id", &self.device_id)
            .field("username", &crate::redact::REDACTED)
            .field("auth_type", &self.credentials.auth_type)
            .field("auth_data", &crate::redact::REDACTED)
            .finish()
    }
}

impl StoredCredentials {
    fn encode(&self) -> Result<Vec<u8>, SessionError> {
        serde_json::to_vec(self).map_err(internal)
    }

    fn decode(blob: &[u8]) -> Result<Self, SessionError> {
        let stored: Self =
            serde_json::from_slice(blob).map_err(|_| SessionError::InvalidStoredCredentials)?;
        let usable = stored.version == BLOB_VERSION
            && !stored.device_id.is_empty()
            && stored
                .credentials
                .username
                .as_deref()
                .is_some_and(|u| !u.is_empty())
            && !stored.credentials.auth_data.is_empty();
        if usable {
            Ok(stored)
        } else {
            Err(SessionError::InvalidStoredCredentials)
        }
    }
}

#[derive(uniffi::Object)]
pub struct SpotSession {
    session: Session,
}

#[uniffi::export(async_runtime = "tokio")]
impl SpotSession {
    /// Signs in with an OAuth access token on a fresh random device id.
    #[uniffi::constructor]
    pub async fn connect_with_token(access_token: String) -> Result<Arc<Self>, SessionError> {
        let credentials = Credentials::with_access_token(access_token);
        Self::connect(SessionConfig::default(), credentials).await
    }

    /// Signs in with a blob from `stored_credentials`, on its device id.
    #[uniffi::constructor]
    pub async fn connect_with_stored(credentials: Vec<u8>) -> Result<Arc<Self>, SessionError> {
        let stored = StoredCredentials::decode(&credentials)?;
        if let Some(username) = &stored.credentials.username {
            crate::redact::add_secret(username);
        }
        let config = SessionConfig {
            device_id: stored.device_id,
            ..SessionConfig::default()
        };
        Self::connect(config, stored.credentials).await
    }

    pub fn stored_credentials(&self) -> Result<Vec<u8>, SessionError> {
        let auth_data = self.session.auth_data();
        if auth_data.is_empty() {
            return Err(internal("session has no reusable credentials"));
        }
        StoredCredentials {
            version: BLOB_VERSION,
            device_id: self.session.device_id().to_owned(),
            credentials: reusable_credentials(self.session.username(), auth_data),
        }
        .encode()
    }

    pub fn shutdown(&self) {
        self.session.shutdown();
    }
}

impl SpotSession {
    /// Session::new captures the current tokio handle, so it must run inside
    /// the UniFFI runtime that keeps librespot's spawned tasks alive.
    async fn connect(
        config: SessionConfig,
        credentials: Credentials,
    ) -> Result<Arc<Self>, SessionError> {
        let attempt = async {
            let session = Session::new(config, None);
            session.connect(credentials, false).await?;
            Ok::<_, CoreError>(session)
        };
        let session = tokio::time::timeout(CONNECT_TIMEOUT, attempt)
            .await
            .map_err(|_| SessionError::Network {
                message: "connection timed out".to_owned(),
            })?
            .map_err(|e| map_connect_error(&e))?;
        crate::redact::add_secret(&session.username());
        info!("session connected");
        Ok(Arc::new(Self { session }))
    }
}

/// Session keeps only username and auth_data from the reusable credentials
/// connect() received; the AP issues them as stored Spotify credentials,
/// the same assumption login5 makes when it reuses auth_data.
fn reusable_credentials(username: String, auth_data: Vec<u8>) -> Credentials {
    Credentials {
        username: Some(username),
        auth_type: AuthenticationType::AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS,
        auth_data,
    }
}

pub(crate) fn map_connect_error(error: &CoreError) -> SessionError {
    use librespot_core::error::ErrorKind;
    if let Some(code) = login_error_code(error) {
        return match code {
            ErrorCode::BadCredentials => SessionError::CredentialsRejected,
            ErrorCode::TryAnotherAP => SessionError::Network {
                message: "no access point accepted the login".to_owned(),
            },
            code => SessionError::LoginFailed {
                reason: login_reason(code),
            },
        };
    }
    let message = crate::redact::redact(&error.to_string());
    match error.kind {
        ErrorKind::PermissionDenied | ErrorKind::Unauthenticated => SessionError::LoginFailed {
            reason: "authentication failed".to_owned(),
        },
        ErrorKind::Internal
        | ErrorKind::InvalidArgument
        | ErrorKind::Unimplemented
        | ErrorKind::FailedPrecondition
        | ErrorKind::DataLoss => SessionError::Internal { message },
        _ => SessionError::Network { message },
    }
}

/// librespot's AuthenticationError sits in a private module; its type is
/// reached through the public SessionError variant that wraps it, and its
/// code recovered by comparing against each known LoginFailed rendering.
fn login_error_code(error: &CoreError) -> Option<ErrorCode> {
    let auth = login_failed(
        CoreSessionError::AuthenticationError,
        ErrorCode::BadCredentials,
    );
    let rendered = match error.error.downcast_ref::<CoreSessionError>() {
        Some(CoreSessionError::AuthenticationError(inner)) => inner.to_string(),
        _ => downcast_like(&auth, error.error.as_ref())?.to_string(),
    };
    ErrorCode::VALUES.iter().copied().find(|&code| {
        login_failed(CoreSessionError::AuthenticationError, code).to_string() == rendered
    })
}

fn login_failed<T: From<APLoginFailed>>(
    _wrapped_by: fn(T) -> CoreSessionError,
    code: ErrorCode,
) -> T {
    let mut failure = APLoginFailed::new();
    failure.set_error_code(code);
    T::from(failure)
}

fn downcast_like<'a, T: StdError + 'static>(
    _sample: &T,
    error: &'a (dyn StdError + Send + Sync + 'static),
) -> Option<&'a T> {
    error.downcast_ref::<T>()
}

fn login_reason(code: ErrorCode) -> String {
    let rendered = login_failed(CoreSessionError::AuthenticationError, code).to_string();
    match rendered.split_once(": ") {
        Some((_, reason)) => reason.to_owned(),
        None => rendered,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const USERNAME: &str = "veya-test-user";
    const AUTH_DATA: &[u8] = b"stored-auth-data-secret";

    fn stored() -> StoredCredentials {
        StoredCredentials {
            version: BLOB_VERSION,
            device_id: "0b5c3d2e-1111-4222-8333-944455556666".to_owned(),
            credentials: reusable_credentials(USERNAME.to_owned(), AUTH_DATA.to_vec()),
        }
    }

    fn login_error(code: ErrorCode) -> CoreError {
        CoreError::from(login_failed(CoreSessionError::AuthenticationError, code))
    }

    #[test]
    fn blob_round_trip_preserves_fields() {
        let original = stored();
        let decoded = StoredCredentials::decode(&original.encode().unwrap()).unwrap();
        assert_eq!(decoded, original);
        assert_eq!(decoded.device_id, original.device_id);
        assert_eq!(decoded.credentials.username.as_deref(), Some(USERNAME));
        assert_eq!(
            decoded.credentials.auth_type,
            AuthenticationType::AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS
        );
        assert_eq!(decoded.credentials.auth_data, AUTH_DATA);
    }

    #[test]
    fn blob_is_versioned_json() {
        let json: serde_json::Value = serde_json::from_slice(&stored().encode().unwrap()).unwrap();
        assert_eq!(json["version"], 1);
        assert!(json["device_id"].is_string());
        assert!(json["credentials"].is_object());
    }

    #[test]
    fn unknown_version_is_rejected() {
        let mut future = stored();
        future.version = 2;
        let err = StoredCredentials::decode(&future.encode().unwrap()).unwrap_err();
        assert!(matches!(err, SessionError::InvalidStoredCredentials));
    }

    #[test]
    fn garbage_is_rejected() {
        for blob in [
            &b""[..],
            b"not json",
            b"{}",
            b"{\"version\":1}",
            &[0xff, 0x00],
        ] {
            let err = StoredCredentials::decode(blob).unwrap_err();
            assert!(matches!(err, SessionError::InvalidStoredCredentials));
        }
    }

    #[test]
    fn empty_auth_data_is_rejected() {
        let mut empty = stored();
        empty.credentials.auth_data.clear();
        let err = StoredCredentials::decode(&empty.encode().unwrap()).unwrap_err();
        assert!(matches!(err, SessionError::InvalidStoredCredentials));
    }

    #[test]
    fn bad_credentials_map_to_rejected() {
        let err = map_connect_error(&login_error(ErrorCode::BadCredentials));
        assert!(matches!(err, SessionError::CredentialsRejected));
    }

    #[test]
    fn other_login_failure_keeps_reason() {
        let err = map_connect_error(&login_error(ErrorCode::PremiumAccountRequired));
        match err {
            SessionError::LoginFailed { reason } => assert_eq!(reason, "Premium account required"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn login_failure_wrapped_in_session_error_is_recognised() {
        let auth = login_failed(
            CoreSessionError::AuthenticationError,
            ErrorCode::BadCredentials,
        );
        let err = map_connect_error(&CoreError::from(CoreSessionError::AuthenticationError(
            auth,
        )));
        assert!(matches!(err, SessionError::CredentialsRejected));
    }

    #[test]
    fn non_auth_error_maps_to_network() {
        let err = map_connect_error(&CoreError::unavailable("connection refused"));
        match err {
            SessionError::Network { message } => assert!(message.contains("connection refused")),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn internal_kind_maps_to_internal() {
        let err = map_connect_error(&CoreError::internal("broken invariant"));
        assert!(matches!(err, SessionError::Internal { .. }));
    }

    #[test]
    fn debug_and_display_never_leak_secrets() {
        crate::redact::add_secret(USERNAME);
        let secret_text = String::from_utf8(AUTH_DATA.to_vec()).unwrap();
        let network = map_connect_error(&CoreError::unavailable(format!("AP dropped {USERNAME}")));
        assert!(matches!(network, SessionError::Network { .. }));
        let internal = map_connect_error(&CoreError::internal(format!("bad state for {USERNAME}")));
        assert!(matches!(internal, SessionError::Internal { .. }));
        let errors = [
            SessionError::CredentialsRejected,
            map_connect_error(&login_error(ErrorCode::PremiumAccountRequired)),
            SessionError::InvalidStoredCredentials,
            network,
            internal,
        ];
        let mut rendered: Vec<String> = errors
            .iter()
            .flat_map(|e| [e.to_string(), format!("{e:?}")])
            .collect();
        rendered.push(format!("{:?}", stored()));
        for text in rendered {
            assert!(!text.contains(USERNAME), "{text}");
            assert!(!text.contains(&secret_text), "{text}");
        }
    }

    #[test]
    fn every_login_error_code_round_trips() {
        for &code in ErrorCode::VALUES {
            assert_eq!(login_error_code(&login_error(code)), Some(code), "{code:?}");
        }
    }

    #[test]
    fn try_another_ap_maps_to_network() {
        let err = map_connect_error(&login_error(ErrorCode::TryAnotherAP));
        assert!(matches!(err, SessionError::Network { .. }));
    }

    #[test]
    fn unrecognised_auth_kinds_map_to_login_failed() {
        for error in [
            CoreError::permission_denied("denied"),
            CoreError::unauthenticated("no session"),
        ] {
            let err = map_connect_error(&error);
            assert!(matches!(err, SessionError::LoginFailed { .. }), "{err:?}");
        }
    }

    #[tokio::test]
    async fn connect_with_stored_rejects_garbage_without_network() {
        let result = SpotSession::connect_with_stored(b"garbage".to_vec()).await;
        assert!(matches!(
            result,
            Err(SessionError::InvalidStoredCredentials)
        ));
    }
}
