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
ZENDESK_CLIENT_SECRET=yyy \
ruby zendesk_mcp_server.rb
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
ruby test/test_zendesk_oauth.rb
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

**Three classes in one file.** `ZendeskHttp` holds the shared TLS setup, `ZendeskOAuth`
supplies access tokens, and `ZendeskMCPServer` speaks the protocol. The file stays a single
script because MCP client configuration points at one path.

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

OAuth only, using the **client credentials** grant. API token auth was removed. Zendesk
makes OAuth mandatory for all customers on 1 April 2027.

Why this grant and not authorization code:

- Zendesk applies a 30-minute access token expiry by default to clients created on or after
  30 April 2026, so a static token does not work.
- Refresh tokens are single-use and rotated. This server can run as several concurrent
  processes, one per MCP client session, which would race to burn the same refresh token.
  The client credentials grant issues no refresh token, so there is nothing to rotate.

`ZendeskOAuth` caches the token at `~/.cache/zendesk-mcp-server/token.json` with mode
`0600`, and stores the `domain` and `client_id` alongside it. A cache entry is only usable
when both still match, so changing instance or rotating the client invalidates it with no
manual step. No file locking is used, and none is needed: nothing is rotated, so a lost
write costs one extra mint.

Minting is deliberately **lazy**, on the first API call. The MCP client starts this server
on every session, so minting in the constructor would stop the server from starting whenever
Zendesk is unreachable.

`expires_in` is set to 172800 seconds, the documented 48-hour maximum, to keep traffic to
the token endpoint low.

## Zendesk specifics

- `zendesk_request` retries **once** on HTTP 401, after invalidating the cached token.
  Zendesk can revoke a token before it expires, so an expiry check alone is not enough. A
  keyword guard stops the retry from looping.
- `ZendeskHttp.client` sets a custom `verify_callback` that tolerates OpenSSL errors 3 and 4
  (CRL missing / CRL not yet valid) while leaving full certificate verification on. This
  works around SSL failures seen across Ruby versions; do not replace it with
  `VERIFY_NONE`. The token request uses this same helper, and breaks without it.
- The advertised MCP `protocolVersion` is pinned to `"2024-11-05"` in `handle_initialize`.
