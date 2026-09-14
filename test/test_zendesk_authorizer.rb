#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'socket'
require 'uri'
require_relative '../lib/zendesk_authorizer'
require_relative '../lib/zendesk_oauth'
require_relative '../lib/zendesk_token_store'

AUTH_DOMAIN = "example.zendesk.com"
AUTH_CLIENT_ID = "client-abc"
REDIRECT_URI = "http://localhost:4567/callback"

class StubExchangeOAuth < ZendeskOAuth
  attr_reader :calls

  def initialize(results: [], **kwargs)
    super(**kwargs)
    @calls = []
    @results = results
  end

  def post_token_request(params)
    @calls << params
    result = @results.shift
    raise "StubExchangeOAuth ran out of canned results" if result.nil?
    raise result if result.is_a?(StandardError)
    result
  end
end

class TestAuthorizationUrl < Minitest::Test
  def build
    ZendeskAuthorizer.new(
      domain: AUTH_DOMAIN,
      client_id: AUTH_CLIENT_ID,
      scopes: "read write",
      redirect_uri: REDIRECT_URI,
      oauth: nil,
      io: StringIO.new
    )
  end

  def params_of(url)
    URI.decode_www_form(URI(url).query).to_h
  end

  def test_url_points_at_the_zendesk_authorization_endpoint
    url = build.authorization_url(challenge: "chal", state: "st")

    assert url.start_with?("https://#{AUTH_DOMAIN}/oauth/authorizations/new?"), url
  end

  def test_url_requests_an_authorization_code
    assert_equal "code", params_of(build.authorization_url(challenge: "chal", state: "st"))["response_type"]
  end

  def test_url_carries_the_pkce_challenge_and_method
    params = params_of(build.authorization_url(challenge: "chal", state: "st"))

    assert_equal "chal", params["code_challenge"]
    assert_equal "S256", params["code_challenge_method"]
  end

  def test_url_carries_client_redirect_scope_and_state
    params = params_of(build.authorization_url(challenge: "chal", state: "st"))

    assert_equal AUTH_CLIENT_ID, params["client_id"]
    assert_equal REDIRECT_URI, params["redirect_uri"]
    assert_equal "read write", params["scope"]
    assert_equal "st", params["state"]
  end

  def test_url_never_carries_a_client_secret
    refute_includes build.authorization_url(challenge: "chal", state: "st"), "client_secret"
  end

  def test_state_is_unpredictable
    states = Array.new(50) { ZendeskAuthorizer.generate_state }

    assert_equal 50, states.uniq.length
    assert_operator states.first.length, :>=, 16
  end
end

class TestCallbackHandling < Minitest::Test
  def build
    ZendeskAuthorizer.new(
      domain: AUTH_DOMAIN,
      client_id: AUTH_CLIENT_ID,
      scopes: "read write",
      redirect_uri: REDIRECT_URI,
      oauth: nil,
      io: StringIO.new
    )
  end

  def test_query_is_parsed_from_the_request_line
    params = ZendeskAuthorizer.parse_query("GET /callback?code=abc&state=xyz HTTP/1.1")

    assert_equal "abc", params["code"]
    assert_equal "xyz", params["state"]
  end

  def test_query_is_parsed_when_no_parameters_are_present
    assert_equal({}, ZendeskAuthorizer.parse_query("GET /callback HTTP/1.1"))
  end

  def test_percent_encoded_values_are_decoded
    params = ZendeskAuthorizer.parse_query("GET /callback?error_description=Access%20denied HTTP/1.1")

    assert_equal "Access denied", params["error_description"]
  end

  def test_the_code_is_returned_when_the_state_matches
    code = build.code_from({ "code" => "abc", "state" => "xyz" }, expected_state: "xyz")

    assert_equal "abc", code
  end

  # A mismatched state means the redirect did not come from the request this
  # process started.
  def test_a_mismatched_state_is_rejected
    error = assert_raises(ZendeskAuthorizer::AuthorizationFailed) do
      build.code_from({ "code" => "abc", "state" => "attacker" }, expected_state: "xyz")
    end

    assert_match(/state/i, error.message)
  end

  def test_a_missing_state_is_rejected
    assert_raises(ZendeskAuthorizer::AuthorizationFailed) do
      build.code_from({ "code" => "abc" }, expected_state: "xyz")
    end
  end

  def test_a_denial_from_zendesk_is_reported
    error = assert_raises(ZendeskAuthorizer::AuthorizationFailed) do
      build.code_from(
        { "error" => "access_denied", "error_description" => "User said no", "state" => "xyz" },
        expected_state: "xyz"
      )
    end

    assert_match(/User said no/, error.message)
  end

  def test_a_response_without_a_code_is_rejected
    assert_raises(ZendeskAuthorizer::AuthorizationFailed) do
      build.code_from({ "state" => "xyz" }, expected_state: "xyz")
    end
  end
