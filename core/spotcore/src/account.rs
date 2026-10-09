//! Account product check before the access-point login, because librespot
//! exits the process when it sees a non-Premium account (ADR-005).

use std::time::Duration;

use serde::Deserialize;

use crate::session::SessionError;

const ME_URL: &str = "https://api.spotify.com/v1/me";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const PREMIUM: &str = "premium";

/// Only `product` is read; the other `/v1/me` fields are personal data we
/// have no use for.
#[derive(Deserialize)]
struct Me {
    product: Option<String>,
}

/// `false` for Free and every other non-Premium product. Fails when the
/// product cannot be read, for example without the `user-read-private` scope.
#[uniffi::export(async_runtime = "tokio")]
pub async fn is_premium_account(access_token: String) -> Result<bool, SessionError> {
    is_premium_at(ME_URL, &access_token).await
}

async fn is_premium_at(url: &str, access_token: &str) -> Result<bool, SessionError> {
    let http = reqwest::Client::builder()
        // A redirect must not carry the bearer token elsewhere.
        .redirect(reqwest::redirect::Policy::none())
        // Trust only the macOS keychain roots, honoring the user's trust settings.
        .tls_built_in_webpki_certs(false)
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|e| internal(format!("cannot build HTTP client: {e}")))?;
    let response = http
        .get(url)
        .bearer_auth(access_token)
        .send()
        .await
        .map_err(network)?;
    let status = response.status();
    if !status.is_success() {
        return Err(SessionError::LoginFailed {
            reason: format!("account lookup returned HTTP {}", status.as_u16()),
        });
    }
    let body = response.bytes().await.map_err(network)?;
    let me: Me =
        serde_json::from_slice(&body).map_err(|_| internal("malformed account response"))?;
    me.product
        .map(|product| product == PREMIUM)
        .ok_or_else(|| internal("account response has no product"))
}

fn network(error: reqwest::Error) -> SessionError {
    SessionError::Network {
        message: error.without_url().to_string(),
    }
}

fn internal(message: impl Into<String>) -> SessionError {
    SessionError::Internal {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// Answers one request with `status` and `body`, returning the request head.
    async fn fake_me(
        status: &'static str,
        body: &'static str,
    ) -> (String, tokio::task::JoinHandle<String>) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let url = format!("http://{}/v1/me", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut chunk = [0u8; 4096];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = stream.read(&mut chunk).await.unwrap();
                request.extend_from_slice(&chunk[..n]);
            }
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
                 Connection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
            String::from_utf8_lossy(&request).into_owned()
        });
        (url, server)
    }

    #[tokio::test]
    async fn premium_product_is_premium() {
        let (url, server) = fake_me("200 OK", r#"{"product":"premium","country":"PL"}"#).await;
        assert!(is_premium_at(&url, "at-123").await.unwrap());
        let request = server.await.unwrap().to_lowercase();
        assert!(request.starts_with("get /v1/me "), "{request}");
        assert!(
            request.contains("authorization: bearer at-123"),
            "{request}"
        );
    }

    #[tokio::test]
    async fn free_and_open_products_are_not_premium() {
        for body in [r#"{"product":"free"}"#, r#"{"product":"open"}"#] {
            let (url, _server) = fake_me("200 OK", body).await;
            assert!(!is_premium_at(&url, "at").await.unwrap(), "{body}");
        }
    }

    #[tokio::test]
    async fn missing_product_is_an_error() {
        let (url, _server) = fake_me("200 OK", r#"{"country":"PL"}"#).await;
        let error = is_premium_at(&url, "at").await.unwrap_err();
        assert!(matches!(error, SessionError::Internal { .. }), "{error:?}");
    }

    #[tokio::test]
    async fn malformed_body_is_an_error() {
        let (url, _server) = fake_me("200 OK", "<html>").await;
        let error = is_premium_at(&url, "at").await.unwrap_err();
        assert!(matches!(error, SessionError::Internal { .. }), "{error:?}");
    }

    #[tokio::test]
    async fn http_error_is_login_failed_with_status_only() {
        let (url, _server) =
            fake_me("401 Unauthorized", r#"{"error":{"message":"at-secret"}}"#).await;
        let error = is_premium_at(&url, "at").await.unwrap_err();
        let SessionError::LoginFailed { reason } = error else {
            panic!("{error:?}");
        };
        assert_eq!(reason, "account lookup returned HTTP 401");
    }

    #[tokio::test]
    async fn unreachable_server_is_a_network_error() {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let url = format!("http://{}/v1/me", listener.local_addr().unwrap());
        drop(listener);
        let error = is_premium_at(&url, "at").await.unwrap_err();
        assert!(matches!(error, SessionError::Network { .. }), "{error:?}");
    }
}
