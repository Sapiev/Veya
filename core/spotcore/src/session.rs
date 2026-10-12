//! Access-point session and the reusable credentials Swift keeps in the
//! Keychain to sign in again without a browser.

use std::error::Error as StdError;
use std::fmt;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::session::SessionError as CoreSessionError;
use librespot_core::{Error as CoreError, Session, SessionConfig};
use librespot_protocol::authentication::AuthenticationType;
use librespot_protocol::keyexchange::{APLoginFailed, ErrorCode};
use log::info;
use protobuf::Enum;
use serde::{Deserialize, Serialize};
use tokio::sync::watch;

use crate::cache::AudioCache;
use crate::reconnect::{ConnectionObserver, Connector, Link, Supervisor};

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
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
pub(crate) struct StoredCredentials {
    version: u32,
    pub(crate) device_id: String,
    pub(crate) credentials: Credentials,
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
    pub(crate) fn new(device_id: String, credentials: Credentials) -> Self {
        Self {
            version: BLOB_VERSION,
            device_id,
            credentials,
        }
    }

    fn config(&self) -> SessionConfig {
        SessionConfig {
            device_id: self.device_id.clone(),
            ..SessionConfig::default()
        }
    }

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

/// Another connection for the same account, such as the Connect session,
/// that should react to the same wake and network notices.
pub(crate) trait ConnectivityFollower: Send + Sync {
    fn system_did_wake(&self);
    fn network_changed(&self, available: bool);
}

#[derive(uniffi::Object)]
pub struct SpotSession {
    supervisor: Supervisor<Session>,
    follower: Mutex<Option<Weak<dyn ConnectivityFollower>>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl SpotSession {
    /// Signs in with an OAuth access token on a fresh random device id.
    /// Without `cache` every play downloads the file again.
    #[uniffi::constructor]
    pub async fn connect_with_token(
        access_token: String,
        cache: Option<Arc<AudioCache>>,
    ) -> Result<Arc<Self>, SessionError> {
        let credentials = Credentials::with_access_token(access_token);
        Self::start(SessionConfig::default(), credentials, cache).await
    }

    /// Signs in with a blob from `stored_credentials`, on its device id.
    #[uniffi::constructor]
    pub async fn connect_with_stored(
        credentials: Vec<u8>,
        cache: Option<Arc<AudioCache>>,
    ) -> Result<Arc<Self>, SessionError> {
        let stored = StoredCredentials::decode(&credentials)?;
        if let Some(username) = &stored.credentials.username {
            crate::redact::add_secret(username);
        }
        Self::start(stored.config(), stored.credentials, cache).await
    }

    /// Credentials of the current session, which may be a reconnected one.
    pub fn stored_credentials(&self) -> Result<Vec<u8>, SessionError> {
        self.stored()?.encode()
    }

    /// Replaces any previous observer and delivers the current state to it.
    pub fn set_observer(&self, observer: Arc<dyn ConnectionObserver>) {
        self.supervisor.set_observer(observer);
    }

    /// Reconnects now with backoff reset; sockets rarely survive sleep.
    pub fn system_did_wake(&self) {
        self.supervisor.reconnect_now();
        if let Some(follower) = self.follower() {
            follower.system_did_wake();
        }
    }

    /// Replaces a healthy session, for example so a new audio cache limit
    /// applies. A player restarts the current track where it was.
    pub fn reconnect(&self) {
        self.supervisor.reconnect_now();
    }

    /// `true` while reconnecting retries now with backoff reset. Otherwise,
    /// including `false`, a no-op: the liveness poll notices a dead session.
    pub fn network_changed(&self, available: bool) {
        self.supervisor.network_changed(available);
        if let Some(follower) = self.follower() {
            follower.network_changed(available);
        }
    }

    /// Stops reconnecting and closes the session. Idempotent; no observer
    /// callbacks follow it.
    pub fn shutdown(&self) {
        self.supervisor.shutdown();
    }
}

impl SpotSession {
    /// The live session, which a reconnect may have replaced.
    pub(crate) fn current_session(&self) -> Session {
        (*self.supervisor.current_link()).clone()
    }

    /// Replaces any previous follower.
    pub(crate) fn set_follower(&self, follower: Weak<dyn ConnectivityFollower>) {
        *crate::player::lock(&self.follower) = Some(follower);
    }

