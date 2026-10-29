//! Spotify sign-in: Authorization Code + PKCE with a loopback redirect.
//! librespot-oauth is not used because it hides the authorize URL, never
//! checks `state`, blocks inside async code and trace-logs the token
//! response. Nothing in this module logs the code, verifier, state, tokens or
//! callback URL.

use std::fmt;
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use log::{info, warn};
use oauth2::basic::{BasicClient, BasicErrorResponse, BasicErrorResponseType, BasicTokenResponse};
use oauth2::url::Url;
use oauth2::{
    AuthUrl, AuthorizationCode, ClientId, CsrfToken, EndpointNotSet, EndpointSet, HttpClientError,
    PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, RefreshToken, RequestTokenError, Scope,
    TokenResponse, TokenUrl,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, watch};
use tokio::task::JoinSet;

use crate::util::shared_client;

const DEFAULT_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const DEFAULT_REDIRECT_PORT: u16 = 8898;
const AUTHORIZE_URL: &str = "https://accounts.spotify.com/authorize";
const TOKEN_URL: &str = "https://accounts.spotify.com/api/token";
const CALLBACK_PATH: &str = "/login";

/// Minimum for streaming, library and playlist read/write; user-read-private
/// carries the product and country checked at sign-in.
const SCOPES: [&str; 11] = [
    "streaming",
    "user-read-private",
    "user-read-playback-position",
    "user-read-playback-state",
    "user-read-recently-played",
    "user-library-read",
    "user-library-modify",
    "playlist-read-private",
    "playlist-read-collaborative",
    "playlist-modify-private",
    "playlist-modify-public",
];

/// A local connection gets this long to send its request head and read the reply.
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(2);
/// Idle or preconnected sockets beyond this wait for a slot instead of
/// spawning more tasks.
const MAX_CONNECTIONS: usize = 16;
/// Pause after a failed accept (EMFILE and the like) so the loop does not spin.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);
const MAX_REQUEST_HEAD: usize = 8 * 1024;
const TOKEN_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_REASON_LEN: usize = 64;
/// Spotify access tokens last an hour; assumed when a response omits `expires_in`.
const DEFAULT_EXPIRES_IN: Duration = Duration::from_secs(3600);

/// Sent before the code exchange, so it must not claim success.
const PAGE_RECEIVED: &str = "<!doctype html><meta charset=\"utf-8\"><title>Veya</title>\
<p>Return to Veya to finish signing in.</p>";
const PAGE_DENIED: &str = "<!doctype html><meta charset=\"utf-8\"><title>Veya</title>\
<p>Sign-in was not completed. You can close this window and return to Veya.</p>";

type SpotifyClient =
    BasicClient<EndpointSet, EndpointNotSet, EndpointNotSet, EndpointNotSet, EndpointSet>;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OAuthConfig {
    pub client_id: String,
    pub redirect_port: u16,
}

/// The shared librespot keymaster client, whose registered redirect is
/// `http://127.0.0.1:8898/login`.
#[uniffi::export]
pub fn default_oauth_config() -> OAuthConfig {
    OAuthConfig {
        client_id: DEFAULT_CLIENT_ID.to_owned(),
        redirect_port: DEFAULT_REDIRECT_PORT,
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct OAuthTokens {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in_secs: u64,
    pub scopes: Vec<String>,
}

impl fmt::Debug for OAuthTokens {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OAuthTokens")
            .field("access_token", &crate::redact::REDACTED)
            .field("refresh_token", &crate::redact::REDACTED)
            .field("expires_in_secs", &self.expires_in_secs)
            .field("scopes", &self.scopes)
            .finish()
    }
}

/// Messages never carry the code, verifier, state or tokens.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AuthError {
    #[error("sign-in was cancelled")]
    Cancelled,
    #[error("sign-in was denied: {reason}")]
    Denied { reason: String },
    #[error("port {port} is already in use")]
    PortInUse { port: u16 },
    #[error("network error: {message}")]
    Network { message: String },
    #[error("token exchange failed: {message}")]
    Exchange { message: String },
    #[error("invalid OAuth configuration: {message}")]
    InvalidConfig { message: String },
    /// The refresh token was revoked or expired (`invalid_grant`); drop it.
    #[error("refresh token was rejected")]
    RefreshRejected,
    #[error("sign-in flow already finished")]
    AlreadyFinished,
    #[error("internal error: {message}")]
    Internal { message: String },
}

fn internal(message: impl fmt::Display) -> AuthError {
    AuthError::Internal {
        message: message.to_string(),
    }
}

fn invalid_config(message: impl fmt::Display) -> AuthError {
    AuthError::InvalidConfig {
        message: message.to_string(),
    }
}

/// Endpoints and timeouts; tests point the token URL at a local fake server.
#[derive(Debug, Clone)]
pub(crate) struct FlowSettings {
    pub authorize_url: String,
    pub token_url: String,
    pub connection_timeout: Duration,
}

impl FlowSettings {
    fn spotify() -> Self {
        Self {
            authorize_url: AUTHORIZE_URL.to_owned(),
            token_url: TOKEN_URL.to_owned(),
            connection_timeout: CONNECTION_TIMEOUT,
        }
    }
}

struct Pending {
    listener: TcpListener,
    client: SpotifyClient,
    http: reqwest::Client,
    state: CsrfToken,
    verifier: PkceCodeVerifier,
    connection_timeout: Duration,
}

enum Slot {
    Ready(Box<Pending>),
    Cancelled,
    Taken,
}

#[derive(uniffi::Object)]
pub struct LoginFlow {
    authorize_url: String,
    slot: Mutex<Slot>,
    cancelled: watch::Sender<bool>,
    callback_received: AtomicBool,
}

