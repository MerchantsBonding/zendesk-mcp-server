#!/usr/bin/env ruby

require 'minitest/autorun'
require 'json'
require_relative '../zendesk_mcp_server'

SERVER_DOMAIN = "example.zendesk.com"

class FakeResponse
  attr_reader :code, :body, :message

  def initialize(code, body, message = "")
    @code = code.to_s
    @body = body
    @message = message
  end
end

# Hands out tokens in order, and records how often the access token was dropped.
class FakeOAuth
  attr_reader :invalidations

  def initialize(tokens: [], error: nil)
    @tokens = tokens
    @error = error
    @invalidations = 0
    @current = nil
  end

  def access_token
    raise @error if @error

    @current = @tokens.shift if @current.nil?
    @current
  end

  def invalidate!
    @invalidations += 1
    @current = nil
  end
end

class StubServer < ZendeskMCPServer
  attr_reader :attempts

  def initialize(oauth:, responses:, launcher: nil)
    super(oauth: oauth, launcher: launcher)
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

class TestServerRequests < Minitest::Test
  def setup
    @saved = ENV["ZENDESK_DOMAIN"]
    ENV["ZENDESK_DOMAIN"] = SERVER_DOMAIN
  end

  def teardown
    ENV["ZENDESK_DOMAIN"] = @saved
    ENV.delete("ZENDESK_DOMAIN") if @saved.nil?
  end

  def test_requests_carry_a_bearer_token
    server = StubServer.new(
      oauth: FakeOAuth.new(tokens: ["token-1"]),
      responses: [FakeResponse.new(200, '{"ticket":{"id":1}}')]
    )

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/1.json")

    assert_equal 1, result.dig("ticket", "id")
    assert_equal "Bearer token-1", server.attempts.first[:authorization]
  end

  # Zendesk can revoke a token before it expires, so an expiry check alone is
  # not enough.
  def test_a_401_drops_the_access_token_and_retries_once
    oauth = FakeOAuth.new(tokens: ["revoked-token", "replacement-token"])
    server = StubServer.new(
      oauth: oauth,
      responses: [
        FakeResponse.new(401, '{"error":"denied"}', "Unauthorized"),
        FakeResponse.new(200, '{"ticket":{"id":7}}')
      ]
    )

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/7.json")

    assert_equal 7, result.dig("ticket", "id")
    assert_equal 2, server.attempts.length
    assert_equal "Bearer revoked-token", server.attempts[0][:authorization]
    assert_equal "Bearer replacement-token", server.attempts[1][:authorization]
    assert_equal 1, oauth.invalidations
  end

  def test_a_repeated_401_returns_an_error_without_looping
    server = StubServer.new(
      oauth: FakeOAuth.new(tokens: ["token-a", "token-b"]),
      responses: [
        FakeResponse.new(401, '{"error":"denied"}', "Unauthorized"),
        FakeResponse.new(401, '{"error":"denied"}', "Unauthorized")
      ]
    )

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/7.json")

    assert_match(/401/, result[:error].to_s)
    assert_equal 2, server.attempts.length
  end

  def test_non_auth_errors_are_not_retried
    server = StubServer.new(
      oauth: FakeOAuth.new(tokens: ["token-1"]),
      responses: [FakeResponse.new(404, '{"error":"RecordNotFound"}', "Not Found")]
    )

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/999.json")

    assert_match(/404/, result[:error].to_s)
    assert_equal 1, server.attempts.length
  end

  # The developer needs to be told what to run, not shown a stack trace.
  def test_a_missing_authorization_is_reported_with_the_command_to_run
    error = ZendeskOAuth::AuthorizationRequired.new("Run: ruby zendesk_mcp_server.rb --authorize")
    server = StubServer.new(oauth: FakeOAuth.new(error: error), responses: [])

    result = server.send(:zendesk_request, "GET", "/api/v2/tickets/1.json")

    assert_match(/--authorize/, result[:error].to_s)
    assert_empty server.attempts
  end
end

