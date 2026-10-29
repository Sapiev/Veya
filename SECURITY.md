# Security Policy

Veya is an unofficial Spotify client; please help keep users safe by
reporting security issues responsibly.

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.** Instead, use
GitHub's private vulnerability reporting: go to the repository's **Security**
tab → **Report a vulnerability** to open a private advisory with the
maintainers.

Please include:

- A description of the vulnerability and its potential impact.
- Steps to reproduce (minimal proof of concept if possible).
- Affected version/commit.

## Scope

In scope: credential handling (Keychain storage, OAuth/PKCE flow), the Rust
core (`spotcore`)/FFI boundary, the release and update pipeline, and anything
that could leak account tokens or user data.

Caches are not encrypted by Veya. The metadata cache
(`Caches/<bundle id>/Metadata.sqlite`, ADR-0008) is plaintext SQLite protected
only by the app sandbox and file permissions. The audio cache keeps librespot's
own AES encryption, which is Spotify's DRM and not protection for user data.

## Supported versions

Only the latest stable release receives security fixes; the beta channel gets
them in the next beta.

## Release trust model

Releases are self-signed and not notarized (no paid Apple account), so macOS
asks the user to approve the app once, and the Homebrew cask tells users to
clear quarantine. Updates are delivered by Sparkle over https and each archive
is verified against the Ed25519 public key built into the app
(`SUPublicEDKey`). The appcast itself is not signed yet, so a tampered feed
cannot install code but could alter release notes or withhold updates. The
release build adds `com.apple.security.cs.disable-library-validation` because a
self-signed certificate has no Team ID for library validation to match against
Sparkle.framework; the sandbox still bounds what the app can do. Release
secrets sit behind a protected GitHub environment and the signing key never
leaves CI.

Out of scope: issues solely in librespot itself (report upstream at
[librespot-org/librespot](https://github.com/librespot-org/librespot)) and
vulnerabilities requiring a jailbroken/compromised device.

## Response

If private reporting is unavailable, contact the maintainer through the email
on the GitHub profile of the repository owner, without technical details, and
ask for a private channel.

Maintainers aim to acknowledge reports within 5 business days and will work
with the reporter on a fix and disclosure timeline before any public
advisory is published.