#[uniffi::export(async_runtime = "tokio")]
impl LoginFlow {
    /// Binds `127.0.0.1:{redirect_port}` and prepares a PKCE (S256) request
    /// with a fresh random `state`.
    #[uniffi::constructor]
    pub async fn start(config: OAuthConfig) -> Result<Arc<Self>, AuthError> {
        validate(&config)?;
        let port = config.redirect_port;
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, port))
            .await
            .map_err(|e| match e.kind() {
                std::io::ErrorKind::AddrInUse => AuthError::PortInUse { port },
                _ => internal(format!("cannot listen on port {port}: {e}")),
            })?;
        Self::with_listener(config, FlowSettings::spotify(), listener).map(Arc::new)
    }

    pub fn authorize_url(&self) -> String {
        self.authorize_url.clone()
    }

    /// True once a callback with the right `state` delivered a code, so the
    /// exchange has started or finished; cancelling now drops an approval.
    pub fn callback_received(&self) -> bool {
        self.callback_received.load(Ordering::Acquire)
    }

    /// Waits for the browser callback, then exchanges the code. One-shot.
    pub async fn finish(&self) -> Result<OAuthTokens, AuthError> {
        let taken = std::mem::replace(&mut *self.lock_slot(), Slot::Taken);
        let pending = match taken {
            Slot::Ready(pending) => pending,
            Slot::Cancelled => return Err(AuthError::Cancelled),
            Slot::Taken => return Err(AuthError::AlreadyFinished),
        };
        let mut cancelled = self.cancelled.subscribe();
        tokio::select! {
            result = pending.run(&self.callback_received) => result,
            _ = cancelled.wait_for(|c| *c) => {
                info!("sign-in cancelled");
                Err(AuthError::Cancelled)
            }
        }
    }

    /// Idempotent. Frees the port and makes a pending or later `finish()`
    /// return `Cancelled`; a no-op once the flow has completed.
    pub fn cancel(&self) {
        self.cancelled.send_replace(true);
        let mut slot = self.lock_slot();
        if matches!(*slot, Slot::Ready(_)) {
            *slot = Slot::Cancelled;
        }
    }
}

impl LoginFlow {
    pub(crate) fn with_listener(
        config: OAuthConfig,
        settings: FlowSettings,
        listener: TcpListener,
    ) -> Result<Self, AuthError> {
        let (client, http) = oauth_client(&config, &settings)?;
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        let (url, state) = client
            .authorize_url(CsrfToken::new_random)
            .add_scopes(SCOPES.iter().map(|s| Scope::new((*s).to_owned())))
            .set_pkce_challenge(challenge)
            .url();
        info!(
            "sign-in started, listening on loopback port {}",
            listener.local_addr().map_or(0, |addr| addr.port())
        );
        Ok(Self {
            authorize_url: url.into(),
            slot: Mutex::new(Slot::Ready(Box::new(Pending {
                listener,
                client,
                http,
                state,
                verifier,
                connection_timeout: settings.connection_timeout,
            }))),
            cancelled: watch::Sender::new(false),
            callback_received: AtomicBool::new(false),
        })
    }

    fn lock_slot(&self) -> std::sync::MutexGuard<'_, Slot> {
        self.slot.lock().unwrap_or_else(|e| e.into_inner())
    }
}

fn oauth_client(
    config: &OAuthConfig,
    settings: &FlowSettings,
) -> Result<(SpotifyClient, reqwest::Client), AuthError> {
    validate(config)?;
    let redirect = format!("http://127.0.0.1:{}{CALLBACK_PATH}", config.redirect_port);
    let client = BasicClient::new(ClientId::new(config.client_id.clone()))
        .set_auth_uri(AuthUrl::new(settings.authorize_url.clone()).map_err(invalid_config)?)
        .set_token_uri(TokenUrl::new(settings.token_url.clone()).map_err(invalid_config)?)
        .set_redirect_uri(RedirectUrl::new(redirect).map_err(invalid_config)?);
    static HTTP: OnceLock<reqwest::Client> = OnceLock::new();
    let http = shared_client(&HTTP, || {
        reqwest::Client::builder()
            // The token endpoint must answer directly; following redirects
            // would forward the code or refresh token elsewhere.
            .redirect(reqwest::redirect::Policy::none())
            // Trust only the macOS keychain roots, honoring the user's trust settings.
            .tls_built_in_webpki_certs(false)
            .timeout(TOKEN_REQUEST_TIMEOUT)
            .build()
    })
    .map_err(|e| internal(format!("cannot build HTTP client: {e}")))?;
    Ok((client, http))
}

/// The last successful refresh, so a second caller holding the same (now
/// rotated away) refresh token gets its result instead of `invalid_grant`.
type RecentRefresh = tokio::sync::Mutex<Option<(String, std::time::Instant, OAuthTokens)>>;

/// How long a finished refresh answers callers that held the old token.
const REFRESH_SHARE_WINDOW: Duration = Duration::from_secs(30);

/// Trades a refresh token for a fresh access token. When Spotify does not
/// rotate the refresh token, the result carries the one passed in. Calls
/// are serialized, and ones with the same token share one exchange.
#[uniffi::export(async_runtime = "tokio")]
pub async fn refresh_tokens(
    config: OAuthConfig,
    refresh_token: String,
) -> Result<OAuthTokens, AuthError> {
    static RECENT: RecentRefresh = tokio::sync::Mutex::const_new(None);
    refresh_shared(&RECENT, &config, &FlowSettings::spotify(), refresh_token).await
}

async fn refresh_shared(
    recent: &RecentRefresh,
    config: &OAuthConfig,
    settings: &FlowSettings,
    refresh_token: String,
) -> Result<OAuthTokens, AuthError> {
    let mut recent = recent.lock().await;
    if let Some((used, at, tokens)) = recent.as_ref()
        && *used == refresh_token
        && at.elapsed() < REFRESH_SHARE_WINDOW
    {
        return Ok(tokens.clone());
    }
    let tokens = refresh_with(config, settings, refresh_token.clone()).await?;
    *recent = Some((refresh_token, std::time::Instant::now(), tokens.clone()));
    Ok(tokens)
}