class TestServerConfiguration < Minitest::Test
  def with_env(values)
    saved = ENV.to_h
    ENV.delete("ZENDESK_DOMAIN")
    ENV.delete("ZENDESK_CLIENT_ID")
    ENV.delete("ZENDESK_CLIENT_SECRET")
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    ENV.clear
    saved.each { |k, v| ENV[k] = v }
  end

  def test_missing_variables_are_named
    with_env({}) do
      error = assert_raises(RuntimeError) { ZendeskMCPServer.new }

      assert_match(/ZENDESK_DOMAIN/, error.message)
      assert_match(/ZENDESK_CLIENT_ID/, error.message)
    end
  end

  # A public OAuth client has no secret, so requiring one would be wrong.
  def test_a_client_secret_is_not_required
    with_env("ZENDESK_DOMAIN" => SERVER_DOMAIN, "ZENDESK_CLIENT_ID" => "client-abc") do
      ZendeskMCPServer.new
    end
  end

  def test_the_client_secret_variable_is_no_longer_consulted
    with_env("ZENDESK_DOMAIN" => SERVER_DOMAIN, "ZENDESK_CLIENT_SECRET" => "leftover") do
      error = assert_raises(RuntimeError) { ZendeskMCPServer.new }

      assert_match(/ZENDESK_CLIENT_ID/, error.message)
    end
  end
end

class TestConfiguredScopes < Minitest::Test
  def with_scopes(value)
    saved = ENV["ZENDESK_OAUTH_SCOPES"]
    ENV.delete("ZENDESK_OAUTH_SCOPES")
    ENV["ZENDESK_OAUTH_SCOPES"] = value unless value.nil?
    yield
  ensure
    ENV.delete("ZENDESK_OAUTH_SCOPES")
    ENV["ZENDESK_OAUTH_SCOPES"] = saved unless saved.nil?
  end

  def test_the_default_is_used_when_the_variable_is_unset
    with_scopes(nil) do
      assert_equal "read tickets:write", ZendeskMCPServer.configured_scopes
    end
  end

  def test_the_default_is_used_when_the_variable_is_empty
    with_scopes("") do
      assert_equal "read tickets:write", ZendeskMCPServer.configured_scopes
    end
  end

  def test_the_variable_overrides_the_default
    with_scopes("read") do
      assert_equal "read", ZendeskMCPServer.configured_scopes
    end
  end
end

class FakeLauncher
  attr_reader :reasons

  def initialize(message: "launcher message")
    @message = message
    @reasons = []
  end

  def launch(reason)
    @reasons << reason
    @message
  end
end

class TestAutomaticAuthorization < Minitest::Test
  def setup
    @saved = ENV["ZENDESK_DOMAIN"]
    ENV["ZENDESK_DOMAIN"] = SERVER_DOMAIN
  end

  def teardown
    ENV["ZENDESK_DOMAIN"] = @saved
    ENV.delete("ZENDESK_DOMAIN") if @saved.nil?
  end

  def build(launcher)
    error = ZendeskOAuth::AuthorizationRequired.new("The refresh token expired.")
    StubServer.new(oauth: FakeOAuth.new(error: error), responses: [], launcher: launcher)
  end

  def test_a_missing_authorization_starts_the_flow
    launcher = FakeLauncher.new
    build(launcher).send(:zendesk_request, "GET", "/api/v2/tickets/1.json")

    assert_equal 1, launcher.reasons.length
  end

  def test_the_launcher_receives_the_reason_not_the_baked_in_command
    launcher = FakeLauncher.new
    build(launcher).send(:zendesk_request, "GET", "/api/v2/tickets/1.json")

    assert_equal "The refresh token expired.", launcher.reasons.first
  end

  def test_the_launchers_message_is_what_the_tool_call_reports
    result = build(FakeLauncher.new(message: "a browser has opened")).send(
      :zendesk_request, "GET", "/api/v2/tickets/1.json"
    )

    assert_equal "a browser has opened", result[:error]
  end

  def test_no_request_is_attempted_without_credentials
    server = build(FakeLauncher.new)
    server.send(:zendesk_request, "GET", "/api/v2/tickets/1.json")

    assert_empty server.attempts
  end
end

