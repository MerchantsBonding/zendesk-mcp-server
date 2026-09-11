# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A Model Context Protocol (MCP) server that exposes Zendesk Support to MCP clients. The whole
server is one file: `zendesk_mcp_server.rb`. There is no build step and no linter configured.

## Commands

Run the server (it waits on STDIN for JSON-RPC lines):

```bash
ZENDESK_DOMAIN=your-subdomain.zendesk.com \
ZENDESK_CLIENT_ID=xxx \
ruby zendesk_mcp_server.rb
```

There is no client secret. The OAuth client is public and PKCE replaces it.

Authorize a machine (interactive, opens a browser, writes the token file):

```bash
ZENDESK_DOMAIN=... ZENDESK_CLIENT_ID=... ruby zendesk_mcp_server.rb --authorize
```

Smoke-test a single request without an MCP client:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ruby zendesk_mcp_server.rb
```

Swap `tools/list` for `initialize`, `resources/list`, or a full `tools/call` request to
exercise a specific handler. Env vars must be set even for methods that never reach the
Zendesk API, because `validate_configuration!` runs in the constructor.

Run the tests (minitest, ships with Ruby, no network access):

```bash
ruby test/all.rb                   # everything
ruby test/test_zendesk_oauth.rb    # one file
```

Syntax check: `ruby -c zendesk_mcp_server.rb`

## Architecture

**Hand-rolled protocol.** No MCP SDK or HTTP client gem is used. The JSON-RPC 2.0 framing,
the method dispatch, and the Zendesk REST calls are all written directly on Ruby's standard
library (`net/http`, `json`, `base64`). The `Gemfile` pins `json` and `logger`, but nothing
outside stdlib is required.

**STDOUT is the wire.** `run` reads one JSON object per line from STDIN and writes one
response object per line to STDOUT. Anything else printed to STDOUT corrupts the protocol
stream and breaks the client. All diagnostics go through `@logger`, which writes to STDERR.

**Entry point plus `lib/`.** `zendesk_mcp_server.rb` holds the protocol server and the CLI
entry point. The auth machinery lives beside it:

| File | Responsibility |
|---|---|
| `lib/zendesk_http.rb` | Shared TLS setup, including the CRL workaround |
| `lib/zendesk_pkce.rb` | PKCE verifier and S256 challenge |
| `lib/zendesk_token_store.rb` | Reads, writes and **locks** the token file |
| `lib/zendesk_oauth.rb` | Supplies access tokens, refreshes them |
| `lib/zendesk_authorizer.rb` | The one-time `--authorize` browser flow |
| `lib/zendesk_authorization_launcher.rb` | Starts that flow in the background when a call finds no auth |

Each has one job, so the locking and the refresh rules can be tested without a network or
a browser.

**Three layers inside the server class:**

1. `handle_request` dispatches on the JSON-RPC `method` string to `handle_initialize`,
   `handle_tools_list`, `handle_tools_call`, `handle_resources_list`, `handle_resources_read`.
2. Tool methods (`search_tickets`, `get_ticket`, `create_ticket`, `update_ticket`,
   `list_users`) translate MCP arguments into a Zendesk endpoint and payload. They return
   plain Ruby hashes.
3. `zendesk_request` builds the HTTPS call, attaches Basic auth, and parses the response.

**Adding a tool requires three coordinated edits:** the JSON Schema entry in
`handle_tools_list`, the `when` branch in `handle_tools_call`, and the implementation method.
Missing any one of them produces a tool that is either invisible to clients or answers
"Unknown tool".

**Errors are returned as data, not raised.** `zendesk_request` rescues every exception and
returns `{ error: ... }`. `handle_tools_call` then wraps that hash in a normal JSON-RPC
`result`. A failed Zendesk call therefore reaches the client as a successful MCP response
whose text content describes the failure. Only malformed JSON and unhandled exceptions in the
read loop produce real JSON-RPC `error` objects.

**Resources reuse the tool methods.** `zendesk://tickets/recent` and `zendesk://users/agents`
call `search_tickets` and `list_users` with canned arguments, so changes to those methods
change the resources too.

