# ADR-005: Premium check before the access-point login

- Status: Accepted
- Date: 2026-10-09

## Context

PBI-105 requires a non-Premium account to see an explanation and a way to
sign out. librespot cannot support this flow. When the access point sends
the ProductInfo packet with a `type` other than `premium`,
`Session::check_catalogue` calls `std::process::exit(1)`. This is true for
the pinned rev and for upstream `dev` (marked `TODO: logout instead of
exiting`). The app quits before `spotcore` or Swift can react.

We considered three options:

- Fork librespot and remove the exit. This covers every login path, but the
  project must then maintain a fork.
- Vendor a patched `librespot-core` in the repository. This also covers
  every login path, but adds about 10k lines that must be kept in sync.
- Read the product from the Web API before connecting. This needs no
  librespot change, but it covers only a fresh sign-in.

## Decision

1. After OAuth sign-in, and before `SpotSession::connect_with_token`, Swift
   calls `spotcore::is_premium_account(access_token)`. This function sends
   `GET https://api.spotify.com/v1/me` and compares `product` with
   `premium`. The `user-read-private` scope is already requested (ADR-002).
2. A non-Premium product sets `SessionState.notPremium`. The app does not
   connect and does not save credentials. It shows an explanation screen
   with Sign Out.
3. A failed check does not block sign-in. Examples are a network error, a
   non-2xx status (such as a user-supplied Client ID over its Development
   Mode user limit), or a missing `product`. The app logs a warning and
   connects. A Premium user must never be locked out by a Web API failure.
4. The request does not follow redirects and trusts only the keychain
   roots, the same as the token exchange. Errors contain the HTTP status
   only, never the response body.

## Consequences

- Restoring saved credentials and reconnecting still log in without a
  check. If the account is downgraded after sign-in, librespot still exits
  the app at the next login. The same happens on a fresh sign-in when the
  check fails and the account is not Premium.
- This is the app's first Web API call. It is one request for each sign-in,
  which keeps it inside the "Web API only where unavoidable" constraint.
- If upstream librespot replaces the exit with an error, remove this check.
  Then read `type` from the session's user attributes in all login paths.
