# Zendesk MCP Server

A Model Context Protocol (MCP) server that provides integration with Zendesk Support, allowing AI assistants to interact with your Zendesk instance through a standardized interface.

## Features

This MCP server enables the following Zendesk operations:

- **Search tickets** - Search for tickets with custom queries and filters
- **Get ticket details** - Retrieve full details of a specific ticket including comments
- **Create tickets** - Create new support tickets
- **Update tickets** - Update ticket status, priority, or add comments
- **List users** - List Zendesk users with role filtering

## Prerequisites

- Ruby (tested with Ruby 2.7+)
- A Zendesk admin to register one OAuth client, once, for the whole team
- Each developer authorizes their own machine, in their browser, once

## Authentication

This server uses **OAuth**, with the authorization code grant and PKCE. API
token authentication is not supported. Zendesk makes OAuth mandatory for all
customers on **1 April 2027**.

Each developer authorizes their own machine and acts as themselves. Tickets
created or updated through this server are attributed to the developer who did
it, with that developer's own Zendesk permissions.

There is **no client secret**. The OAuth client is registered as public, so
PKCE takes the place of a secret. Nothing confidential is distributed to the
team, and nothing confidential sits in your environment variables.

| Item | Value |
|---|---|
| Token file | `~/.cache/zendesk-mcp-server/token.json` (or `$XDG_CACHE_HOME`) |
| File permissions | `0600`, owner only |
| Access token lifetime | 48 hours, the Zendesk maximum |
| Refresh token lifetime | 90 days, the Zendesk maximum |

After the one-time authorization, the server renews its own access token. You
authorize again only if you do not use the server for 90 days, or if an admin
revokes the token.

When that happens, the server notices and **opens your browser for you**. The
tool call you made returns a message telling you to approve access and run the
request again. You do not have to remember the command.

This is best effort, and deliberately so. On a machine with no browser, or with
`ZENDESK_AUTO_AUTHORIZE=0` set, the server falls back to naming the command
instead. Only one flow starts at a time, however many sessions you have open.

The token file records the domain and client ID that produced it. Change
either one and the server asks you to authorize again, rather than failing in a
confusing way.

## Setup

### 1. Register the OAuth client (admin, once per team)

1. Log into Zendesk Admin Center
2. Go to Apps and integrations > APIs > Zendesk API
3. Open the **OAuth Clients** tab and click **Add OAuth client**
4. Set **Client kind** to **Public**. This is what makes PKCE apply and removes
   the need for a secret.
5. Set **Redirect URLs** to:

   ```
   http://localhost:4567/callback
   ```

6. Under **Allowed scopes**, permit `read` and `tickets:write`, or leave the
   field empty to allow everything. A requested scope outside this list is
   rejected with `Invalid scope`.
7. Save, and share the **unique identifier** with the team. It is not secret.

### 2. Environment Variables

Add the following to your shell configuration file (e.g., `~/.bashrc`, `~/.zshrc`, or `~/.bash_profile`):

```bash
export ZENDESK_DOMAIN="your-subdomain.zendesk.com"
export ZENDESK_CLIENT_ID="the-oauth-client-unique-identifier"
```

Both are required. There is no secret to set.

Two optional variables:

```bash
export ZENDESK_OAUTH_SCOPES="read tickets:write"                # default
export ZENDESK_OAUTH_REDIRECT_URI="http://localhost:4567/callback"  # default
export ZENDESK_AUTO_AUTHORIZE=0                                 # do not open a browser automatically
```

`ZENDESK_OAUTH_REDIRECT_URI` must match a redirect URL registered on the OAuth
client. Change it only if port 4567 is taken, and register the new URL first.

Reload your shell configuration:
```bash
source ~/.bashrc  # or ~/.zshrc, ~/.bash_profile depending on your shell
```

### 3. Authorize your machine (each developer, once)

```bash
ruby zendesk_mcp_server.rb --authorize
```

This opens your browser at Zendesk, where you approve access. The command
prints the link as well, in case no browser opens. After you approve, the
tokens are written to the token file and the command exits.

Run this once per machine. Run it again if the server reports that
authorization is needed.

### 4. MCP Configuration