end

class TestCallbackListener < Minitest::Test
  def build
    ZendeskAuthorizer.new(
      domain: AUTH_DOMAIN,
      client_id: AUTH_CLIENT_ID,
      scopes: "read write",
      redirect_uri: REDIRECT_URI,
      oauth: nil,
      io: StringIO.new
    )
  end

  def test_the_listener_receives_the_code_and_answers_the_browser
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    received = nil

    listener = Thread.new { received = build.wait_for_callback(server: server, expected_state: "xyz") }

    socket = TCPSocket.new("127.0.0.1", port)
    socket.print("GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n")
    response = socket.read
    socket.close
    listener.join(5)

    assert_equal "abc", received
    assert_match(/^HTTP\/1\.1 200/, response)
    assert_match(/close this (tab|window)/i, response)
  end

  def test_the_listener_answers_the_browser_even_when_authorization_failed
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    error = nil

    listener = Thread.new do
      begin
        build.wait_for_callback(server: server, expected_state: "xyz")
      rescue ZendeskAuthorizer::AuthorizationFailed => e
        error = e
      end
    end

    socket = TCPSocket.new("127.0.0.1", port)
    socket.print("GET /callback?error=access_denied&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n")
    response = socket.read
    socket.close
    listener.join(5)

    refute_nil error
    assert_match(/^HTTP\/1\.1 400/, response)
  end
end

