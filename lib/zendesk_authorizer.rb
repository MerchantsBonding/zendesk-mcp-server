require 'securerandom'
require 'socket'
require 'uri'
require_relative 'zendesk_pkce'
require_relative 'zendesk_oauth'

# Runs the one-time authorization code flow with PKCE, so this machine holds
# tokens belonging to the developer who approved them.
#
# Zendesk redirects back to a loopback address after consent. This class listens
# on that address for exactly one request, takes the authorization code, and
# exchanges it for tokens. Nothing here runs while the MCP server serves
# requests.
class ZendeskAuthorizer
  class AuthorizationFailed < StandardError; end

  AUTHORIZE_PATH = "/oauth/authorizations/new"
  # The redirect URL must match one registered on the OAuth client, so the port
  # is fixed rather than chosen at run time.
  DEFAULT_REDIRECT_URI = "http://localhost:4567/callback"

  def self.generate_state
    SecureRandom.urlsafe_base64(24, false)
  end

  # Reads the query parameters out of an HTTP request line.
  def self.parse_query(request_line)
    target = request_line.to_s.split(" ")[1].to_s
    query = target.split("?", 2)[1]
    return {} if query.to_s.empty?

    URI.decode_www_form(query).to_h
  end

  def initialize(domain:, client_id:, oauth:, scopes: ZendeskOAuth::DEFAULT_SCOPES,
                 redirect_uri: DEFAULT_REDIRECT_URI, io: $stdout)
    @domain = domain
    @client_id = client_id
    @scopes = scopes
    @redirect_uri = redirect_uri
    @oauth = oauth
    @io = io
  end

  def run
    pkce = ZendeskPkce.new
    state = self.class.generate_state
    url = authorization_url(challenge: pkce.challenge, state: state)

    server = nil
    begin
      server = TCPServer.new(redirect_host, redirect_port)
    rescue Errno::EADDRINUSE
      raise AuthorizationFailed,
            "Port #{redirect_port} is already in use. Close whatever holds it, then try again."
    end

    begin
      @io.puts "Approve access in your browser. If no page opens, use this link:"
      @io.puts url
      @io.puts
      open_browser(url)

      code = wait_for_callback(server: server, expected_state: state)
      exchange(code: code, verifier: pkce.verifier)
      @io.puts "Authorization complete. The MCP server can now reach Zendesk as you."
    ensure
      server.close
    end
  end

  def authorization_url(challenge:, state:)
    query = {
      "response_type" => "code",
      "client_id" => @client_id,
      "redirect_uri" => @redirect_uri,
      "scope" => @scopes,
      "state" => state,
      "code_challenge" => challenge,
      "code_challenge_method" => ZendeskPkce::METHOD
    }.map { |key, value| "#{key}=#{encode(value)}" }.join("&")

    "https://#{@domain}#{AUTHORIZE_PATH}?#{query}"
  end

  # Serves exactly one request, and always answers the browser, so the developer
  # sees the outcome on the page rather than a connection error.
  def wait_for_callback(server:, expected_state:)
    socket = server.accept
    params = self.class.parse_query(socket.gets)
    discard_headers(socket)

    begin
      code = code_from(params, expected_state: expected_state)
      respond(socket, 200, "Authorization complete. You can close this tab.")
      code
    rescue AuthorizationFailed => e
      respond(socket, 400, "Authorization failed. #{e.message}")
      raise
    end
  ensure
    socket&.close
  end

  def code_from(params, expected_state:)
    if params["error"]
      detail = params["error_description"]
      detail = params["error"] if detail.to_s.empty?
      raise AuthorizationFailed, detail
    end

    # A state that does not match means this redirect belongs to some other
    # request, not the one this process started.
    raise AuthorizationFailed, "The redirect carried the wrong state value." unless params["state"] == expected_state

    code = params["code"]
    raise AuthorizationFailed, "The redirect carried no authorization code." if code.to_s.empty?

    code
  end

  def exchange(code:, verifier:)
    @oauth.redeem(
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => @client_id,
      "redirect_uri" => @redirect_uri,
      "code_verifier" => verifier,
      "scope" => @scopes,
      "expires_in" => ZendeskOAuth::MAX_EXPIRES_IN,
      "refresh_token_expires_in" => ZendeskOAuth::MAX_REFRESH_EXPIRES_IN
    )
  end

  private

  # Form encoding writes a space as "+". Some OAuth endpoints accept only
  # "%20", so convert it. A literal "+" is already escaped to "%2B" by this
  # point, so only spaces change.
  def encode(value)
    URI.encode_www_form_component(value.to_s).gsub("+", "%20")
  end

  def redirect_host
    URI(@redirect_uri).host
  end

  def redirect_port
    URI(@redirect_uri).port
  end

  def discard_headers(socket)
    while (line = socket.gets)
      break if line.strip.empty?
    end
  end

  def respond(socket, status, message)
    reason = "OK"
    reason = "Bad Request" unless status == 200

    body = "<!doctype html><meta charset=\"utf-8\">" \
           "<title>Zendesk MCP Server</title>" \
           "<p style=\"font:16px system-ui;padding:2rem\">#{message}</p>"

    socket.print(
      "HTTP/1.1 #{status} #{reason}\r\n" \
      "Content-Type: text/html; charset=utf-8\r\n" \
      "Content-Length: #{body.bytesize}\r\n" \
      "Connection: close\r\n\r\n#{body}"
    )
  end

  def open_browser(url)
    command = browser_command
    return if command.nil?

    system(*command, url, out: File::NULL, err: File::NULL)
  rescue StandardError
    nil
  end

  def browser_command
    return ["open"] if RUBY_PLATFORM.include?("darwin")
    return ["xdg-open"] if RUBY_PLATFORM.include?("linux")

    nil
  end
end
