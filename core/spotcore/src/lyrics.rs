//! Track lyrics from spclient's color-lyrics endpoint.

use librespot_core::error::ErrorKind;
use librespot_core::{Session, SpotifyUri};
use serde::Deserialize;

use crate::metadata::MetadataError;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Lyrics {
    /// False when lines carry no timing and show as static text.
    pub synced: bool,
    pub lines: Vec<LyricsLine>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LyricsLine {
    /// 0 for every line of unsynced lyrics.
    pub start_ms: u32,
    pub words: String,
}

// Decoded here rather than with librespot_metadata::Lyrics, whose every field
// is required, so a reply missing e.g. `colors` would fail as a whole.
#[derive(Deserialize)]
struct Reply {
    lyrics: Inner,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Inner {
    sync_type: String,
    lines: Vec<Line>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Line {
    /// Milliseconds as a decimal string.
    start_time_ms: String,
    words: String,
}

/// `None` when Spotify has no lyrics for the track.
pub(crate) async fn fetch(
    session: &Session,
    track_uri: &str,
) -> Result<Option<Lyrics>, MetadataError> {
    let id = match SpotifyUri::from_uri(track_uri) {
        Ok(SpotifyUri::Track { id }) => id,
        Ok(_) => {
            return Err(MetadataError::UnsupportedKind {
                uri: track_uri.to_owned(),
            });
        }
        Err(e) => {
            return Err(MetadataError::InvalidUri {
                message: e.to_string(),
            });
        }
    };
    match session.spclient().get_lyrics(&id).await {
        Ok(body) => decode(&body),
        Err(e) if e.kind == ErrorKind::NotFound => Ok(None),
        Err(e) => Err(MetadataError::Request {
            message: e.to_string(),
        }),
    }
}

fn decode(body: &[u8]) -> Result<Option<Lyrics>, MetadataError> {
    if body.is_empty() {
        return Ok(None);
    }
    let reply: Reply = serde_json::from_slice(body).map_err(|e| MetadataError::Request {
        message: format!("malformed lyrics: {e}"),
    })?;
    let synced = reply.lyrics.sync_type != "UNSYNCED";
    let lines: Vec<_> = reply
        .lyrics
        .lines
        .into_iter()
        .map(|line| LyricsLine {
            start_ms: if synced {
                line.start_time_ms.parse().unwrap_or(0)
            } else {
                0
            },
            words: line.words,
        })
        .collect();
    Ok((!lines.is_empty()).then_some(Lyrics { synced, lines }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(start_ms: u32, words: &str) -> LyricsLine {
        LyricsLine {
            start_ms,
            words: words.into(),
        }
    }

    #[test]
    fn decodes_line_synced_lyrics() {
        let body = br#"{"lyrics":{"syncType":"LINE_SYNCED","lines":[
            {"startTimeMs":"960","words":"First","endTimeMs":"0","syllables":[]},
            {"startTimeMs":"4200","words":"Second","endTimeMs":"0"}]},"colors":{}}"#;
        assert_eq!(
            decode(body).unwrap(),
            Some(Lyrics {
                synced: true,
                lines: vec![line(960, "First"), line(4200, "Second")]
            })
        );
    }

    #[test]
    fn unsynced_lyrics_have_no_timing() {
        let body =
            br#"{"lyrics":{"syncType":"UNSYNCED","lines":[{"startTimeMs":"0","words":"Only"}]}}"#;
        assert_eq!(
            decode(body).unwrap(),
            Some(Lyrics {
                synced: false,
                lines: vec![line(0, "Only")]
            })
        );
    }

    #[test]
    fn empty_body_or_no_lines_means_no_lyrics() {
        assert_eq!(decode(b"").unwrap(), None);
        assert_eq!(
            decode(br#"{"lyrics":{"syncType":"LINE_SYNCED","lines":[]}}"#).unwrap(),
            None
        );
    }

    #[test]
    fn malformed_reply_is_a_request_error() {
        assert!(matches!(decode(b"{"), Err(MetadataError::Request { .. })));
    }
}