class TestCodeExchange < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = ZendeskTokenStore.new(path: File.join(@dir, "token.json"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build(results:)
    oauth = StubExchangeOAuth.new(
      results: results,
      domain: AUTH_DOMAIN,
      client_id: AUTH_CLIENT_ID,
      store: @store
    )
    authorizer = ZendeskAuthorizer.new(
      domain: AUTH_DOMAIN,
      client_id: AUTH_CLIENT_ID,
      scopes: "read write",
      redirect_uri: REDIRECT_URI,
      oauth: oauth,
      io: StringIO.new
    )
    [authorizer, oauth]
  end

  def granted
    {
      "access_token" => "access-1",
      "refresh_token" => "refresh-1",
      "expires_in" => 172_800,
      "refresh_token_expires_in" => 7_776_000
    }
  end

  def test_the_exchange_sends_the_verifier_and_no_secret
    authorizer, oauth = build(results: [granted])

    authorizer.exchange(code: "the-code", verifier: "the-verifier")

    params = oauth.calls.first
    assert_equal "authorization_code", params["grant_type"]
    assert_equal "the-code", params["code"]
    assert_equal "the-verifier", params["code_verifier"]
    assert_equal AUTH_CLIENT_ID, params["client_id"]
    assert_equal REDIRECT_URI, params["redirect_uri"]
    refute params.key?("client_secret"), "a public client must not send a secret"
  end

  def test_the_exchange_asks_for_the_maximum_token_lifetimes
    authorizer, oauth = build(results: [granted])

    authorizer.exchange(code: "the-code", verifier: "the-verifier")

    params = oauth.calls.first
    assert_equal 172_800, params["expires_in"]
    assert_equal 7_776_000, params["refresh_token_expires_in"]
  end

  def test_the_exchange_stores_both_tokens
    authorizer, = build(results: [granted])

    authorizer.exchange(code: "the-code", verifier: "the-verifier")

    record = @store.read
    assert_equal "access-1", record["access_token"]
    assert_equal "refresh-1", record["refresh_token"]
    assert_equal AUTH_DOMAIN, record["domain"]
    assert_equal AUTH_CLIENT_ID, record["client_id"]
  end

  def test_a_rejected_code_is_reported_as_a_failure
    authorizer, = build(results: [ZendeskOAuth::TokenRequestFailed.new("HTTP 400: invalid_grant", status: 400)])

    assert_raises(ZendeskOAuth::AuthorizationRequired) do
      authorizer.exchange(code: "bad", verifier: "v")
    end
  end
end

class TestScopeEncoding < Minitest::Test
  def build
    ZendeskAuthorizer.new(
      domain: AUTH_DOMAIN,
      client_id: AUTH_CLIENT_ID,
      scopes: "read write",
      redirect_uri: REDIRECT_URI,
      oauth: nil,
      io: StringIO.new
    )
  end

  # Form encoding writes a space as "+". Some OAuth endpoints accept only
  # "%20", so encode spaces the stricter way.
  def test_spaces_in_scope_are_percent_encoded
    url = build.authorization_url(challenge: "chal", state: "st")

    assert_includes url, "scope=read%20write"
    refute_includes url, "read+write"
  end

  def test_values_are_still_decoded_correctly
    url = build.authorization_url(challenge: "chal", state: "st")
    params = URI.decode_www_form(URI(url).query).to_h

    assert_equal "read write", params["scope"]
    assert_equal REDIRECT_URI, params["redirect_uri"]
  end
end

class TestListenerRobustness < Minitest::Test
  def build
    ZendeskAuthorizer.new(
      domain: AUTH_DOMAIN, client_id: AUTH_CLIENT_ID, scopes: "read",
      redirect_uri: REDIRECT_URI, oauth: nil, io: StringIO.new
    )
  end


# Never block the suite on a server that is not answering.
def read_with_deadline(socket, seconds)
  deadline = Time.now + seconds
  buffer = +""
  loop do
    remaining = deadline - Time.now
    break if remaining <= 0
    break unless IO.select([socket], nil, nil, remaining)

    chunk = socket.read_nonblock(4096, exception: false)
    break if chunk.nil?
    next if chunk == :wait_readable

    buffer << chunk
  end
  buffer
end

  def serve(requests, timeout: 5)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    result = nil
    error = nil

    listener = Thread.new do
      begin
        result = build.wait_for_callback(server: server, expected_state: "xyz", timeout: timeout)
      rescue ZendeskAuthorizer::AuthorizationFailed => e
        error = e
      end
    end

    responses = requests.map do |line|
      socket = TCPSocket.new("127.0.0.1", port)
      socket.print("#{line}\r\nHost: localhost\r\n\r\n")
      body = read_with_deadline(socket, 3)
      socket.close
      body
    end

    listener.join(5)
    server.close unless server.closed?
    [result, error, responses]
  end

  # A browser preconnect, a favicon probe or a security agent can reach the port
  # first. Consuming the only accept on one of those loses the real redirect.
  def test_an_unrelated_request_does_not_consume_the_callback
    result, error, responses = serve([
      "GET /favicon.ico HTTP/1.1",
      "GET /callback?code=abc&state=xyz HTTP/1.1"
    ])

    assert_nil error
    assert_equal "abc", result
    assert_match(%r{^HTTP/1\.1 404}, responses[0])
    assert_match(%r{^HTTP/1\.1 200}, responses[1])
  end

  # An unanswered browser must not hold port 4567 for the life of the machine.
  def test_the_listener_gives_up_after_the_timeout
    _result, error, = serve([], timeout: 0.3)

    refute_nil error
    assert_match(/timed out/i, error.message)
  end

  # parse_query used to sit outside the rescue, so this closed the socket with
  # no HTTP response at all.
  def test_malformed_encoding_still_answers_the_browser
    _result, error, responses = serve(["GET /callback?state=%ZZ HTTP/1.1"])

    refute_nil error
    assert_match(%r{^HTTP/1\.1 400}, responses[0])
  end

  def test_the_port_is_released_once_the_flow_ends
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      begin
        build.wait_for_callback(server: server, expected_state: "xyz", timeout: 0.2)
      rescue ZendeskAuthorizer::AuthorizationFailed
        nil
      end
    end
    thread.join(5)
    server.close unless server.closed?

    reopened = TCPServer.new("127.0.0.1", port)
    reopened.close
  end
end