async fn refresh_with(
    config: &OAuthConfig,
    settings: &FlowSettings,
    refresh_token: String,
) -> Result<OAuthTokens, AuthError> {
    let (client, http) = oauth_client(config, settings)?;
    let previous = RefreshToken::new(refresh_token);
    let response = client
        .exchange_refresh_token(&previous)
        .request_async(&http)
        .await
        .map_err(|error| match error {
            RequestTokenError::ServerResponse(ref response)
                if *response.error() == BasicErrorResponseType::InvalidGrant =>
            {
                AuthError::RefreshRejected
            }
            other => map_exchange_error(other),
        })?;
    let tokens = into_tokens(&response, Some(&previous))?;
    info!("access token refreshed");
    Ok(tokens)
}

fn validate(config: &OAuthConfig) -> Result<(), AuthError> {
    if config.client_id.trim().is_empty() {
        return Err(invalid_config("client ID is empty"));
    }
    if config.redirect_port == 0 {
        return Err(invalid_config("redirect port must not be 0"));
    }
    Ok(())
}

impl Pending {
    /// Consumes the flow, so the listener closes however this ends.
    async fn run(
        self: Box<Self>,
        callback_received: &AtomicBool,
    ) -> Result<OAuthTokens, AuthError> {
        let Pending {
            listener,
            client,
            http,
            state,
            verifier,
            connection_timeout,
        } = *self;
        let code = await_callback(&listener, state.secret(), connection_timeout).await;
        drop(listener);
        let code = code?;
        callback_received.store(true, Ordering::Release);
        let response = client
            .exchange_code(AuthorizationCode::new(code))
            .set_pkce_verifier(verifier)
            .request_async(&http)
            .await
            .map_err(map_exchange_error)?;
        let tokens = into_tokens(&response, None)?;
        info!("sign-in succeeded");
        Ok(tokens)
    }
}

/// `previous` is the refresh token a refresh used; it stands in when the
/// response does not rotate it.
fn into_tokens(
    response: &BasicTokenResponse,
    previous: Option<&RefreshToken>,
) -> Result<OAuthTokens, AuthError> {
    let refresh_token =
        response
            .refresh_token()
            .or(previous)
            .ok_or_else(|| AuthError::Exchange {
                message: "token response has no refresh_token".to_owned(),
            })?;
    let expires_in = response.expires_in().unwrap_or(DEFAULT_EXPIRES_IN);
    // RFC 6749 5.1: an omitted scope means the requested scopes were granted.
    let scopes = match response.scopes() {
        Some(scopes) => scopes.iter().map(|s| s.to_string()).collect(),
        None => SCOPES.iter().map(|s| (*s).to_owned()).collect(),
    };
    Ok(OAuthTokens {
        access_token: response.access_token().secret().clone(),
        refresh_token: refresh_token.secret().clone(),
        expires_in_secs: expires_in.as_secs(),
        scopes,
    })
}

fn map_exchange_error(
    error: RequestTokenError<HttpClientError<reqwest::Error>, BasicErrorResponse>,
) -> AuthError {
    match error {
        RequestTokenError::Request(HttpClientError::Reqwest(e)) => AuthError::Network {
            message: e.without_url().to_string(),
        },
        RequestTokenError::Request(e) => AuthError::Network {
            message: e.to_string(),
        },
        RequestTokenError::ServerResponse(response) => AuthError::Exchange {
            message: sanitize(&response.to_string(), 256),
        },
        RequestTokenError::Parse(..) => AuthError::Exchange {
            message: "malformed token response".to_owned(),
        },
        RequestTokenError::Other(message) => AuthError::Exchange {
            message: sanitize(&message, 256),
        },
    }
}

