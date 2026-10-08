//! Scrubs credentials and personal identifiers from log text. Applied when a
//! record is written and again at export, so a secret registered after a line
//! was logged (for example the username learned at sign-in) is still removed.
//! Every rule maps its own output to itself, so redacting twice is a no-op.

use std::sync::{LazyLock, RwLock};

use regex::Regex;

pub const REDACTED: &str = "<redacted>";
const REDACTED_EMAIL: &str = "<redacted-email>";
/// Earlier redaction output; secrets are never replaced inside these.
const MARKERS: [&str; 2] = [REDACTED, REDACTED_EMAIL];

/// Shorter secrets would shred unrelated text.
const MIN_SECRET_LEN: usize = 3;

static SECRETS: RwLock<Vec<String>> = RwLock::new(Vec::new());

static RULES: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    [
        (r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+", "$1 <redacted>"),
        (
            r#"(?i)("?\b(?:access_token|refresh_token|auth_token|client_secret|password|auth_data|auth_blob|blob|client_?key|code_verifier|username|user_name)\b"?\s*[:=]\s*)(?:"[^"\n]*"|'[^'\n]*'|\[[^\]\n]*\]|[^\s,;&)}\]]+)"#,
            "${1}<redacted>",
        ),
        // OAuth callback and PKCE parameters; a bare `code` key is too common
        // elsewhere ("status code: 400"), so only the URL/form form matches.
        (
            r#"([?&](?:code|state|code_verifier|code_challenge)=)[^&\s#"']+"#,
            "${1}<redacted>",
        ),
        // librespot: "Authenticated as 'name'", "Login error for user \"name\"".
        (r#"(?i)\b(as|user)\s+(?:'[^'\n]*'|"[^"\n]*")"#, "$1 '<redacted>'"),
        (r#"spotify:user:[^\s:"']+"#, "spotify:user:<redacted>"),
        // spclient request paths (`/profile/<name>`, `/user/<name>/rootlist`)
        // and the macOS account name in home-directory paths.
        (r#"(?i)(/(?:users?|profile)/)[^/?\s"']+"#, "${1}<redacted>"),
        (
            r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
            REDACTED_EMAIL,
        ),
    ]
    .into_iter()
    .map(|(pattern, replacement)| (Regex::new(pattern).expect("valid redaction rule"), replacement))
    .collect()
});

static BASE64_RUN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z0-9+/]{48,}={0,2}").expect("valid base64 rule"));

/// Opaque tokens: Spotify access/refresh tokens are long base64url. Track and
/// file IDs are 22-40 chars and stay readable. Runs after [`BASE64_RUN`] so a
/// standard base64 blob is replaced whole, not cut at its `+` and `/`.
static OPAQUE_TOKEN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z0-9_-]{48,}").expect("valid token rule"));

/// A run with `/` is a path unless every long segment holds a digit or `+`;
/// random base64 almost always does, words like `Frameworks` never do.
fn is_base64_blob(run: &str) -> bool {
    run.split('/')
        .filter(|segment| segment.len() >= 8)
        .all(|segment| segment.bytes().any(|b| b.is_ascii_digit() || b == b'+'))
}

/// Registers a value (such as the signed-in username) to scrub verbatim.
pub fn add_secret(secret: &str) {
    let secret = secret.trim();
    if secret.len() < MIN_SECRET_LEN {
        return;
    }
    let mut secrets = SECRETS.write().unwrap_or_else(|e| e.into_inner());
    if !secrets.iter().any(|s| s == secret) {
        secrets.push(secret.to_owned());
        // Longest first, so a secret containing another is replaced whole.
        secrets.sort_by_key(|s| std::cmp::Reverse(s.len()));
    }
}

/// Export re-redacts written lines, so a secret like `act` must not rewrite
/// `<redacted>` into `<red<redacted>ed>`.
fn replace_outside_markers(text: &str, secret: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        let next = MARKERS
            .iter()
            .filter_map(|m| rest.find(m).map(|i| (i, m.len())))
            .min();
        let (start, len) = next.unwrap_or((rest.len(), 0));
        out.push_str(&rest[..start].replace(secret, REDACTED));
        if len == 0 {
            return out;
        }
        out.push_str(&rest[start..start + len]);
        rest = &rest[start + len..];
    }
}

pub fn redact(text: &str) -> String {
    let secrets = SECRETS.read().unwrap_or_else(|e| e.into_inner());
    redact_with(text, &secrets)
}

