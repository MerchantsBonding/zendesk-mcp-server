require 'securerandom'
require 'socket'
require 'uri'
require_relative 'zendesk_pkce'
require_relative 'zendesk_oauth'

class ZendeskAuthorizer
  class AuthorizationFailed < StandardError; end

  AUTHORIZE_PATH = "/oauth/authorizations/new"
  # The redirect URL must match one registered on the OAuth client, so the port
  # is fixed rather than chosen at run time.
  DEFAULT_REDIRECT_URI = "http://localhost:4567/callback"
  # An unanswered browser must not hold the port forever. The launcher's
  # in-progress window is derived from this, so the child is gone before a
  # replacement is started.
  CALLBACK_TIMEOUT_SECONDS = 150

  def self.generate_state
    SecureRandom.urlsafe_base64(24, false)
  end

  def self.parse_query(request_line)
    query = target(request_line).split("?", 2)[1]
    return {} if query.to_s.empty?

    URI.decode_www_form(query).to_h
  rescue ArgumentError
    {}
  end

  def self.parse_path(request_line)
    target(request_line).split("?", 2).first.to_s
  end

  def self.target(request_line)
    request_line.to_s.split(" ")[1].to_s
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

  # Always answers the browser, so the outcome shows on the page.
  # Answers every request that arrives, and keeps listening until the redirect
  # shows up or the deadline passes. A browser preconnect or a favicon probe can
  # reach the port first, and must not consume the one chance to read the code.
  def wait_for_callback(server:, expected_state:, timeout: CALLBACK_TIMEOUT_SECONDS)
    deadline = Time.now + timeout

    loop do
      remaining = deadline - Time.now
      raise AuthorizationFailed, timed_out_message if remaining <= 0
      raise AuthorizationFailed, timed_out_message unless IO.select([server], nil, nil, remaining)

      socket = server.accept
      begin
        line = socket.gets
        path = self.class.parse_path(line)
        params = self.class.parse_query(line)
        discard_headers(socket)

        if path != callback_path
          respond(socket, 404, "Not found.")
          next
        end

        code = code_from(params, expected_state: expected_state)
        respond(socket, 200, "Authorization complete. You can close this tab.")
        return code
      rescue AuthorizationFailed => e
        respond(socket, 400, "Authorization failed. #{e.message}")
        raise
      ensure
        socket.close
      end
    end
  end

  def code_from(params, expected_state:)
    if params["error"]
      detail = params["error_description"]
      detail = params["error"] if detail.to_s.empty?
      raise AuthorizationFailed, detail
    end

    # A mismatched state belongs to some other request, not this one.
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

  # Some OAuth endpoints accept only "%20" for a space, not "+". A literal "+"
  # is already "%2B" here, so only spaces change.
  def encode(value)
    URI.encode_www_form_component(value.to_s).gsub("+", "%20")
  end

  def timed_out_message
    "Timed out waiting for the browser redirect."
  end

  def callback_path
    URI(@redirect_uri).path
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
    reason = { 200 => "OK", 400 => "Bad Request", 404 => "Not Found" }.fetch(status, "Error")

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
