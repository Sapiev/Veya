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
core (`spotcore`)/FFI boundary, cache encryption, and anything that could
leak account tokens or user data.

Out of scope: issues solely in librespot itself (report upstream at
[librespot-org/librespot](https://github.com/librespot-org/librespot)) and
vulnerabilities requiring a jailbroken/compromised device.

## Response

Maintainers aim to acknowledge reports within 5 business days and will work
with the reporter on a fix and disclosure timeline before any public
advisory is published.
