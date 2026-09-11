# Per-developer identity for the Zendesk MCP server

Date: 2026-09-11
Status: Approved
Supersedes: [2026-09-11-zendesk-oauth-design.md](2026-09-11-zendesk-oauth-design.md)

## Problem

The client credentials grant authenticates as the single Zendesk user who owns
the OAuth client. Every ticket this server creates or updates is attributed to
that one account, whichever developer acted. The audit trail cannot tell them
apart, and every developer inherits that account's permissions.

## Decision

Use the **authorization code grant with PKCE**, against a **public** OAuth
client. Remove the client credentials path.

Each developer authorizes their own machine once, in a browser, and every later
call carries their identity and their permissions.

A public client has no secret. PKCE takes its place, so nothing confidential is
distributed to the team or held in anyone's environment.

Keeping both grants was rejected. The client credentials grant requires a
secret, which would force a confidential client, and the secret would then have
to be distributed and rotated across the team. That is most of what this change
removes.

## Configuration

| Variable | Required | Purpose |
|---|---|---|
| `ZENDESK_DOMAIN` | yes | unchanged |
| `ZENDESK_CLIENT_ID` | yes | OAuth client unique identifier, not secret |
| `ZENDESK_OAUTH_SCOPES` | no | defaults to `read write` |
| `ZENDESK_OAUTH_REDIRECT_URI` | no | defaults to `http://localhost:4567/callback` |

`ZENDESK_CLIENT_SECRET` is removed.

## Components

The auth code moved out of the entry point into `lib/`, because one file holding
the protocol server, the browser flow, the token store and the refresh rules had
grown too large to read.

| File | Responsibility |
|---|---|
| `lib/zendesk_http.rb` | Shared TLS setup, including the CRL workaround |
| `lib/zendesk_pkce.rb` | Verifier and S256 challenge |
| `lib/zendesk_token_store.rb` | Reads, writes and locks the token file |
| `lib/zendesk_oauth.rb` | Supplies access tokens, refreshes them |
| `lib/zendesk_authorizer.rb` | The one-time `--authorize` flow |

## Authorization flow

1. Generate a PKCE verifier of 43 to 128 characters, and the S256 challenge.
2. Generate an unpredictable `state`.
3. Bind a listener on the redirect host and port.
4. Open the browser at `/oauth/authorizations/new`, and print the link too.
5. Serve exactly one request. Check `state`. Answer the browser either way, so
   the developer sees the outcome on the page.
6. Exchange the code and the verifier for tokens, and store them.

The redirect URL must be pre-registered on the OAuth client, so the port is
fixed rather than chosen at run time.

## Refresh, and the concurrency hazard

Zendesk rotates refresh tokens and accepts each one only once.

An MCP client starts one server process per session, so several run at the same
time. `access_token` therefore:

1. Reads the token file. Returns the access token if it is still fresh.
2. Otherwise takes an exclusive lock on a separate lock file.
3. **Reads the token file again, inside the lock.** Another process may have
   refreshed while this one waited. This second read is what stops two processes
   from spending the same single-use token.
4. Refreshes only if the record is still stale, and stores the rotated refresh
   token.

Both lifetimes are requested at the Zendesk maximum: 48 hours for the access
token, 90 days for the refresh token.

`invalidate!` expires only the access token and keeps the refresh token.
Clearing both on a 401 would force a browser round trip for what is usually just
a revoked access token.

When no refresh is possible, `AuthorizationRequired` is raised naming the
`--authorize` command, and the server returns that message as the tool result.

## Testing

`ruby test/all.rb`. Minitest, no gems, no network, no browser.

Cases that must not be deleted:

- a refresh by another process is adopted rather than repeated (the lock
  behaviour above)
- the rotated refresh token replaces the old one
- `invalidate!` keeps the refresh token
- the lock excludes a genuinely separate process
- neither the authorization URL nor either token request carries a client secret
- a mismatched or missing `state` is rejected
- the callback listener answers the browser on success and on failure

## Known documentation conflict

Zendesk documents two authorization endpoints. `/oauth/authorizations/new`
appears in the migration guide and the refresh token guide; `/oauth/authorize`
appears in the PKCE guide. This implementation uses the former, as the
`AUTHORIZE_PATH` constant. If the consent page returns 404, try the other.
