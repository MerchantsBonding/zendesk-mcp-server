# Migrate Zendesk authentication from API tokens to OAuth

> **Superseded on 2026-09-11** by
> [per-developer identity](2026-09-11-zendesk-oauth-per-developer-identity.md).
> The client credentials grant described here was implemented, then replaced,
> because it attributes every action to one service account.

Date: 2026-09-11
Status: Approved

## Problem

The server authenticates with an API token, sent as HTTP Basic credentials in the
form `email/token:api_token`. Zendesk is retiring this method. OAuth becomes
mandatory for all customers on **April 1, 2027**.

Two Zendesk rules shape the solution:

- OAuth clients created on or after **April 30, 2026** expire access tokens after
  30 minutes by default. A static token is therefore not viable.
- Refresh tokens are **single-use and rotated**. Two concurrent processes that
  refresh with the same stored token destroy each other's credentials.

## Decision

Use the **client credentials** grant.

The server runs locally and acts as one person. The client credentials grant
returns no refresh token, so the rotation hazard disappears. Several Claude Code
sessions can run this server at the same time, and each can mint its own token
safely.

Rejected alternatives:

- **Authorization code with PKCE.** Correct for many users, but it needs a browser
  flow, a callback listener, a lock file to guard refresh rotation, and
  re-authorization every 90 days. The identity benefit is nil for a single user.
- **Static OAuth token.** Breaks after 30 minutes with any client registered today.

This is a **hard cutover**. The API token path is deleted.

## Configuration

| Variable | Required | Purpose |
|---|---|---|
| `ZENDESK_DOMAIN` | yes | unchanged |
| `ZENDESK_CLIENT_ID` | yes | OAuth client unique identifier |
| `ZENDESK_CLIENT_SECRET` | yes | OAuth client secret |
| `ZENDESK_OAUTH_SCOPES` | no | defaults to `read write` |

`ZENDESK_EMAIL` and `ZENDESK_API_TOKEN` are removed. This also removes the defect
where `validate_configuration!` reads `ZENDESK_API_TOKEN` but reports the missing
variable as `ZENDESK_TOKEN`.

## Component: ZendeskOAuth

A second class in `zendesk_mcp_server.rb`. The file stays a single script, because
the MCP client configuration points at one path.

Responsibility: return a valid bearer token.

- `access_token` returns a cached token, or mints one.
- `invalidate!` deletes the cached token.

### Token cache

- Path: `$XDG_CACHE_HOME/zendesk-mcp-server/token.json`, or
  `~/.cache/zendesk-mcp-server/token.json`.
- File mode `0600`. The directory is created on demand.
- Fields: `access_token`, `expires_at` (absolute epoch seconds), `domain`,
  `client_id`.
- A cache entry is valid only when `domain` and `client_id` match the current
  configuration. Changing the Zendesk instance or rotating the client therefore
  invalidates the cache without manual action.
- A token counts as expired 60 seconds early, to absorb clock skew.
- Unreadable, corrupt, or partial cache files are treated as a cache miss, never
  as an error.

No file locking is needed. Tokens are not rotated, so a lost write costs one
extra mint, and both tokens stay valid.

### Minting

`POST https://{domain}/oauth/tokens` with a JSON body:

    grant_type    = client_credentials
    client_id     = ZENDESK_CLIENT_ID
    client_secret = ZENDESK_CLIENT_SECRET
    scope         = ZENDESK_OAUTH_SCOPES (default "read write")
    expires_in    = 172800

`expires_in` is the documented maximum of 48 hours, instead of the 30 minute
default. This minimises how often the server contacts the token endpoint.

Minting is **lazy**. It happens on the first API call, not in the constructor.
The MCP client starts this server on every session. Minting at startup would
prevent the server from starting whenever Zendesk is unreachable.

## Request path

- `zendesk_request` sends `Authorization: Bearer <token>`.
- The Basic authentication header and the `base64` requirement are removed.
- On HTTP **401**, the server invalidates the cache, mints once, and retries the
  request one time. Expiry checks alone are not sufficient, because a token can be
  revoked in Zendesk at any time. A guard parameter prevents more than one retry.
- Failures remain data, not exceptions, which matches the existing convention.
  A rejected credential returns `{"error": "OAuth token request failed: ..."}`.

## Shared TLS setup

The TLS configuration, including the `verify_callback` that tolerates CRL errors 3
and 4, moves from `zendesk_request` into a shared `http_client(uri)` helper. The
token request uses the same helper.

This is required, not cosmetic. Without it the token request fails with the same
SSL error that commit `eca32f9` fixed for the API requests.

## Testing

The repository has no tests. Add a minitest suite. Minitest ships with Ruby, so
the Gemfile does not change.

`ZendeskOAuth` takes an injectable HTTP caller, so no test reaches the network.

Cases:

- a valid cached token is reused, and no mint occurs
- an expired cached token is replaced
- a token inside the 60 second skew window counts as expired
- a cache whose `domain` or `client_id` differs is rejected
- a corrupt cache file is treated as a miss
- the mint body carries the correct `grant_type`, `scope`, and `expires_in`
- the cache file is written with mode `0600`
- a 401 causes exactly one re-mint and one retry
- a second consecutive 401 returns an error and does not loop

Run: `ruby test/test_zendesk_oauth.rb`

## Files

- `zendesk_mcp_server.rb` — auth rewrite
- `test/test_zendesk_oauth.rb` — new
- `README.md` — OAuth client registration and setup steps
- `CLAUDE.md` — auth architecture, and removal of the known-quirk section
