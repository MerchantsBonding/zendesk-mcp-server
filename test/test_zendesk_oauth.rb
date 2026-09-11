#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/zendesk_oauth'
require_relative '../lib/zendesk_token_store'

DOMAIN = "example.zendesk.com"
CLIENT_ID = "client-abc"

# Records refresh calls and replays canned responses, so no test uses the network.
class StubOAuth < ZendeskOAuth
  attr_reader :calls

  def initialize(results: [], **kwargs)
    super(**kwargs)
    @calls = []
    @results = results
  end

  def post_token_request(params)
    @calls << params
    result = @results.shift
    raise "StubOAuth ran out of canned results" if result.nil?
    raise result if result.is_a?(StandardError)
    result
  end
end

class TestZendeskOAuth < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = ZendeskTokenStore.new(path: File.join(@dir, "token.json"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def save(access_token: "access-1", expires_at: Time.now.to_i + 3600,
           refresh_token: "refresh-1", refresh_expires_at: Time.now.to_i + 86_400,
           domain: DOMAIN, client_id: CLIENT_ID)
    @store.write(
      "access_token" => access_token,
      "expires_at" => expires_at,
      "refresh_token" => refresh_token,
      "refresh_expires_at" => refresh_expires_at,
      "domain" => domain,
      "client_id" => client_id
    )
  end

  def build(results: [], store: @store)
    StubOAuth.new(results: results, domain: DOMAIN, client_id: CLIENT_ID, store: store)
  end

  def refreshed(access: "access-2", refresh: "refresh-2")
    {
      "access_token" => access,
      "refresh_token" => refresh,
      "expires_in" => 172_800,
      "refresh_token_expires_in" => 7_776_000
    }
  end

  def test_a_valid_access_token_is_used_without_refreshing
    save(access_token: "access-1")

    oauth = build

    assert_equal "access-1", oauth.access_token
    assert_empty oauth.calls
  end

  def test_an_expired_access_token_is_refreshed
    save(access_token: "stale", expires_at: Time.now.to_i - 1)

    oauth = build(results: [refreshed(access: "access-2")])

    assert_equal "access-2", oauth.access_token
    assert_equal 1, oauth.calls.length
  end

  def test_an_access_token_inside_the_skew_window_is_refreshed
    save(access_token: "almost-stale", expires_at: Time.now.to_i + 30)

    oauth = build(results: [refreshed(access: "access-2")])

    assert_equal "access-2", oauth.access_token
  end

  def test_the_refresh_request_sends_no_client_secret
    save(expires_at: Time.now.to_i - 1, refresh_token: "refresh-1")

    oauth = build(results: [refreshed])
    oauth.access_token

    params = oauth.calls.first
    assert_equal "refresh_token", params["grant_type"]
    assert_equal "refresh-1", params["refresh_token"]
    assert_equal CLIENT_ID, params["client_id"]
    refute params.key?("client_secret"), "a public client must not send a secret"
  end

  # Zendesk retires a refresh token as soon as it is used. Losing the replacement
  # would force the developer to authorize again.
  def test_the_rotated_refresh_token_replaces_the_old_one
    save(expires_at: Time.now.to_i - 1, refresh_token: "refresh-1")

    oauth = build(results: [refreshed(access: "access-2", refresh: "refresh-2")])
    oauth.access_token

    record = @store.read
    assert_equal "refresh-2", record["refresh_token"]
    assert_equal "access-2", record["access_token"]
  end

  def test_refresh_records_absolute_expiry_times
    save(expires_at: Time.now.to_i - 1)

    oauth = build(results: [refreshed])
    oauth.access_token

    record = @store.read
    assert_in_delta Time.now.to_i + 172_800, record["expires_at"], 5
    assert_in_delta Time.now.to_i + 7_776_000, record["refresh_expires_at"], 5
  end

  def test_a_refresh_response_without_a_new_refresh_token_keeps_the_old_one
    save(expires_at: Time.now.to_i - 1, refresh_token: "refresh-1")

    oauth = build(results: [{ "access_token" => "access-2", "expires_in" => 172_800 }])
    oauth.access_token

    assert_equal "refresh-1", @store.read["refresh_token"]
  end

  def test_no_stored_record_asks_the_developer_to_authorize
    error = assert_raises(ZendeskOAuth::AuthorizationRequired) { build.access_token }

    assert_match(/--authorize/, error.message)
  end

  def test_a_record_without_a_refresh_token_asks_the_developer_to_authorize
    save(expires_at: Time.now.to_i - 1, refresh_token: nil)

    assert_raises(ZendeskOAuth::AuthorizationRequired) { build.access_token }
  end

  def test_an_expired_refresh_token_asks_the_developer_to_authorize
    save(expires_at: Time.now.to_i - 1, refresh_expires_at: Time.now.to_i - 1)

    error = assert_raises(ZendeskOAuth::AuthorizationRequired) { build.access_token }

    assert_match(/--authorize/, error.message)
  end

  def test_a_record_from_a_different_domain_asks_the_developer_to_authorize
    save(domain: "other.zendesk.com")

    assert_raises(ZendeskOAuth::AuthorizationRequired) { build.access_token }
  end

  def test_a_record_from_a_different_client_asks_the_developer_to_authorize
    save(client_id: "rotated-client")

    assert_raises(ZendeskOAuth::AuthorizationRequired) { build.access_token }
  end

  def test_a_rejected_refresh_token_asks_the_developer_to_authorize
    save(expires_at: Time.now.to_i - 1)

    oauth = build(results: [StandardError.new("HTTP 400: invalid_grant")])

    error = assert_raises(ZendeskOAuth::AuthorizationRequired) { oauth.access_token }
    assert_match(/--authorize/, error.message)
  end

  def test_invalidate_expires_the_access_token_but_keeps_the_refresh_token
    save(access_token: "revoked", refresh_token: "refresh-1")

    build.invalidate!

    record = @store.read
    assert_equal "refresh-1", record["refresh_token"], "must not force a re-authorization"
    refute_operator record["expires_at"], :>, Time.now.to_i
  end

  def test_invalidate_is_safe_when_nothing_is_stored
    build.invalidate!
  end
end

# A store that simulates another server process refreshing while this one waits
# for the lock.
class RacingStore < ZendeskTokenStore
  def initialize(path:, on_lock:)
    super(path: path)
    @on_lock = on_lock
  end

  def with_lock
    super do
      @on_lock.call(self)
      yield
    end
  end
end

class TestConcurrentRefresh < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "token.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # Without a re-read inside the lock, this process would refresh with a token
  # the other process has already retired.
  def test_a_refresh_by_another_process_is_adopted_instead_of_repeated
    seed = ZendeskTokenStore.new(path: @path)
    seed.write(
      "access_token" => "stale",
      "expires_at" => Time.now.to_i - 1,
      "refresh_token" => "refresh-1",
      "refresh_expires_at" => Time.now.to_i + 86_400,
      "domain" => DOMAIN,
      "client_id" => CLIENT_ID
    )

    winner = lambda do |store|
      store.write(
        "access_token" => "minted-by-other-process",
        "expires_at" => Time.now.to_i + 3600,
        "refresh_token" => "refresh-2",
        "refresh_expires_at" => Time.now.to_i + 86_400,
        "domain" => DOMAIN,
        "client_id" => CLIENT_ID
      )
    end

    store = RacingStore.new(path: @path, on_lock: winner)
    oauth = StubOAuth.new(results: [], domain: DOMAIN, client_id: CLIENT_ID, store: store)

    assert_equal "minted-by-other-process", oauth.access_token
    assert_empty oauth.calls, "must not refresh a token another process already rotated"
  end
end