Configure the MCP server in your `.mcp.json` file. This file tells AI assistants how to connect to this server.

Create or update your `.mcp.json` file (typically located in your project root or home directory) with:

```json
{
  "mcpServers": {
    "zendesk": {
      "command": "ruby",
      "args": ["path/to/zendesk_mcp_server.rb"]
    }
  }
}
```

Replace `path/to/zendesk_mcp_server.rb` with the actual path to the `zendesk_mcp_server.rb` file in this repository.

## Usage

Once configured, AI assistants that support MCP can use this server to interact with your Zendesk instance. The server provides the following tools:

### search_tickets
Search for tickets using Zendesk's search syntax.
- `query`: Search query (required)
- `status`: Filter by status (optional: new, open, pending, hold, solved, closed)
- `limit`: Maximum results to return (optional, default: 25)

### get_ticket
Get detailed information about a specific ticket.
- `ticket_id`: The ticket ID (required)

### create_ticket
Create a new support ticket.
- `subject`: Ticket subject (required)
- `description`: Ticket body (required)
- `requester_email`: Email of the requester (required)
- `priority`: Ticket priority (optional: low, normal, high, urgent)
- `type`: Ticket type (optional: problem, incident, question, task)

### update_ticket
Update an existing ticket.
- `ticket_id`: The ticket ID (required)
- `status`: New status (optional)
- `priority`: New priority (optional)
- `comment`: Add a comment (optional)

### list_users
List Zendesk users.
- `role`: Filter by role (optional: end-user, agent, admin)
- `limit`: Maximum results (optional, default: 25)

## Resources

The server also provides these read-only resources:
- `zendesk://tickets/recent` - Recently updated tickets (last 24 hours)
- `zendesk://users/agents` - List of active support agents

## Troubleshooting

1. **A tool call says a browser has opened**: your stored authorization ran out
   or was revoked. Approve access in the browser, then run the request again.
   If no browser appeared, the link is in
   `~/.cache/zendesk-mcp-server/authorize.log`, or run
   `ruby zendesk_mcp_server.rb --authorize` yourself.
2. **`Missing required environment variables`**: Set `ZENDESK_DOMAIN` and
   `ZENDESK_CLIENT_ID`.
3. **The browser shows an invalid redirect URL**: The redirect URL registered
   on the OAuth client does not match `ZENDESK_OAUTH_REDIRECT_URI`. They must
   be identical, including the port and the path.
4. **`Port 4567 is already in use`**: Something else holds the port. Close it,
   or register a different redirect URL and set `ZENDESK_OAUTH_REDIRECT_URI`.
5. **`Invalid Authorization Request` / `Invalid scope`** in the browser: the
   OAuth client's **Allowed scopes** does not grant everything in
   `ZENDESK_OAUTH_SCOPES`. Widen the client's allowed scopes, clear the field
   to allow all, or narrow the variable. The scope values themselves are
   valid; this is a client configuration problem.
6. **`HTTP 403`** on a tool call:
 Your Zendesk user lacks permission for that
   action, or `ZENDESK_OAUTH_SCOPES` is too narrow.
7. **Authorization keeps being requested**: Check that the token file is
   writable, at `~/.cache/zendesk-mcp-server/token.json`.
8. **Connection errors**: Verify your ZENDESK_DOMAIN is correct (should be your-subdomain.zendesk.com)
9. **Missing dependencies**: This server uses only Ruby standard library, no gems required

## Testing

```bash
ruby test/all.rb            # everything
ruby test/test_zendesk_oauth.rb   # one file
```

The tests use minitest, which ships with Ruby. No test reaches the network.

## Security

- There is no client secret to leak, store, or rotate. PKCE replaces it.
- The client ID is not secret. Sharing it with the team is expected.
- Tokens are per developer. They live only in that developer's token file,
  written with `0600` permissions.
- Every action is attributed to the developer who took it, so the Zendesk
  audit trail stays meaningful.
- `ZENDESK_OAUTH_SCOPES` already defaults to least privilege for these tools.
  Narrow it further if your work needs less.
- To revoke one developer, delete their token in Zendesk Admin Center under
  the OAuth client. Other developers are unaffected.
- Never commit the token file to version control.
