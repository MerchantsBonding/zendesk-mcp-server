#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'uri'
require 'logger'
require_relative 'lib/zendesk_oauth'
require_relative 'lib/zendesk_authorizer'
require_relative 'lib/zendesk_token_store'
require_relative 'lib/zendesk_http'

class ZendeskMCPServer
  # Reads the scopes to request. Narrowing these limits what the MCP server can
  # do with the developer's own Zendesk permissions.
  def self.configured_scopes
    scopes = ENV['ZENDESK_OAUTH_SCOPES']
    return ZendeskOAuth::DEFAULT_SCOPES if scopes.to_s.empty?

    scopes
  end

  # Must match a redirect URL registered on the OAuth client.
  def self.configured_redirect_uri
    uri = ENV['ZENDESK_OAUTH_REDIRECT_URI']
    return ZendeskAuthorizer::DEFAULT_REDIRECT_URI if uri.to_s.empty?

    uri
  end

  def initialize(oauth: nil)
    @logger = Logger.new(STDERR)
    @logger.level = Logger::INFO

    @zendesk_domain = ENV['ZENDESK_DOMAIN']
    @client_id = ENV['ZENDESK_CLIENT_ID']

    # An injected token supplier is used by the tests, and skips configuration
    # checks that only apply to the real one.
    if oauth
      @oauth = oauth
      return
    end

    validate_configuration!

    @oauth = ZendeskOAuth.new(
      domain: @zendesk_domain,
      client_id: @client_id,
      scopes: self.class.configured_scopes
    )
  end

  def run
    @logger.info("Starting Zendesk MCP Server")

    # MCP protocol communication happens over stdio
    STDOUT.sync = true

    while line = STDIN.gets
      begin
        request = JSON.parse(line.strip)
        response = handle_request(request)
        puts JSON.generate(response)
      rescue JSON::ParserError => e
        @logger.error("Invalid JSON received: #{e.message}")
        error_response = {
          jsonrpc: "2.0",
          id: nil,
          error: {
            code: -32700,
            message: "Parse error"
          }
        }
        puts JSON.generate(error_response)
      rescue => e
        @logger.error("Error handling request: #{e.message}")
        error_response = {
          jsonrpc: "2.0",
          id: request&.dig("id"),
          error: {
            code: -32603,
            message: "Internal error: #{e.message}"
          }
        }
        puts JSON.generate(error_response)
      end
    end
  end

  private

  def validate_configuration!
    missing = []
    missing << "ZENDESK_DOMAIN" if @zendesk_domain.to_s.empty?
    missing << "ZENDESK_CLIENT_ID" if @client_id.to_s.empty?

    return if missing.empty?

    raise "Missing required environment variables: #{missing.join(', ')}"
  end

  def handle_request(request)
    case request["method"]
    when "initialize"
      handle_initialize(request)
    when "tools/list"
      handle_tools_list(request)
    when "tools/call"
      handle_tools_call(request)
    when "resources/list"
      handle_resources_list(request)
    when "resources/read"
      handle_resources_read(request)
    else
      {
        jsonrpc: "2.0",
        id: request["id"],
        error: {
          code: -32601,
          message: "Method not found"
        }
      }
    end
  end

  def handle_initialize(request)
    {
      jsonrpc: "2.0",
      id: request["id"],
      result: {
        protocolVersion: "2024-11-05",
        capabilities: {
          tools: {},
          resources: {}
        },
        serverInfo: {
          name: "zendesk-mcp-server",
          version: "1.0.0"
        }
      }
    }
  end

  def handle_tools_list(request)
    {
      jsonrpc: "2.0",
      id: request["id"],
      result: {
        tools: [
          {
            name: "search_tickets",
            description: "Search for Zendesk tickets",
            inputSchema: {
              type: "object",
              properties: {
                query: {
                  type: "string",
                  description: "Search query for tickets"
                },
                status: {
                  type: "string",
                  description: "Filter by ticket status (new, open, pending, hold, solved, closed)",
                  enum: ["new", "open", "pending", "hold", "solved", "closed"]
                },
                limit: {
                  type: "integer",
                  description: "Maximum number of results to return (default: 25)",
                  default: 25
                }
              },
              required: ["query"]
            }
          },
          {
            name: "get_ticket",
            description: "Get details of a specific ticket",
            inputSchema: {
              type: "object",
              properties: {
                ticket_id: {
                  type: "integer",
                  description: "The ticket ID"
                }
              },
              required: ["ticket_id"]
            }
          },
          {
            name: "create_ticket",
            description: "Create a new ticket",
            inputSchema: {
              type: "object",
              properties: {
                subject: {
                  type: "string",
                  description: "Ticket subject"
                },
                description: {
                  type: "string",
                  description: "Ticket description/body"
                },
                requester_email: {
                  type: "string",
                  description: "Email of the requester"
                },
                priority: {
                  type: "string",
                  description: "Ticket priority",
                  enum: ["low", "normal", "high", "urgent"]
                },
                type: {
                  type: "string",
                  description: "Ticket type",
                  enum: ["problem", "incident", "question", "task"]
                }
              },
              required: ["subject", "description", "requester_email"]
            }
          },
          {
            name: "update_ticket",
            description: "Update an existing ticket",
            inputSchema: {
              type: "object",
              properties: {
                ticket_id: {
                  type: "integer",
                  description: "The ticket ID"
                },
                status: {
                  type: "string",
                  description: "New ticket status",
                  enum: ["new", "open", "pending", "hold", "solved", "closed"]
                },
                priority: {
                  type: "string",
                  description: "New ticket priority",
                  enum: ["low", "normal", "high", "urgent"]
                },
                comment: {
                  type: "string",
                  description: "Add a comment to the ticket"
                }
              },
              required: ["ticket_id"]
            }
          },
          {
            name: "list_users",
            description: "List Zendesk users",
            inputSchema: {
              type: "object",
              properties: {
                role: {
                  type: "string",
                  description: "Filter by user role",
                  enum: ["end-user", "agent", "admin"]
                },
                limit: {
                  type: "integer",
                  description: "Maximum number of results (default: 25)",
                  default: 25
                }
              }
            }
          }
        ]
      }
    }
  end

  def handle_tools_call(request)
    tool_name = request.dig("params", "name")
    arguments = request.dig("params", "arguments") || {}

    result = case tool_name
             when "search_tickets"
               search_tickets(arguments)
             when "get_ticket"
               get_ticket(arguments)
             when "create_ticket"
               create_ticket(arguments)
             when "update_ticket"
               update_ticket(arguments)
             when "list_users"
               list_users(arguments)
             else
               { error: "Unknown tool: #{tool_name}" }
             end

    {
      jsonrpc: "2.0",
      id: request["id"],
      result: {
        content: [
          {
            type: "text",
            text: JSON.pretty_generate(result)
          }
        ]
      }
    }
  end

  def handle_resources_list(request)
    {
      jsonrpc: "2.0",
      id: request["id"],
      result: {
        resources: [
          {
            uri: "zendesk://tickets/recent",
            name: "Recent Tickets",
            description: "List of recently updated tickets",
            mimeType: "application/json"
          },
          {
            uri: "zendesk://users/agents",
            name: "Active Agents",
            description: "List of active support agents",
            mimeType: "application/json"
          }
        ]
      }
    }
  end

  def handle_resources_read(request)
    uri = request.dig("params", "uri")

    result = case uri
             when "zendesk://tickets/recent"
               search_tickets({ "query" => "updated>24hours" })
             when "zendesk://users/agents"
               list_users({ "role" => "agent" })
             else
               { error: "Unknown resource: #{uri}" }
             end

    {
      jsonrpc: "2.0",
      id: request["id"],
      result: {
        contents: [
          {
            uri: uri,
            mimeType: "application/json",
            text: JSON.pretty_generate(result)
          }
        ]
      }
    }
  end

  # Zendesk API methods
  def search_tickets(args)
    query = args["query"]
    status = args["status"]
    limit = args["limit"] || 25

    search_query = query
    search_query += " status:#{status}" if status

    zendesk_request("GET", "/api/v2/search.json?query=#{URI.encode_www_form_component(search_query)}&sort_by=updated_at&sort_order=desc&per_page=#{limit}")
  end

  def get_ticket(args)
    ticket_id = args["ticket_id"]
    zendesk_request("GET", "/api/v2/tickets/#{ticket_id}.json?include=comments,users")
  end

  def create_ticket(args)
    ticket_data = {
      ticket: {
        subject: args["subject"],
        comment: {
          body: args["description"]
        },
        requester: {
          email: args["requester_email"]
        }
      }
    }

    ticket_data[:ticket][:priority] = args["priority"] if args["priority"]
    ticket_data[:ticket][:type] = args["type"] if args["type"]

    zendesk_request("POST", "/api/v2/tickets.json", ticket_data)
  end

  def update_ticket(args)
    ticket_id = args["ticket_id"]
    update_data = { ticket: {} }

    update_data[:ticket][:status] = args["status"] if args["status"]
    update_data[:ticket][:priority] = args["priority"] if args["priority"]

    if args["comment"]
      update_data[:ticket][:comment] = { body: args["comment"] }
    end

    zendesk_request("PUT", "/api/v2/tickets/#{ticket_id}.json", update_data)
  end

  def list_users(args)
    role = args["role"]
    limit = args["limit"] || 25

    endpoint = "/api/v2/users.json?per_page=#{limit}"
    endpoint += "&role=#{role}" if role

    zendesk_request("GET", endpoint)
  end

  def zendesk_request(method, endpoint, data = nil, retry_on_auth_failure: true)
    uri = URI("https://#{@zendesk_domain}#{endpoint}")
    request = build_request(method, uri, data)

    request["Authorization"] = "Bearer #{@oauth.access_token}"
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"

    response = perform_http(uri, request)
    code = response.code.to_i

    return JSON.parse(response.body) if code.between?(200, 299)

    # Zendesk can revoke a token before it expires, so checking the expiry is
    # not enough. Discard the cached token and try once with a fresh one.
    if code == 401 && retry_on_auth_failure
      @logger.warn("Zendesk rejected the access token, minting a new one")
      @oauth.invalidate!
      return zendesk_request(method, endpoint, data, retry_on_auth_failure: false)
    end

    {
      error: "HTTP #{response.code}: #{response.message}",
      body: response.body
    }
  rescue ZendeskOAuth::AuthorizationRequired => e
    # Tell the developer what to run, rather than showing a failed request.
    {
      error: e.message
    }
  rescue => e
    {
      error: "Request failed: #{e.message}"
    }
  end

  def build_request(method, uri, data)
    case method.upcase
    when "GET"
      Net::HTTP::Get.new(uri)
    when "POST"
      request = Net::HTTP::Post.new(uri)
      request.body = data.to_json if data
      request
    when "PUT"
      request = Net::HTTP::Put.new(uri)
      request.body = data.to_json if data
      request
    else
      raise "Unsupported HTTP method: #{method}"
    end
  end

  def perform_http(uri, request)
    ZendeskHttp.client(uri).request(request)
  end
end

def self.authorize!
  domain = ENV['ZENDESK_DOMAIN']
  client_id = ENV['ZENDESK_CLIENT_ID']

  missing = []
  missing << "ZENDESK_DOMAIN" if domain.to_s.empty?
  missing << "ZENDESK_CLIENT_ID" if client_id.to_s.empty?
  raise "Missing required environment variables: #{missing.join(', ')}" if missing.any?

  scopes = ZendeskMCPServer.configured_scopes
  oauth = ZendeskOAuth.new(domain: domain, client_id: client_id, scopes: scopes)

  ZendeskAuthorizer.new(
    domain: domain,
    client_id: client_id,
    scopes: scopes,
    redirect_uri: ZendeskMCPServer.configured_redirect_uri,
    oauth: oauth
  ).run
end

# Run the server if this file is executed directly
if __FILE__ == $0
  if ARGV.include?("--authorize")
    begin
      authorize!
      exit 0
    rescue => e
      STDERR.puts "Authorization failed: #{e.message}"
      exit 1
    end
  end

  begin
    server = ZendeskMCPServer.new
    server.run
  rescue => e
    STDERR.puts "Failed to start server: #{e.message}"
    exit 1
  end
end