## Authentication

OAuth with the **authorization code grant and PKCE**, against a **public** OAuth client.
There is no client secret anywhere in this project. Zendesk makes OAuth mandatory for all
customers on 1 April 2027.

Each developer authorizes their own machine, so every API call carries that developer's
identity and permissions. This replaced an earlier client credentials implementation, which
worked but attributed every action to one service account.

**`--authorize` flow** (`ZendeskAuthorizer`): generate a PKCE verifier and S256 challenge,
open the consent page, listen on `http://localhost:4567/callback` for exactly one request,
check the `state`, then exchange the code plus the verifier for tokens.

The redirect URL must be **pre-registered** on the OAuth client, so the port is fixed rather
than chosen at run time. `ZENDESK_OAUTH_REDIRECT_URI` overrides it, but a matching URL must
be registered first.

**Automatic recovery** (`ZendeskAuthorizationLauncher`): when a tool call raises
`AuthorizationRequired`, the server starts the browser flow in the background and
returns a message asking for the request to be retried. It never blocks, because a
blocking tool call would hit the MCP client timeout and would hang outright in a
headless session. Guards: `ZENDESK_AUTO_AUTHORIZE=0` disables it, no browser means
no launch, and a timestamp marker under a short lock keeps concurrent server
processes from opening several browsers and fighting over port 4567.

**Runtime** (`ZendeskOAuth`): never prompts. It refreshes with the stored refresh token, and
raises `AuthorizationRequired` naming the `--authorize` command when it cannot. Both
lifetimes are requested at the Zendesk maximum, 48 hours and 90 days, instead of the
defaults of 30 minutes and 30 days.

### Three things that will bite if changed carelessly

**Refresh tokens are single-use and rotated.** An MCP client starts one server process per
session, so several can run at once. `ZendeskOAuth#access_token` therefore takes an
exclusive `flock` and then **re-reads the token file inside the lock**. Without that second
read, two processes spend the same refresh token and the loser is left holding one Zendesk
has already retired. `test_a_refresh_by_another_process_is_adopted_instead_of_repeated`
covers this; do not delete it.

**The launcher must never write to STDOUT, and neither may its child.**
`ZendeskAuthorizationLauncher` runs inside the server, where STDOUT is the JSON-RPC
wire. A process spawned without explicit redirection inherits that stream and
corrupts every response. `spawn_options` therefore sends the child's output to
`~/.cache/zendesk-mcp-server/authorize.log` and sets `pgroup: true`.
`test_the_child_never_inherits_the_protocol_stream` covers this; do not delete it.

Note that `ZendeskAuthorizer` still defaults `io:` to `$stdout`, which is correct
for the CLI path and wrong inside the server. The launcher avoids the problem by
spawning a separate process rather than calling the authorizer in-process.

**`invalidate!` must keep the refresh token.** It expires only the access token. Clearing
both on a 401 would force the developer through the browser flow again for what is usually
a revoked or stale access token.

## Zendesk specifics

- `zendesk_request` retries **once** on HTTP 401, after invalidating the access token.
  Zendesk can revoke a token before it expires, so an expiry check alone is not enough. A
  keyword guard stops the retry from looping.
- `ZendeskHttp.client` sets a custom `verify_callback` that tolerates OpenSSL errors 3 and 4
  (CRL missing / CRL not yet valid) while leaving full certificate verification on. This
  works around SSL failures seen across Ruby versions; do not replace it with
  `VERIFY_NONE`. The token requests use this same helper, and break without it.
- The authorization endpoint is `/oauth/authorizations/new`. Zendesk's own docs disagree
  here, with one page giving `/oauth/authorize`. If the consent page 404s, try that instead:
  it is the `AUTHORIZE_PATH` constant.
- Scope values are percent-encoded with `%20` rather than `+`. Both are valid form encoding,
  but not every OAuth endpoint accepts `+`.
- `CGI.parse` does not exist in Ruby 4.0. Use `URI.decode_www_form`.
- The advertised MCP `protocolVersion` is pinned to `"2024-11-05"` in `handle_initialize`.
