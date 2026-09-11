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
- A Zendesk account with admin access, to register an OAuth client
- Zendesk OAuth credentials (client ID and client secret)

## Authentication

This server authenticates with **OAuth**, using the client credentials grant.
API token authentication is no longer supported. Zendesk makes OAuth mandatory
for all customers on **1 April 2027**.

The server gets its own access token and keeps it in a cache file. It requests
the maximum lifetime that Zendesk allows, which is 48 hours, and gets a new
token when the old one runs out. No manual step is needed after setup.

| Item | Value |
|---|---|
| Cache file | `~/.cache/zendesk-mcp-server/token.json` (or `$XDG_CACHE_HOME`) |
| File permissions | `0600`, owner only |
| Token lifetime | 48 hours, the Zendesk maximum |

The cache records the domain and client ID that produced the token. If you
change either one, the server discards the cached token automatically. To force
a new token at any time, delete the cache file.

## Setup

### 1. Register an OAuth client

1. Log into your Zendesk Admin Center
2. Go to Apps and integrations > APIs > Zendesk API
3. Open the **OAuth Clients** tab and click **Add OAuth client**
4. Give the client a name and a unique identifier
5. Set the client type to **Confidential**
6. Save, then copy the **secret**. Zendesk shows the secret one time only.

The unique identifier is your `ZENDESK_CLIENT_ID`. The secret is your
`ZENDESK_CLIENT_SECRET`.

The client credentials grant acts as the Zendesk user who owns the OAuth
client. Tickets that this server creates or updates are attributed to that
user.

### 2. Environment Variables

Add the following environment variables to your shell configuration file (e.g., `~/.bashrc`, `~/.zshrc`, or `~/.bash_profile`):

```bash
export ZENDESK_DOMAIN="your-subdomain.zendesk.com"
export ZENDESK_CLIENT_ID="your-oauth-client-identifier"
export ZENDESK_CLIENT_SECRET="your-oauth-client-secret"
```

`ZENDESK_DOMAIN`, `ZENDESK_CLIENT_ID` and `ZENDESK_CLIENT_SECRET` are required.
The server refuses to start if any one of them is missing.

Optionally, restrict what the server can do:

```bash
export ZENDESK_OAUTH_SCOPES="read write"   # this is the default
```

The five tools read and write tickets and read users, so `read write` covers
them all. Narrow this if you only need a subset.

After adding these variables, reload your shell configuration:
```bash
source ~/.bashrc  # or ~/.zshrc, ~/.bash_profile depending on your shell
```

### 3. MCP Configuration

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

1. **`Missing required environment variables`**: The server did not start. Set `ZENDESK_DOMAIN`, `ZENDESK_CLIENT_ID` and `ZENDESK_CLIENT_SECRET`.
2. **`OAuth token request failed: HTTP 401`**: Zendesk rejected the client ID or secret. Confirm both values, and confirm the OAuth client is **Confidential**.
3. **`HTTP 403`** on a tool call: The token is valid but the scope is too narrow. Check `ZENDESK_OAUTH_SCOPES`.
4. **Authentication worked before and now fails**: Delete `~/.cache/zendesk-mcp-server/token.json` and try again. The server mints a new token.
5. **Connection errors**: Verify your ZENDESK_DOMAIN is correct (should be your-subdomain.zendesk.com)
6. **Missing dependencies**: This server uses only Ruby standard library, no gems required

## Testing

```bash
ruby test/test_zendesk_oauth.rb
```

The tests use minitest, which ships with Ruby. No test reaches the network.

## Security

- Store your OAuth credentials securely as environment variables
- Never commit credentials to version control
- Narrow `ZENDESK_OAUTH_SCOPES` to the least privilege your work needs
- The cached token is written with `0600` permissions, readable by you only
- To revoke access, delete the OAuth client in Zendesk Admin Center. This
  invalidates every token it issued.