    fn follower(&self) -> Option<Arc<dyn ConnectivityFollower>> {
        crate::player::lock(&self.follower)
            .as_ref()
            .and_then(Weak::upgrade)
    }

    pub(crate) fn stored(&self) -> Result<StoredCredentials, SessionError> {
        self.supervisor.current_link().stored_credentials()
    }

    /// Changes after each reconnect, once `current_session` returns the new session.
    pub(crate) fn link_changes(&self) -> watch::Receiver<u64> {
        self.supervisor.link_changes()
    }

    async fn start(
        config: SessionConfig,
        credentials: Credentials,
        cache: Option<Arc<AudioCache>>,
    ) -> Result<Arc<Self>, SessionError> {
        let initial = StoredCredentials::new(config.device_id.clone(), credentials.clone());
        let session = connect(
            config,
            credentials,
            cache.as_ref().map(|c| c.librespot_cache()),
        )
        .await?;
        info!("session connected");
        Ok(Arc::new(Self {
            supervisor: Supervisor::start(session, initial, SessionConnector { cache }),
            follower: Mutex::default(),
        }))
    }
}

/// Session::new captures the current tokio handle, so it must run inside
/// the UniFFI runtime that keeps librespot's spawned tasks alive.
async fn connect(
    config: SessionConfig,
    credentials: Credentials,
    cache: Option<Cache>,
) -> Result<Session, SessionError> {
    let attempt = async {
        let session = Session::new(config, cache);
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
    Ok(session)
}

impl Link for Session {
    fn is_invalid(&self) -> bool {
        Session::is_invalid(self)
    }

    fn shutdown(&self) {
        Session::shutdown(self);
    }

    fn stored_credentials(&self) -> Result<StoredCredentials, SessionError> {
        let auth_data = self.auth_data();
        if auth_data.is_empty() {
            return Err(internal("session has no reusable credentials"));
        }
        Ok(StoredCredentials::new(
            self.device_id().to_owned(),
            reusable_credentials(self.username(), auth_data),
        ))
    }
}

/// Reads the cache on every connect so a reconnect picks up a new limit.
struct SessionConnector {
    cache: Option<Arc<AudioCache>>,
}

impl Connector<Session> for SessionConnector {
    async fn connect(&self, stored: StoredCredentials) -> Result<Session, SessionError> {
        let cache = self.cache.as_ref().map(|c| c.librespot_cache());
        connect(stored.config(), stored.credentials, cache).await
    }
}

/// Session keeps only username and auth_data from the reusable credentials
/// connect() received; the AP issues them as stored Spotify credentials,
/// the same assumption login5 makes when it reuses auth_data.
pub(crate) fn reusable_credentials(username: String, auth_data: Vec<u8>) -> Credentials {
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
    #[derive(Default)]
    struct Follower(std::sync::Mutex<Vec<String>>);

    impl super::ConnectivityFollower for Follower {
        fn system_did_wake(&self) {
            self.0.lock().unwrap().push("wake".to_owned());
        }

        fn network_changed(&self, available: bool) {
            self.0.lock().unwrap().push(format!("network {available}"));
        }
    }

    #[tokio::test]
    async fn wake_and_network_notices_reach_the_connect_session() {
        let initial = super::StoredCredentials::new(
            "device".to_owned(),
            super::reusable_credentials("user".to_owned(), vec![1]),
        );
        let unconnected = super::Session::new(super::SessionConfig::default(), None);
        let spot = super::SpotSession {
            supervisor: super::Supervisor::start(
                unconnected,
                initial,
                super::SessionConnector { cache: None },
            ),
            follower: super::Mutex::default(),
        };
        let follower = super::Arc::new(Follower::default());
        let weak = super::Arc::downgrade(&follower);
        spot.set_follower(weak);

        spot.system_did_wake();
        spot.network_changed(true);

        assert_eq!(*follower.0.lock().unwrap(), ["wake", "network true"]);
        spot.shutdown();
    }

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
        let result = SpotSession::connect_with_stored(b"garbage".to_vec(), None).await;
        assert!(matches!(
            result,
            Err(SessionError::InvalidStoredCredentials)
        ));
    }
}
