#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../zendesk_mcp_server'

DOMAIN = "example.zendesk.com"
CLIENT_ID = "client-abc"
CLIENT_SECRET = "secret-xyz"

# Captures mint calls and returns canned token payloads, so no test touches the
# network.
class StubOAuth < ZendeskOAuth
  attr_reader :mint_calls

  def initialize(mint_results: [], **kwargs)
    super(**kwargs)
    @mint_calls = []
    @mint_results = mint_results
  end

  def post_token_request(params)
    @mint_calls << params
    result = @mint_results.shift
    raise "StubOAuth ran out of canned mint results" if result.nil?
    raise result if result.is_a?(StandardError)
    result
  end
end

class FakeResponse
  attr_reader :code, :body, :message

  def initialize(code, body, message = "")
    @code = code.to_s
    @body = body
    @message = message
  end
end

# Records outbound requests and replays canned responses.
class StubServer < ZendeskMCPServer
  attr_reader :attempts

  def initialize(oauth:, responses:)
    super(oauth: oauth)
    @logger.level = Logger::FATAL
    @responses = responses
    @attempts = []
  end

  def perform_http(uri, request)
    @attempts << { path: uri.request_uri, authorization: request["Authorization"] }
    response = @responses.shift
    raise "StubServer ran out of canned responses" if response.nil?
    response
  end
end