pub fn redact_with(text: &str, secrets: &[String]) -> String {
    let mut out = text.to_owned();
    for secret in secrets {
        out = replace_outside_markers(&out, secret);
    }
    for (rule, replacement) in RULES.iter() {
        if rule.is_match(&out) {
            out = rule.replace_all(&out, *replacement).into_owned();
        }
    }
    let out = BASE64_RUN.replace_all(&out, |caps: &regex::Captures| {
        let run = &caps[0];
        if is_base64_blob(run) { REDACTED } else { run }.to_owned()
    });
    OPAQUE_TOKEN.replace_all(&out, REDACTED).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "BQDx7f3kP9qLmN2vR8sT4uW6yZ0aB1cD3eF5gH7iJ9kL1mN3oP5qR7sT9uV1wX3yZ5";

    fn r(text: &str) -> String {
        redact_with(text, &[])
    }

    #[test]
    fn scrubs_librespot_username_lines() {
        assert_eq!(
            r("Authenticated as 'alice99' !"),
            "Authenticated as '<redacted>' !"
        );
        assert_eq!(
            r(r#"Login error for user "alice99": MAC mismatch"#),
            "Login error for user '<redacted>': MAC mismatch"
        );
    }

    #[test]
    fn scrubs_key_value_credentials() {
        let cases = [
            ("access_token=abc123&x=1", "access_token=<redacted>&x=1"),
            (
                r#"{"refresh_token": "abc"}"#,
                r#"{"refresh_token": <redacted>}"#,
            ),
            ("password: hunter2, ok", "password: <redacted>, ok"),
            ("Username = bob", "Username = <redacted>"),
        ];
        for (input, expected) in cases {
            assert_eq!(r(input), expected, "input: {input}");
        }
    }

    #[test]
    fn scrubs_bearer_and_opaque_tokens() {
        assert_eq!(
            r(&format!("Authorization: Bearer {TOKEN}")),
            "Authorization: Bearer <redacted>"
        );
        assert_eq!(
            r(&format!("Got token: Token {{ {TOKEN} }}")),
            "Got token: Token { <redacted> }"
        );
    }

    #[test]
    fn scrubs_oauth_callback_and_pkce_params() {
        assert_eq!(
            r("GET /login?code=AQBx-1_9&state=Zk3q HTTP/1.1"),
            "GET /login?code=<redacted>&state=<redacted> HTTP/1.1"
        );
        assert_eq!(
            r("authorize?client_id=abc&code_challenge=E9Mel&code_challenge_method=S256"),
            "authorize?client_id=abc&code_challenge=<redacted>&code_challenge_method=S256"
        );
        assert_eq!(
            r("grant_type=authorization_code&code=AQB&code_verifier=dBjf"),
            "grant_type=authorization_code&code=<redacted>&code_verifier=<redacted>"
        );
        assert_eq!(r("code_verifier: dBjf"), "code_verifier: <redacted>");
        assert_eq!(r("status code: 400"), "status code: 400");
    }

    #[test]
    fn scrubs_user_uris_and_emails() {
        assert_eq!(
            r("spotify:user:alice99:collection"),
            "spotify:user:<redacted>:collection"
        );
        assert_eq!(r("mail alice@example.com now"), "mail <redacted-email> now");
    }

    #[test]
    fn scrubs_usernames_in_request_and_home_paths() {
        assert_eq!(
            r(
                "Requesting https://spclient.wg.spotify.com/user-profile-view/v3/profile/alice99?market=from_token"
            ),
            "Requesting https://spclient.wg.spotify.com/user-profile-view/v3/profile/<redacted>?market=from_token"
        );
        assert_eq!(
            r("GET /playlist/v2/user/alice99/rootlist"),
            "GET /playlist/v2/user/<redacted>/rootlist"
        );
        assert_eq!(
            r("open /Users/jane/Library/Containers/app.veya/Data/Library/Logs/Veya failed"),
            "open /Users/<redacted>/Library/Containers/app.veya/Data/Library/Logs/Veya failed"
        );
    }

    #[test]
    fn scrubs_zeroconf_add_user_params() {
        let blob = "u3RkRmYh+9k/Pq2Wz8xVb1LmN0aT5cQe7yHf4GjK6sD9oP2rI8wE1zX3vB5nM7lA0qS==";
        let line = format!(r#"{{"blob": "{blob}", "clientKey": "abc+/def", "userName": "alice"}}"#);
        assert_eq!(
            r(&line),
            r#"{"blob": <redacted>, "clientKey": <redacted>, "userName": <redacted>}"#
        );
        assert_eq!(r(&format!("raw {blob} end")), "raw <redacted> end");
    }

    #[test]
    fn quoted_rules_never_span_lines() {
        let text = "Login as \"half quoted\nkeep me\nuser \"bob\"\n";
        assert_eq!(
            r(text),
            "Login as \"half quoted\nkeep me\nuser '<redacted>'\n"
        );
    }

    #[test]
    fn keeps_track_ids_and_ordinary_text() {
        let line = "Loading <spotify:track:4uLU6hMCjMI75M1A2tKUQC> file 0123456789abcdef0123456789abcdef01234567 \
                    from /Applications/Veya.app/Contents/Frameworks/SomeVeryLongFrameworkName/Versions/A";
        assert_eq!(r(line), line);
    }

    #[test]
    fn scrubs_registered_secrets_longest_first() {
        let secrets = vec!["alice99x".to_owned(), "alice".to_owned()];
        assert_eq!(
            redact_with("alice99x and alice", &secrets),
            "<redacted> and <redacted>"
        );
    }

    #[test]
    fn secrets_never_rewrite_earlier_markers() {
        let secrets = vec!["act".to_owned(), "email".to_owned()];
        let once = redact_with("act mail a@b.io", &secrets);
        assert_eq!(once, "<redacted> mail <redacted-email>");
        assert_eq!(redact_with(&once, &secrets), once);
    }

    #[test]
    fn scrubs_debug_formatted_byte_arrays() {
        assert_eq!(
            r("Credentials { username: Some(\"x\"), auth_data: [1, 2, 3] }"),
            "Credentials { username: <redacted>), auth_data: <redacted> }"
        );
    }

    #[test]
    fn redaction_is_idempotent() {
        let inputs = [
            "Authenticated as 'alice99' !".to_owned(),
            format!("Bearer {TOKEN} access_token={TOKEN} alice@example.com spotify:user:bob"),
            r#"{"password": "x y"}"#.to_owned(),
            "GET /user/alice/rootlist from /Users/jane/x".to_owned(),
            "/login?code=abc&state=def".to_owned(),
        ];
        for input in inputs {
            let once = r(&input);
            assert_eq!(r(&once), once, "input: {input}");
        }
    }
}