class TestTicketComments < Minitest::Test
  def setup
    @saved = ENV["ZENDESK_DOMAIN"]
    ENV["ZENDESK_DOMAIN"] = SERVER_DOMAIN
  end

  def teardown
    ENV["ZENDESK_DOMAIN"] = @saved
    ENV.delete("ZENDESK_DOMAIN") if @saved.nil?
  end

  def comment(id, author_id: 10, public: true)
    {
      "id" => id, "author_id" => author_id, "public" => public,
      "plain_body" => "body #{id}", "html_body" => "<p>body #{id}</p>",
      "created_at" => "2026-10-01T12:00:00Z", "metadata" => { "system" => {} },
      "attachments" => [
        { "file_name" => "a.pdf", "content_url" => "https://files/a.pdf",
          "content_type" => "application/pdf", "size" => 42, "thumbnails" => [] }
      ]
    }
  end

  def page(comments, users: [], next_cursor: nil)
    body = {
      "comments" => comments,
      "users" => users,
      "meta" => { "has_more" => !next_cursor.nil? },
      "links" => { "next" => next_cursor && "https://#{SERVER_DOMAIN}/api/v2/tickets/5/comments.json?include=users&page%5Bafter%5D=#{next_cursor}&page%5Bsize%5D=100" }
    }
    FakeResponse.new(200, body.to_json)
  end

  def build(responses)
    StubServer.new(oauth: FakeOAuth.new(tokens: ["token-1"]), responses: responses)
  end

  def test_comments_are_trimmed_to_what_a_reader_needs
    server = build([page([comment(1)], users: [{ "id" => 10, "name" => "Ada", "email" => "ada@example.com", "phone" => "x" }])])

    result = server.send(:get_ticket_comments, { "ticket_id" => 5 })
    first = result[:comments].first

    assert_equal 5, result[:ticket_id]
    assert_equal 1, result[:count]
    assert_equal false, result[:truncated]
    assert_equal({ id: 10, name: "Ada", email: "ada@example.com" }, first[:author])
    assert_equal "body 1", first[:body]
    assert_equal true, first[:public]
    assert_equal "2026-10-01T12:00:00Z", first[:created_at]
    assert_equal [{ file_name: "a.pdf", content_url: "https://files/a.pdf", content_type: "application/pdf", size: 42 }], first[:attachments]
    refute first.key?(:html_body)
  end

  def test_the_first_request_sideloads_users_and_asks_for_full_pages
    server = build([page([comment(1)])])
    server.send(:get_ticket_comments, { "ticket_id" => 5 })

    assert_equal "/api/v2/tickets/5/comments.json?include=users&page[size]=100", server.attempts.first[:path]
  end

  # Internal notes are part of the story; the flag lets the reader tell them apart.
  def test_internal_notes_are_kept_and_marked
    server = build([page([comment(1), comment(2, public: false)])])

    result = server.send(:get_ticket_comments, { "ticket_id" => 5 })

    assert_equal [true, false], result[:comments].map { |c| c[:public] }
  end

  def test_every_page_is_followed_and_authors_from_any_page_are_resolved
    server = build([
      page([comment(1, author_id: 10)], users: [{ "id" => 10, "name" => "Ada", "email" => "a@x" }], next_cursor: "abc"),
      page([comment(2, author_id: 11)], users: [{ "id" => 11, "name" => "Bo", "email" => "b@x" }])
    ])

    result = server.send(:get_ticket_comments, { "ticket_id" => 5 })

    assert_equal [1, 2], result[:comments].map { |c| c[:id] }
    assert_equal ["Ada", "Bo"], result[:comments].map { |c| c[:author][:name] }
    assert_match(/page%5Bafter%5D=abc/, server.attempts[1][:path])
  end

  def test_an_unknown_author_still_reports_the_id
    server = build([page([comment(1, author_id: 99)])])

    result = server.send(:get_ticket_comments, { "ticket_id" => 5 })

    assert_equal({ id: 99, name: nil, email: nil }, result[:comments].first[:author])
  end

  def test_paging_stops_at_the_cap_and_says_so
    pages = Array.new(ZendeskMCPServer::MAX_COMMENT_PAGES) { |i| page([comment(i)], next_cursor: "c#{i}") }
    server = build(pages)

    result = server.send(:get_ticket_comments, { "ticket_id" => 5 })

    assert_equal ZendeskMCPServer::MAX_COMMENT_PAGES, server.attempts.length
    assert_equal true, result[:truncated]
  end

  def test_a_failed_page_returns_the_error
    server = build([FakeResponse.new(404, '{"error":"RecordNotFound"}', "Not Found")])

    result = server.send(:get_ticket_comments, { "ticket_id" => 5 })

    assert_match(/404/, result[:error].to_s)
  end

  def test_the_tool_is_listed_and_dispatched
    server = build([page([comment(1)])])
    tools = server.send(:handle_tools_list, { "id" => 1 })[:result][:tools].map { |t| t[:name] }
    response = server.send(:handle_tools_call, { "id" => 2, "params" => { "name" => "get_ticket_comments", "arguments" => { "ticket_id" => 5 } } })

    assert_includes tools, "get_ticket_comments"
    assert_equal 1, JSON.parse(response[:result][:content].first[:text])["count"]
  end

  # The single-ticket endpoint ignores a comments sideload, so asking for one
  # only suggested comments would come back.
  def test_get_ticket_no_longer_asks_for_comments
    server = build([FakeResponse.new(200, '{"ticket":{"id":5}}')])
    server.send(:get_ticket, { "ticket_id" => 5 })

    assert_equal "/api/v2/tickets/5.json?include=users", server.attempts.first[:path]
  end
end