class TestZendeskOAuthCache < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @cache_path = File.join(@dir, "token.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_oauth(mint_results: [])
    StubOAuth.new(
      mint_results: mint_results,
      domain: DOMAIN,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      cache_path: @cache_path
    )
  end

  def write_cache(access_token: "cached-token", expires_at: Time.now.to_i + 3600,
                  domain: DOMAIN, client_id: CLIENT_ID)
    File.write(@cache_path, JSON.generate(
      "access_token" => access_token,
      "expires_at" => expires_at,
      "domain" => domain,
      "client_id" => client_id
    ))
  end

  def minted(token: "fresh-token", expires_in: 172_800)
    { "access_token" => token, "expires_in" => expires_in }
  end

  def test_valid_cached_token_is_reused_without_minting
    write_cache(access_token: "cached-token")
    oauth = build_oauth

    assert_equal "cached-token", oauth.access_token
    assert_empty oauth.mint_calls, "expected no mint when a valid token is cached"
  end

  def test_expired_cached_token_is_replaced
    write_cache(access_token: "stale-token", expires_at: Time.now.to_i - 1)
    oauth = build_oauth(mint_results: [minted(token: "fresh-token")])

    assert_equal "fresh-token", oauth.access_token
    assert_equal 1, oauth.mint_calls.length
  end

  def test_token_expiring_inside_skew_window_counts_as_expired
    write_cache(access_token: "almost-stale", expires_at: Time.now.to_i + 30)
    oauth = build_oauth(mint_results: [minted(token: "fresh-token")])

    assert_equal "fresh-token", oauth.access_token
  end

  def test_cache_for_a_different_domain_is_rejected
    write_cache(access_token: "other-instance", domain: "other.zendesk.com")
    oauth = build_oauth(mint_results: [minted])

    assert_equal "fresh-token", oauth.access_token
  end

  def test_cache_for_a_different_client_id_is_rejected
    write_cache(access_token: "other-client", client_id: "rotated-client")
    oauth = build_oauth(mint_results: [minted])

    assert_equal "fresh-token", oauth.access_token
  end

  def test_corrupt_cache_file_is_treated_as_a_miss
    File.write(@cache_path, "{not json")
    oauth = build_oauth(mint_results: [minted])

    assert_equal "fresh-token", oauth.access_token
  end

  def test_missing_cache_file_is_treated_as_a_miss
    oauth = build_oauth(mint_results: [minted])

    assert_equal "fresh-token", oauth.access_token
  end

  def test_mint_request_uses_client_credentials_grant_and_maximum_expiry
    oauth = build_oauth(mint_results: [minted])
    oauth.access_token

    params = oauth.mint_calls.first
    assert_equal "client_credentials", params["grant_type"]
    assert_equal CLIENT_ID, params["client_id"]
    assert_equal CLIENT_SECRET, params["client_secret"]
    assert_equal "read write", params["scope"]
    assert_equal 172_800, params["expires_in"]
  end

  def test_custom_scopes_are_sent
    oauth = StubOAuth.new(
      mint_results: [minted],
      domain: DOMAIN,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      scopes: "tickets:read",
      cache_path: @cache_path
    )
    oauth.access_token

    assert_equal "tickets:read", oauth.mint_calls.first["scope"]
  end

  def test_minted_token_is_cached_with_an_absolute_expiry
    oauth = build_oauth(mint_results: [minted(token: "fresh-token", expires_in: 172_800)])
    oauth.access_token

    cached = JSON.parse(File.read(@cache_path))
    assert_equal "fresh-token", cached["access_token"]
    assert_equal DOMAIN, cached["domain"]
    assert_equal CLIENT_ID, cached["client_id"]
    assert_in_delta Time.now.to_i + 172_800, cached["expires_at"], 5
  end

  def test_cache_file_is_written_with_owner_only_permissions
    oauth = build_oauth(mint_results: [minted])
    oauth.access_token

    mode = File.stat(@cache_path).mode & 0o777
    assert_equal 0o600, mode, "token cache must not be readable by other users"
  end

  def test_a_second_call_reuses_the_token_minted_by_the_first
    oauth = build_oauth(mint_results: [minted])

    oauth.access_token
    oauth.access_token

    assert_equal 1, oauth.mint_calls.length
  end

  def test_invalidate_removes_the_cached_token
    write_cache
    oauth = build_oauth(mint_results: [minted])

    oauth.invalidate!

    refute File.exist?(@cache_path)
    assert_equal "fresh-token", oauth.access_token
  end

  def test_invalidate_is_safe_when_no_cache_exists
    oauth = build_oauth
    oauth.invalidate!
  end
end

class TestZendeskRequestAuth < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @cache_path = File.join(@dir, "token.json")
    @saved_domain = ENV["ZENDESK_DOMAIN"]
    ENV["ZENDESK_DOMAIN"] = DOMAIN
  end

  def teardown
    FileUtils.remove_entry(@dir)
    ENV["ZENDESK_DOMAIN"] = @saved_domain
    ENV.delete("ZENDESK_DOMAIN") if @saved_domain.nil?
  end

  def build_oauth(mint_results:)
    StubOAuth.new(
      mint_results: mint_results,
      domain: DOMAIN,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      cache_path: @cache_path
    )
  end

  def test_requests_carry_a_bearer_token
    oauth = build_oauth(mint_results: [{ "access_token" => "token-1", "expires_in" => 172_800 }])
    server = StubServer.new(
      oauth: oauth,
      responses: [FakeResponse.new(200, '{"ticket":{"id":1}}')]
    )

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/1.json")

    assert_equal 1, result.dig("ticket", "id")
    assert_equal "Bearer token-1", server.attempts.first[:authorization]
  end

  def test_a_401_triggers_exactly_one_remint_and_retry
    oauth = build_oauth(mint_results: [
      { "access_token" => "revoked-token", "expires_in" => 172_800 },
      { "access_token" => "replacement-token", "expires_in" => 172_800 }
    ])
    server = StubServer.new(
      oauth: oauth,
      responses: [
        FakeResponse.new(401, '{"error":"Couldn\'t authenticate you"}', "Unauthorized"),
        FakeResponse.new(200, '{"ticket":{"id":7}}')
      ]
    )

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/7.json")

    assert_equal 7, result.dig("ticket", "id")
    assert_equal 2, server.attempts.length
    assert_equal "Bearer revoked-token", server.attempts[0][:authorization]
    assert_equal "Bearer replacement-token", server.attempts[1][:authorization]
    assert_equal 2, oauth.mint_calls.length
  end

  def test_a_repeated_401_returns_an_error_without_looping
    oauth = build_oauth(mint_results: [
      { "access_token" => "token-a", "expires_in" => 172_800 },
      { "access_token" => "token-b", "expires_in" => 172_800 }
    ])
    server = StubServer.new(
      oauth: oauth,
      responses: [
        FakeResponse.new(401, '{"error":"denied"}', "Unauthorized"),
        FakeResponse.new(401, '{"error":"denied"}', "Unauthorized")
      ]
    )

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/7.json")

    assert_match(/401/, result[:error].to_s)
    assert_equal 2, server.attempts.length, "must not retry more than once"
  end

  def test_a_failed_mint_is_reported_as_an_error_not_an_exception
    oauth = build_oauth(mint_results: [StandardError.new("invalid_client")])
    server = StubServer.new(oauth: oauth, responses: [])

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/7.json")

    assert_match(/invalid_client/, result[:error].to_s)
  end

  def test_non_auth_errors_are_not_retried
    oauth = build_oauth(mint_results: [{ "access_token" => "token-1", "expires_in" => 172_800 }])
    server = StubServer.new(
      oauth: oauth,
      responses: [FakeResponse.new(404, '{"error":"RecordNotFound"}', "Not Found")]
    )

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/999.json")

    assert_match(/404/, result[:error].to_s)
    assert_equal 1, server.attempts.length
  end
end

class TestConfiguration < Minitest::Test
  def around_env
    saved = ENV.to_h
    yield
  ensure
    ENV.clear
    saved.each { |k, v| ENV[k] = v }
  end

  def test_missing_oauth_variables_are_named_in_the_error
    around_env do
      ENV.delete("ZENDESK_DOMAIN")
      ENV.delete("ZENDESK_CLIENT_ID")
      ENV.delete("ZENDESK_CLIENT_SECRET")

      error = assert_raises(RuntimeError) { ZendeskMCPServer.new }

      assert_match(/ZENDESK_DOMAIN/, error.message)
      assert_match(/ZENDESK_CLIENT_ID/, error.message)
      assert_match(/ZENDESK_CLIENT_SECRET/, error.message)
    end
  end

  def test_server_starts_with_oauth_variables_present
    around_env do
      ENV["ZENDESK_DOMAIN"] = DOMAIN
      ENV["ZENDESK_CLIENT_ID"] = CLIENT_ID
      ENV["ZENDESK_CLIENT_SECRET"] = CLIENT_SECRET

      ZendeskMCPServer.new
    end
  end
end