/// Keeps peer-supplied text printable and short.
fn sanitize(text: &str, max_len: usize) -> String {
    text.chars()
        .filter(|c| c.is_ascii_graphic() || *c == ' ')
        .take(max_len)
        .collect()
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[derive(Debug, PartialEq, Eq)]
enum Request {
    NotFound,
    BadState,
    Malformed,
    Denied(String),
    Code(String),
}

enum HeadError {
    TooLarge,
    Io,
}

trait Accept {
    fn accept_stream(&self) -> impl Future<Output = std::io::Result<TcpStream>> + Send;
}

impl Accept for TcpListener {
    async fn accept_stream(&self) -> std::io::Result<TcpStream> {
        self.accept().await.map(|(stream, _)| stream)
    }
}

/// Serves connections concurrently until a callback with the right `state`
/// arrives. Anything else is answered and ignored, so another local process
/// cannot end, hijack or stall the flow. Returning aborts the other handlers.
async fn await_callback(
    listener: &impl Accept,
    expected_state: &str,
    connection_timeout: Duration,
) -> Result<String, AuthError> {
    let expected_state: Arc<str> = expected_state.into();
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    let mut handlers = JoinSet::new();
    loop {
        let next = async {
            // The semaphore is never closed, so this always yields a permit.
            let slot = Arc::clone(&slots).acquire_owned().await.ok()?;
            match listener.accept_stream().await {
                Ok(stream) => Some((slot, stream)),
                Err(e) => {
                    warn!("accepting callback connection failed: {e}");
                    tokio::time::sleep(ACCEPT_BACKOFF).await;
                    None
                }
            }
        };
        tokio::select! {
            Some(joined) = handlers.join_next() => match joined {
                Ok(Some(Ok(code))) => return Ok(code),
                Ok(Some(Err(reason))) => {
                    info!("sign-in denied by the user or Spotify");
                    return Err(AuthError::Denied { reason });
                }
                Ok(None) => {}
                Err(e) => warn!("callback handler failed: {e}"),
            },
            accepted = next => if let Some((slot, stream)) = accepted {
                let state = Arc::clone(&expected_state);
                handlers.spawn(async move {
                    let _slot = slot;
                    serve(stream, &state, connection_timeout).await
                });
            }
        }
    }
}

async fn serve(
    mut stream: TcpStream,
    expected_state: &str,
    connection_timeout: Duration,
) -> Option<Result<String, String>> {
    let handled = tokio::time::timeout(
        connection_timeout,
        handle_connection(&mut stream, expected_state),
    );
    handled.await.unwrap_or_else(|_| {
        warn!("callback connection timed out");
        None
    })
}

/// `None` means keep waiting; `Some` ends the flow.
async fn handle_connection(
    stream: &mut TcpStream,
    expected_state: &str,
) -> Option<Result<String, String>> {
    let head = match read_head(stream).await {
        Ok(head) => head,
        Err(HeadError::TooLarge) => {
            warn!("callback request head too large");
            respond(stream, "431 Request Header Fields Too Large", "").await;
            return None;
        }
        Err(HeadError::Io) => return None,
    };
    match classify(&head, expected_state) {
        Request::NotFound => respond(stream, "404 Not Found", "").await,
        Request::Malformed => respond(stream, "400 Bad Request", "").await,
        Request::BadState => {
            warn!("ignoring callback with missing or mismatched state");
            respond(stream, "400 Bad Request", "").await;
        }
        Request::Denied(reason) => {
            respond(stream, "200 OK", PAGE_DENIED).await;
            return Some(Err(reason));
        }
        Request::Code(code) => {
            respond(stream, "200 OK", PAGE_RECEIVED).await;
            return Some(Ok(code));
        }
    }
    None
}

async fn read_head(stream: &mut TcpStream) -> Result<Vec<u8>, HeadError> {
    let mut head = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    loop {
        let n = stream.read(&mut chunk).await.map_err(|_| HeadError::Io)?;
        if n == 0 {
            return Err(HeadError::Io);
        }
        let searched_from = head.len().saturating_sub(3);
        head.extend_from_slice(&chunk[..n]);
        if let Some(end) = head[searched_from..]
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
        {
            head.truncate(searched_from + end);
            return Ok(head);
        }
        if head.len() >= MAX_REQUEST_HEAD {
            return Err(HeadError::TooLarge);
        }
    }
}

fn classify(head: &[u8], expected_state: &str) -> Request {
    let line_end = head
        .windows(2)
        .position(|w| w == b"\r\n")
        .unwrap_or(head.len());
    let Ok(line) = std::str::from_utf8(&head[..line_end]) else {
        return Request::Malformed;
    };
    let mut parts = line.split(' ');
    let (Some(method), Some(target), Some(_version), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Request::Malformed;
    };
    if !target.starts_with('/') {
        return Request::Malformed;
    }
    let Ok(url) = Url::parse(&format!("http://127.0.0.1{target}")) else {
        return Request::Malformed;
    };
    if method != "GET" || url.path() != CALLBACK_PATH {
        return Request::NotFound;
    }

    let (mut state, mut code, mut error) = (None, None, None);
    for (key, value) in url.query_pairs() {
        let slot = match key.as_ref() {
            "state" => &mut state,
            "code" => &mut code,
            "error" => &mut error,
            _ => continue,
        };
        slot.get_or_insert(value.into_owned());
    }
    let state_ok = state
        .as_deref()
        .is_some_and(|s| constant_time_eq(s.as_bytes(), expected_state.as_bytes()));
    if !state_ok {
        return Request::BadState;
    }
    match (error, code) {
        (Some(error), _) => Request::Denied(sanitize(&error, MAX_REASON_LEN)),
        (None, Some(code)) if !code.is_empty() => Request::Code(code),
        _ => Request::Malformed,
    }
}

async fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\n\
         Content-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n\
         Connection: close\r\n\r\n{body}",
        body.len()
    );
    // The browser may already be gone; the flow outcome does not depend on it.
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLIENT_ID: &str = "test-client";
    const CODE: &str = "test-code-0123";
    const TOKEN_JSON: &str = r#"{"access_token":"at-123","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-456","scope":"streaming user-read-private"}"#;

    async fn flow(token_url: &str, connection_timeout: Duration) -> (Arc<LoginFlow>, u16) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let config = OAuthConfig {
            client_id: CLIENT_ID.to_owned(),
            redirect_port: port,
        };
        let settings = FlowSettings {
            authorize_url: AUTHORIZE_URL.to_owned(),
            token_url: token_url.to_owned(),
            connection_timeout,
        };
        let flow = LoginFlow::with_listener(config, settings, listener).unwrap();
        (Arc::new(flow), port)
    }

    async fn waiting_flow() -> (Arc<LoginFlow>, u16) {
        flow("http://127.0.0.1:9/api/token", CONNECTION_TIMEOUT).await
    }

    fn spawn_finish(
        flow: &Arc<LoginFlow>,
    ) -> tokio::task::JoinHandle<Result<OAuthTokens, AuthError>> {
        let flow = Arc::clone(flow);
        tokio::spawn(async move { flow.finish().await })
    }

    fn param(url: &str, key: &str) -> Option<String> {
        Url::parse(url)
            .unwrap()
            .query_pairs()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.into_owned())
    }

    fn state_of(flow: &LoginFlow) -> String {
        param(&flow.authorize_url(), "state").unwrap()
    }

    async fn send(port: u16, raw: &[u8]) -> String {
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap();
        stream.write_all(raw).await.unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).await.unwrap();
        String::from_utf8_lossy(&response).into_owned()
    }

    async fn get(port: u16, target: &str) -> String {
        let request = format!("GET {target} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n");
        send(port, request.as_bytes()).await
    }

    async fn deny(port: u16, state: &str) -> String {
        get(port, &format!("/login?error=access_denied&state={state}")).await
    }

    fn assert_rebindable(port: u16) {
        std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port))
            .unwrap_or_else(|e| panic!("port {port} still held: {e}"));
    }

    /// Answers one token request with `status` and `body`, returning the
    /// form body it received.
    async fn fake_token_endpoint(
        status: &'static str,
        body: &'static str,
    ) -> (String, tokio::task::JoinHandle<String>) {
        let (release, gate) = tokio::sync::oneshot::channel();
        let _ = release.send(());
        let (url, _seen, server) = gated_token_endpoint(status, body, gate).await;
        (url, server)
    }

    /// Like [`fake_token_endpoint`], but signals `seen` once the request is
    /// read and holds the response until `gate` fires.
    async fn gated_token_endpoint(
        status: &'static str,
        body: &'static str,
        gate: tokio::sync::oneshot::Receiver<()>,
    ) -> (
        String,
        tokio::sync::oneshot::Receiver<()>,
        tokio::task::JoinHandle<String>,
    ) {
        let (seen_tx, seen) = tokio::sync::oneshot::channel();
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let url = format!("http://{}/api/token", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut chunk = [0u8; 4096];
            let (head_end, length) = loop {
                let n = stream.read(&mut chunk).await.unwrap();
                request.extend_from_slice(&chunk[..n]);
                let text = String::from_utf8_lossy(&request).to_lowercase();
                if let Some(end) = text.find("\r\n\r\n") {
                    let length = text[..end]
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length:"))
                        .map_or(0, |v| v.trim().parse::<usize>().unwrap());
                    break (end + 4, length);
                }
            };
            while request.len() < head_end + length {
                let n = stream.read(&mut chunk).await.unwrap();
                request.extend_from_slice(&chunk[..n]);
            }
            let _ = seen_tx.send(());
            let _ = gate.await;
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
                 Connection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
            String::from_utf8_lossy(&request[head_end..]).into_owned()
        });
        (url, seen, server)
    }

    fn s256_challenge(verifier: &str) -> String {
        use base64::Engine as _;
        use sha2::Digest as _;
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(verifier))
    }

    /// Fails the first `failures` accepts the way EMFILE would.
    struct FlakyListener {
        failures: std::sync::atomic::AtomicUsize,
        inner: TcpListener,
    }

    impl Accept for FlakyListener {
        async fn accept_stream(&self) -> std::io::Result<TcpStream> {
            use std::sync::atomic::Ordering;
            if self.failures.load(Ordering::SeqCst) > 0 {
                self.failures.fetch_sub(1, Ordering::SeqCst);
                return Err(std::io::Error::from_raw_os_error(24));
            }
            self.inner.accept_stream().await
        }
    }

    #[tokio::test]
    async fn accept_errors_are_retried_not_fatal() {
        let inner = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let port = inner.local_addr().unwrap().port();
        let listener = FlakyListener {
            failures: 3.into(),
            inner,
        };
        let (result, _) = tokio::join!(
            await_callback(&listener, "s", CONNECTION_TIMEOUT),
            deny(port, "s")
        );
        assert!(
            matches!(result, Err(AuthError::Denied { .. })),
            "{result:?}"
        );
    }

    #[tokio::test]
    async fn idle_connections_do_not_delay_the_callback() {
        let (flow, port) = waiting_flow().await;
        let task = spawn_finish(&flow);
        let mut idle = Vec::new();
        for _ in 0..3 {
            idle.push(
                TcpStream::connect((Ipv4Addr::LOCALHOST, port))
                    .await
                    .unwrap(),
            );
        }
        let started = std::time::Instant::now();
        deny(port, &state_of(&flow)).await;
        assert!(matches!(task.await.unwrap(), Err(AuthError::Denied { .. })));
        assert!(
            started.elapsed() < CONNECTION_TIMEOUT,
            "callback waited {:?} behind idle connections",
            started.elapsed()
        );
    }

    #[test]
    fn default_config_is_the_registered_keymaster_client() {
        let config = default_oauth_config();
        assert_eq!(config.client_id, "65b708073fc0480ea92a077233ca87bd");
        assert_eq!(config.redirect_port, 8898);
    }

    #[tokio::test]
    async fn authorize_url_requests_code_with_pkce_and_state() {
        let (flow, port) = waiting_flow().await;
        let url = flow.authorize_url();
        assert!(url.starts_with("https://accounts.spotify.com/authorize?"));
        let p = |key| param(&url, key);
        assert_eq!(p("response_type").as_deref(), Some("code"));
        assert_eq!(p("code_challenge_method").as_deref(), Some("S256"));
        assert_eq!(p("client_id").as_deref(), Some(CLIENT_ID));
        assert_eq!(
            p("redirect_uri"),
            Some(format!("http://127.0.0.1:{port}/login"))
        );
        assert_eq!(p("scope"), Some(SCOPES.join(" ")));
        assert_eq!(p("code_challenge").map(|c| c.len()), Some(43));
        assert!(p("state").is_some_and(|s| s.len() >= 16));
    }

    #[tokio::test]
    async fn each_flow_gets_a_fresh_state_and_challenge() {
        let (a, _) = waiting_flow().await;
        let (b, _) = waiting_flow().await;
        assert_ne!(state_of(&a), state_of(&b));
        assert_ne!(
            param(&a.authorize_url(), "code_challenge"),
            param(&b.authorize_url(), "code_challenge")
        );
    }

    #[tokio::test]
    async fn rejects_invalid_config() {
        for config in [
            OAuthConfig {
                client_id: " ".to_owned(),
                redirect_port: 8898,
            },
            OAuthConfig {
                client_id: CLIENT_ID.to_owned(),
                redirect_port: 0,
            },
        ] {
            let err = LoginFlow::start(config).await.err().unwrap();
            assert!(matches!(err, AuthError::InvalidConfig { .. }), "{err:?}");
        }
    }

    #[tokio::test]
    async fn port_in_use_is_reported() {
        let taken = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = taken.local_addr().unwrap().port();
        let config = OAuthConfig {
            client_id: CLIENT_ID.to_owned(),
            redirect_port: port,
        };
        let err = LoginFlow::start(config).await.err().unwrap();
        assert!(
            matches!(err, AuthError::PortInUse { port: p } if p == port),
            "{err:?}"
        );
    }

    #[tokio::test]
    async fn start_binds_ipv4_loopback_and_cancel_frees_it() {
        let probe = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = probe.local_addr().unwrap().port();
        drop(probe);
        let flow = LoginFlow::start(OAuthConfig {
            client_id: CLIENT_ID.to_owned(),
            redirect_port: port,
        })
        .await
        .unwrap();
        assert!(std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_err());
        flow.cancel();
        assert_rebindable(port);
    }

    #[tokio::test]
    async fn access_denied_ends_flow_with_denied() {
        let (flow, port) = waiting_flow().await;
        let task = spawn_finish(&flow);
        let response = deny(port, &state_of(&flow)).await;
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        let err = task.await.unwrap().unwrap_err();
        assert!(
            matches!(&err, AuthError::Denied { reason } if reason == "access_denied"),
            "{err:?}"
        );
        assert_rebindable(port);
    }

    #[tokio::test]
    async fn mismatched_or_missing_state_is_ignored() {
        let (flow, port) = waiting_flow().await;
        let task = spawn_finish(&flow);
        for target in [
            format!("/login?code={CODE}&state=forged"),
            format!("/login?code={CODE}"),
            "/login?error=access_denied&state=forged".to_owned(),
        ] {
            let response = get(port, &target).await;
            assert!(response.starts_with("HTTP/1.1 400"), "{target}: {response}");
            assert!(!task.is_finished());
        }
        deny(port, &state_of(&flow)).await;
        let err = task.await.unwrap().unwrap_err();
        assert!(matches!(err, AuthError::Denied { .. }), "{err:?}");
    }

    #[test]
    fn only_the_first_state_parameter_counts_and_only_on_the_callback_path() {
        let head = |target: &str| format!("GET {target} HTTP/1.1\r\n\r\n").into_bytes();
        assert!(matches!(
            classify(&head("/login?state=forged&state=real&code=c"), "real"),
            Request::BadState
        ));
        assert!(matches!(
            classify(&head("/login?state=real&state=forged&code=c"), "real"),
            Request::Code(code) if code == "c"
        ));
        assert!(matches!(
            classify(&head("/other?state=real&code=c"), "real"),
            Request::NotFound
        ));
        assert!(matches!(
            classify(&head("//evil.example/login?state=real&code=c"), "real"),
            Request::NotFound | Request::Malformed
        ));
    }

    #[tokio::test]
    async fn a_callback_replayed_after_success_reaches_nothing() {
        let (token_url, server) = fake_token_endpoint("200 OK", TOKEN_JSON).await;
        let (flow, port) = flow(&token_url, CONNECTION_TIMEOUT).await;
        let task = spawn_finish(&flow);
        let target = format!("/login?code={CODE}&state={}", state_of(&flow));
        get(port, &target).await;
        task.await.unwrap().unwrap();
        server.await.unwrap();

        let replay = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).await;
        assert!(replay.is_err(), "the one-shot listener is closed");
        assert!(matches!(
            flow.finish().await,
            Err(AuthError::AlreadyFinished)
        ));
    }

    #[tokio::test]
    async fn other_paths_get_404_and_flow_keeps_waiting() {
        let (flow, port) = waiting_flow().await;
        let task = spawn_finish(&flow);
        let state = state_of(&flow);
        let favicon = get(port, "/favicon.ico").await;
        assert!(favicon.starts_with("HTTP/1.1 404"), "{favicon}");
        let post = format!("POST /login?code={CODE}&state={state} HTTP/1.1\r\n\r\n");
        let response = send(port, post.as_bytes()).await;
        assert!(response.starts_with("HTTP/1.1 404"), "{response}");
        let garbage = send(port, b"\xff\xfe nonsense\r\n\r\n").await;
        assert!(garbage.starts_with("HTTP/1.1 400"), "{garbage}");
        assert!(!task.is_finished());
        deny(port, &state).await;
        assert!(matches!(task.await.unwrap(), Err(AuthError::Denied { .. })));
    }

    #[tokio::test]
    async fn oversized_request_head_is_rejected_and_flow_keeps_waiting() {
        let (flow, port) = waiting_flow().await;
        let task = spawn_finish(&flow);
        let mut huge = b"GET /login?pad=".to_vec();
        huge.resize(MAX_REQUEST_HEAD, b'a');
        let response = send(port, &huge).await;
        assert!(response.starts_with("HTTP/1.1 431"), "{response}");
        deny(port, &state_of(&flow)).await;
        assert!(matches!(task.await.unwrap(), Err(AuthError::Denied { .. })));
    }

    #[tokio::test]
    async fn stalled_connection_times_out_without_wedging_the_flow() {
        let (flow, port) = flow("http://127.0.0.1:9/api/token", Duration::from_millis(200)).await;
        let task = spawn_finish(&flow);
        let _stalled = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap();
        deny(port, &state_of(&flow)).await;
        assert!(matches!(task.await.unwrap(), Err(AuthError::Denied { .. })));
    }

    #[tokio::test]
    async fn cancel_before_finish_returns_cancelled_and_frees_port() {
        let (flow, port) = waiting_flow().await;
        flow.cancel();
        flow.cancel();
        assert_rebindable(port);
        assert!(matches!(flow.finish().await, Err(AuthError::Cancelled)));
        assert!(matches!(
            flow.finish().await,
            Err(AuthError::AlreadyFinished)
        ));
    }

    #[tokio::test]
    async fn cancel_while_waiting_returns_cancelled_and_frees_port() {
        let (flow, port) = waiting_flow().await;
        let task = spawn_finish(&flow);
        // The test runtime is single-threaded: one yield lets `finish` start waiting.
        tokio::task::yield_now().await;
        flow.cancel();
        let result = task.await.unwrap();
        assert!(matches!(result, Err(AuthError::Cancelled)), "{result:?}");
        assert_rebindable(port);
    }

    #[tokio::test]
    async fn dropping_the_flow_frees_port() {
        let (flow, port) = waiting_flow().await;
        drop(flow);
        assert_rebindable(port);
    }

    #[tokio::test]
    async fn finish_is_one_shot() {
        let (flow, port) = waiting_flow().await;
        let task = spawn_finish(&flow);
        // The test runtime is single-threaded: one yield lets `finish` start waiting.
        tokio::task::yield_now().await;
        assert!(matches!(
            flow.finish().await,
            Err(AuthError::AlreadyFinished)
        ));
        deny(port, &state_of(&flow)).await;
        assert!(matches!(task.await.unwrap(), Err(AuthError::Denied { .. })));
        assert!(matches!(
            flow.finish().await,
            Err(AuthError::AlreadyFinished)
        ));
    }

    #[tokio::test]
    async fn valid_callback_exchanges_code_for_tokens() {
        let (token_url, server) = fake_token_endpoint("200 OK", TOKEN_JSON).await;
        let (flow, port) = flow(&token_url, CONNECTION_TIMEOUT).await;
        let task = spawn_finish(&flow);
        let page = get(
            port,
            &format!("/login?code={CODE}&state={}", state_of(&flow)),
        )
        .await;
        assert!(page.starts_with("HTTP/1.1 200"), "{page}");
        assert!(page.contains("Return to Veya to finish signing in."));
        assert!(!page.to_lowercase().contains("signed in"), "{page}");

        let tokens = task.await.unwrap().unwrap();
        assert_eq!(
            tokens,
            OAuthTokens {
                access_token: "at-123".to_owned(),
                refresh_token: "rt-456".to_owned(),
                expires_in_secs: 3600,
                scopes: vec!["streaming".to_owned(), "user-read-private".to_owned()],
            }
        );
        let form = server.await.unwrap();
        for expected in [
            "grant_type=authorization_code".to_owned(),
            format!("code={CODE}"),
            format!("client_id={CLIENT_ID}"),
            format!("redirect_uri=http%3A%2F%2F127.0.0.1%3A{port}%2Flogin"),
        ] {
            assert!(
                form.contains(&expected),
                "missing {expected} in token request"
            );
        }
        let verifier = form
            .split('&')
            .find_map(|kv| kv.strip_prefix("code_verifier="))
            .expect("token request carries code_verifier");
        assert_eq!(
            param(&flow.authorize_url(), "code_challenge"),
            Some(s256_challenge(verifier))
        );
        assert_rebindable(port);
        flow.cancel();
        assert!(matches!(
            flow.finish().await,
            Err(AuthError::AlreadyFinished)
        ));
    }

    #[tokio::test]
    async fn callback_received_turns_true_only_for_an_accepted_code() {
        let (release, gate) = tokio::sync::oneshot::channel();
        let (token_url, seen, _server) = gated_token_endpoint("200 OK", TOKEN_JSON, gate).await;
        let (flow, port) = flow(&token_url, CONNECTION_TIMEOUT).await;
        assert!(!flow.callback_received());
        let task = spawn_finish(&flow);
        get(port, &format!("/login?code={CODE}&state=forged")).await;
        assert!(!flow.callback_received());

        get(
            port,
            &format!("/login?code={CODE}&state={}", state_of(&flow)),
        )
        .await;
        seen.await.unwrap();
        assert!(!task.is_finished());
        assert!(flow.callback_received());

        release.send(()).unwrap();
        task.await.unwrap().unwrap();
        assert!(flow.callback_received());
    }

    #[tokio::test]
    async fn callback_received_stays_false_when_denied() {
        let (flow, port) = waiting_flow().await;
        let task = spawn_finish(&flow);
        deny(port, &state_of(&flow)).await;
        assert!(matches!(task.await.unwrap(), Err(AuthError::Denied { .. })));
        assert!(!flow.callback_received());
    }

    #[tokio::test]
    async fn rejected_code_maps_to_exchange_without_secrets() {
        let (token_url, _server) = fake_token_endpoint(
            "400 Bad Request",
            r#"{"error":"invalid_grant","error_description":"Invalid authorization code"}"#,
        )
        .await;
        let (flow, port) = flow(&token_url, CONNECTION_TIMEOUT).await;
        let task = spawn_finish(&flow);
        let state = state_of(&flow);
        get(port, &format!("/login?code={CODE}&state={state}")).await;
        let err = task.await.unwrap().unwrap_err();
        let AuthError::Exchange { message } = &err else {
            panic!("expected Exchange, got {err:?}");
        };
        assert!(message.contains("invalid_grant"), "{message}");
        assert!(!message.contains(CODE) && !message.contains(&state));
    }

    #[tokio::test]
    async fn token_response_without_refresh_token_is_an_exchange_error() {
        let (token_url, _server) = fake_token_endpoint(
            "200 OK",
            r#"{"access_token":"at-123","token_type":"Bearer","expires_in":3600}"#,
        )
        .await;
        let (flow, port) = flow(&token_url, CONNECTION_TIMEOUT).await;
        let task = spawn_finish(&flow);
        get(
            port,
            &format!("/login?code={CODE}&state={}", state_of(&flow)),
        )
        .await;
        let err = task.await.unwrap().unwrap_err();
        assert!(matches!(err, AuthError::Exchange { .. }), "{err:?}");
    }

    #[tokio::test]
    async fn unreachable_token_endpoint_maps_to_network() {
        let closed = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let token_url = format!("http://{}/api/token", closed.local_addr().unwrap());
        drop(closed);
        let (flow, port) = flow(&token_url, CONNECTION_TIMEOUT).await;
        let task = spawn_finish(&flow);
        get(
            port,
            &format!("/login?code={CODE}&state={}", state_of(&flow)),
        )
        .await;
        let err = task.await.unwrap().unwrap_err();
        let AuthError::Network { message } = &err else {
            panic!("expected Network, got {err:?}");
        };
        assert!(!message.contains(CODE));
    }

    async fn refresh(token_url: &str, refresh_token: &str) -> Result<OAuthTokens, AuthError> {
        let config = OAuthConfig {
            client_id: CLIENT_ID.to_owned(),
            redirect_port: DEFAULT_REDIRECT_PORT,
        };
        let settings = FlowSettings {
            authorize_url: AUTHORIZE_URL.to_owned(),
            token_url: token_url.to_owned(),
            connection_timeout: CONNECTION_TIMEOUT,
        };
        refresh_with(&config, &settings, refresh_token.to_owned()).await
    }

    #[tokio::test]
    async fn refresh_sends_refresh_grant_and_returns_rotated_token() {
        let (token_url, server) = fake_token_endpoint(
            "200 OK",
            r#"{"access_token":"at-new","token_type":"Bearer","expires_in":1800,"refresh_token":"rt-new","scope":"streaming"}"#,
        )
        .await;
        let tokens = refresh(&token_url, "rt-old").await.unwrap();
        assert_eq!(
            tokens,
            OAuthTokens {
                access_token: "at-new".to_owned(),
                refresh_token: "rt-new".to_owned(),
                expires_in_secs: 1800,
                scopes: vec!["streaming".to_owned()],
            }
        );
        let form = server.await.unwrap();
        assert!(form.contains("grant_type=refresh_token"), "{form}");
        assert!(form.contains("refresh_token=rt-old"), "{form}");
        assert!(form.contains(&format!("client_id={CLIENT_ID}")), "{form}");
    }

    #[tokio::test]
    async fn concurrent_refreshes_with_one_token_share_a_single_exchange() {
        let (token_url, server) = fake_token_endpoint(
            "200 OK",
            r#"{"access_token":"at-new","token_type":"Bearer","refresh_token":"rt-new"}"#,
        )
        .await;
        let config = OAuthConfig {
            client_id: CLIENT_ID.to_owned(),
            redirect_port: DEFAULT_REDIRECT_PORT,
        };
        let settings = FlowSettings {
            authorize_url: AUTHORIZE_URL.to_owned(),
            token_url,
            connection_timeout: CONNECTION_TIMEOUT,
        };
        let recent = RecentRefresh::const_new(None);
        let call = || refresh_shared(&recent, &config, &settings, "rt-old".to_owned());
        let (a, b) = tokio::join!(call(), call());
        // The endpoint answers one request only; a second exchange would fail.
        assert_eq!(a.unwrap(), b.unwrap());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn refresh_without_rotation_keeps_the_old_token_and_defaults_expiry() {
        let (token_url, _server) = fake_token_endpoint(
            "200 OK",
            r#"{"access_token":"at-new","token_type":"Bearer"}"#,
        )
        .await;
        let tokens = refresh(&token_url, "rt-old").await.unwrap();
        assert_eq!(tokens.access_token, "at-new");
        assert_eq!(tokens.refresh_token, "rt-old");
        assert_eq!(tokens.expires_in_secs, DEFAULT_EXPIRES_IN.as_secs());
    }

    #[tokio::test]
    async fn rejected_refresh_token_is_refresh_rejected() {
        let (token_url, _server) = fake_token_endpoint(
            "400 Bad Request",
            r#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#,
        )
        .await;
        let err = refresh(&token_url, "rt-old").await.unwrap_err();
        assert!(matches!(err, AuthError::RefreshRejected), "{err:?}");
    }

    #[tokio::test]
    async fn other_refresh_errors_stay_exchange_errors_without_the_token() {
        let (token_url, _server) = fake_token_endpoint(
            "400 Bad Request",
            r#"{"error":"invalid_client","error_description":"Invalid client"}"#,
        )
        .await;
        let err = refresh(&token_url, "rt-old").await.unwrap_err();
        let AuthError::Exchange { message } = &err else {
            panic!("expected Exchange, got {err:?}");
        };
        assert!(!message.contains("rt-old"), "{message}");
    }

    #[tokio::test]
    async fn refresh_validates_config() {
        let config = OAuthConfig {
            client_id: " ".to_owned(),
            redirect_port: DEFAULT_REDIRECT_PORT,
        };
        let err = refresh_tokens(config, "rt-old".to_owned())
            .await
            .unwrap_err();
        assert!(matches!(err, AuthError::InvalidConfig { .. }), "{err:?}");
    }

    #[test]
    fn tokens_debug_hides_both_tokens() {
        let tokens = OAuthTokens {
            access_token: "at-secret".to_owned(),
            refresh_token: "rt-secret".to_owned(),
            expires_in_secs: 1,
            scopes: vec![],
        };
        let debug = format!("{tokens:?}");
        assert!(
            !debug.contains("at-secret") && !debug.contains("rt-secret"),
            "{debug}"
        );
    }

    #[test]
    fn constant_time_eq_compares_whole_values() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
        assert!(!constant_time_eq(b"", b"a"));
    }

    #[test]
    fn denial_reason_is_sanitized_and_bounded() {
        let long = "x".repeat(200);
        let head = format!("GET /login?state=s&error=bad%0Aline{long} HTTP/1.1");
        let Request::Denied(reason) = classify(head.as_bytes(), "s") else {
            panic!("expected Denied");
        };
        assert!(reason.starts_with("badline"));
        assert_eq!(reason.len(), MAX_REASON_LEN);
    }
}
