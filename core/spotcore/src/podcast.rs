//! Episode resume points and played state, read from the Web API because
//! librespot has no endpoint for them (ADR-007).

use std::collections::HashMap;

use serde::Deserialize;

use crate::account::{MAX_BODY_BYTES, read_capped, web_api_client};

const EPISODES_URL: &str = "https://api.spotify.com/v1/episodes";
/// The Web API's per-request limit for `ids`.
const MAX_IDS: usize = 50;
const EPISODE_PREFIX: &str = "spotify:episode:";

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PodcastError {
    #[error("not an episode URI: {uri}")]
    InvalidUri { uri: String },
    /// Tokens from before the scope was added need a fresh sign-in.
    #[error("the access token lacks the user-read-playback-position scope")]
    MissingScope,
    #[error("network error: {message}")]
    Network { message: String },
    #[error("episodes request returned HTTP {status}")]
    Request { status: u16 },
    #[error("malformed episodes response: {message}")]
    Malformed { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EpisodeProgress {
    pub uri: String,
    pub resume_position_ms: u32,
    pub fully_played: bool,
}

#[derive(Deserialize)]
struct Episodes {
    /// Parsed one by one: a malformed entry must not fail the batch.
    episodes: Vec<serde_json::Value>,
}

/// Only the id and resume point are read.
#[derive(Deserialize)]
struct Episode {
    id: String,
    resume_point: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct ResumePoint {
    resume_position_ms: u32,
    fully_played: bool,
}

/// Progress for each episode Spotify knows, in input order; unknown
/// episodes are left out.
#[uniffi::export(async_runtime = "tokio")]
pub async fn episode_progress(
    access_token: String,
    uris: Vec<String>,
) -> Result<Vec<EpisodeProgress>, PodcastError> {
    episode_progress_at(EPISODES_URL, &access_token, &uris).await
}

async fn episode_progress_at(
    url: &str,
    access_token: &str,
    uris: &[String],
) -> Result<Vec<EpisodeProgress>, PodcastError> {
    // One hostile or stale URI must not hide the progress of the others.
    let (uris, ids): (Vec<&String>, Vec<&str>) = uris
        .iter()
        .filter_map(|uri| episode_id(uri).map(|id| (uri, id)))
        .unzip();
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let http = web_api_client().map_err(network)?;
    let mut found = HashMap::new();
    for chunk in ids.chunks(MAX_IDS) {
        // Ids are validated base62, so they need no escaping.
        let response = http
            .get(format!("{url}?ids={}", chunk.join(",")))
            .bearer_auth(access_token)
            .send()
            .await
            .map_err(network)?;
        match response.status().as_u16() {
            200..=299 => {}
            403 => return Err(PodcastError::MissingScope),
            status => return Err(PodcastError::Request { status }),
        }
        let body = read_capped(response, MAX_BODY_BYTES, network, || {
            PodcastError::Malformed {
                message: "response too large".to_owned(),
            }
        })
        .await?;
        let page: Episodes =
            serde_json::from_slice(&body).map_err(|e| PodcastError::Malformed {
                message: e.to_string(),
            })?;
        let mut without_point = 0;
        let mut listed = 0;
        for value in page.episodes {
            let Ok(Some(episode)) = Option::<Episode>::deserialize(value) else {
                continue;
            };
            listed += 1;
            match episode
                .resume_point
                .and_then(|p| ResumePoint::deserialize(p).ok())
            {
                Some(point) => {
                    found.insert(episode.id, point);
                }
                None => without_point += 1,
            }
        }
        // Spotify omits every resume point when the token lacks the scope.
        if listed > 0 && without_point == listed {
            return Err(PodcastError::MissingScope);
        }
    }
    Ok(uris
        .into_iter()
        .zip(ids)
        .filter_map(|(uri, id)| {
            found.get(id).map(|point| EpisodeProgress {
                uri: uri.clone(),
                resume_position_ms: point.resume_position_ms,
                fully_played: point.fully_played,
            })
        })
        .collect())
}

/// The base62 id of a `spotify:episode:<22 base62>` URI; the trust boundary
/// for what goes into the request URL.
fn episode_id(uri: &str) -> Option<&str> {
    let id = uri.strip_prefix(EPISODE_PREFIX)?;
    (id.len() == 22 && id.bytes().all(|b| b.is_ascii_alphanumeric())).then_some(id)
}

fn network(error: reqwest::Error) -> PodcastError {
    PodcastError::Network {
        message: error.without_url().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account::fake_web_api;

    const A: &str = "512ojhOuo1ktJprKbVcKyQ";
    const B: &str = "4rOoJ6Egrf8K2IrywzwOMk";

    fn uri(id: &str) -> String {
        format!("{EPISODE_PREFIX}{id}")
    }

    fn episode(id: &str, ms: u32, played: bool) -> String {
        format!(
            r#"{{"id":"{id}","name":"x","resume_point":{{"resume_position_ms":{ms},"fully_played":{played}}}}}"#
        )
    }

    #[tokio::test]
    async fn reads_progress_in_input_order_skipping_null_entries() {
        let body = format!(
            r#"{{"episodes":[{},null,{}]}}"#,
            episode(B, 90_000, false),
            episode(A, 0, true)
        );
        let (base, server) = fake_web_api(vec![("200 OK", body)]).await;
        let url = format!("{base}/v1/episodes");
        let uris = [uri(A), uri("0000000000000000000000"), uri(B)];

        let progress = episode_progress_at(&url, "at-1", &uris).await.unwrap();

        assert_eq!(
            progress,
            [
                EpisodeProgress {
                    uri: uri(A),
                    resume_position_ms: 0,
                    fully_played: true
                },
                EpisodeProgress {
                    uri: uri(B),
                    resume_position_ms: 90_000,
                    fully_played: false
                },
            ]
        );
        let head = server.await.unwrap().remove(0).to_lowercase();
        assert!(
            head.starts_with(&format!(
                "get /v1/episodes?ids={a},0000000000000000000000,{b} ",
                a = A.to_lowercase(),
                b = B.to_lowercase()
            )),
            "{head}"
        );
        assert!(head.contains("authorization: bearer at-1"), "{head}");
    }

    #[tokio::test]
    async fn requests_at_most_fifty_ids_each() {
        let ids: Vec<String> = (0..51).map(|n| format!("{n:0>22}")).collect();
        let first = format!(r#"{{"episodes":[{}]}}"#, episode(&ids[0], 1, false));
        let second = format!(r#"{{"episodes":[{}]}}"#, episode(&ids[50], 2, false));
        let (base, server) = fake_web_api(vec![("200 OK", first), ("200 OK", second)]).await;
        let uris: Vec<String> = ids.iter().map(|id| uri(id)).collect();

        let progress = episode_progress_at(&base, "at", &uris).await.unwrap();

        let got: Vec<_> = progress.iter().map(|p| p.resume_position_ms).collect();
        assert_eq!(got, [1, 2]);
        let heads = server.await.unwrap();
        let counts: Vec<_> = heads
            .iter()
            .map(|h| h.split_whitespace().nth(1).unwrap().split(',').count())
            .collect();
        assert_eq!(counts, [50, 1]);
    }

    #[tokio::test]
    async fn forbidden_or_absent_resume_point_is_missing_scope() {
        let without = r#"{"episodes":[{"id":"512ojhOuo1ktJprKbVcKyQ","name":"x"}]}"#.to_owned();
        for response in [("403 Forbidden", "{}".to_owned()), ("200 OK", without)] {
            let (base, _server) = fake_web_api(vec![response]).await;
            let error = episode_progress_at(&base, "at", &[uri(A)])
                .await
                .unwrap_err();
            assert!(matches!(error, PodcastError::MissingScope), "{error:?}");
        }
    }

    #[tokio::test]
    async fn other_failures_are_typed() {
        let (base, _server) =
            fake_web_api(vec![("500 Internal Server Error", "{}".to_owned())]).await;
        let error = episode_progress_at(&base, "at", &[uri(A)])
            .await
            .unwrap_err();
        assert!(
            matches!(error, PodcastError::Request { status: 500 }),
            "{error:?}"
        );

        let (base, _server) = fake_web_api(vec![("200 OK", "<html>".to_owned())]).await;
        let error = episode_progress_at(&base, "at", &[uri(A)])
            .await
            .unwrap_err();
        assert!(matches!(error, PodcastError::Malformed { .. }), "{error:?}");

        let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let error = episode_progress_at(&base, "at", &[uri(A)])
            .await
            .unwrap_err();
        assert!(matches!(error, PodcastError::Network { .. }), "{error:?}");
    }

    #[tokio::test]
    async fn bad_uris_and_malformed_entries_skip_only_themselves() {
        let body = format!(
            r#"{{"episodes":[{},{{"id":"x","resume_point":{{"resume_position_ms":null}}}},{{"id":5}},{}]}}"#,
            episode(A, 7, false),
            r#"{"id":"4rOoJ6Egrf8K2IrywzwOMk","name":"no point"}"#,
        );
        let (base, _server) = fake_web_api(vec![("200 OK", body)]).await;
        let uris = ["spotify:track:nope".to_owned(), uri(A), uri(B)];
        let progress = episode_progress_at(&base, "at", &uris).await.unwrap();
        assert_eq!(
            progress,
            [EpisodeProgress {
                uri: uri(A),
                resume_position_ms: 7,
                fully_played: false
            }]
        );
    }

    #[tokio::test]
    async fn non_episode_uris_are_dropped_before_any_request() {
        for bad in [
            "spotify:track:512ojhOuo1ktJprKbVcKyQ",
            "spotify:episode:short",
            "spotify:episode:512ojhOuo1ktJprKbVcKy&",
            "spotify:episode:512ojhOuo1ktJprKbVcKyQ,4rOoJ6Egrf8K2IrywzwOMk",
        ] {
            let progress = episode_progress_at("http://127.0.0.1:9", "at", &[bad.to_owned()])
                .await
                .unwrap();
            assert!(progress.is_empty(), "{bad}");
        }
        assert!(
            episode_progress_at("http://127.0.0.1:9", "at", &[])
                .await
                .unwrap()
                .is_empty()
        );
    }
}
