require 'json'
require 'net/http'
require 'uri'
require_relative 'zendesk_http'
require_relative 'zendesk_token_store'

class ZendeskOAuth
  # `reason` is the cause alone, so callers can word their own guidance.
  class AuthorizationRequired < StandardError
    COMMAND = "Run: ruby zendesk_mcp_server.rb --authorize"

    attr_reader :reason

    def initialize(reason = nil)
      @reason = reason
      super([reason, COMMAND].compact.join(" "))
    end
  end

  TOKEN_PATH = "/oauth/tokens"
  # Zendesk caps the access token at 48 hours and the refresh token at 90 days.
  # Ask for both maximums, because the defaults are 30 minutes and 30 days.
  MAX_EXPIRES_IN = 172_800
  MAX_REFRESH_EXPIRES_IN = 7_776_000
  # Retire a token early, to absorb clock skew between this host and Zendesk.
  EXPIRY_SKEW_SECONDS = 60
  # Must sit inside the OAuth client's Allowed scopes, or Zendesk answers the
  # authorization request with "Invalid scope".
  DEFAULT_SCOPES = "read tickets:write"

  def initialize(domain:, client_id:, scopes: DEFAULT_SCOPES, store: ZendeskTokenStore.new)
    @domain = domain
    @client_id = client_id
    @scopes = scopes
    @store = store
  end

  def access_token
    record = @store.read
    return record["access_token"] if fresh?(record)

    @store.with_lock do
      # Another server process may have refreshed while this one waited. Reading
      # again here is what stops two processes from spending the same single-use
      # refresh token.
      record = @store.read
      next record["access_token"] if fresh?(record)

      refresh!(record)
    end
  end

  # Keeps the refresh token. Clearing it would force a needless re-authorization.
  def invalidate!
    @store.with_lock do
      record = @store.read
      next if record.nil?

      @store.write(record.merge("expires_at" => 0))
    end
  end

  def redeem(params)
    response = begin
      post_token_request(params)
    rescue StandardError => e
      raise AuthorizationRequired, "Zendesk refused the authorization: #{e.message}."
    end

    save_token_response(response)
  end

  def save_token_response(response, previous_refresh_token: nil)
    access_token = response["access_token"]
    raise AuthorizationRequired, "The token response carried no access token." if access_token.to_s.empty?

    expires_in = positive_or(response["expires_in"], MAX_EXPIRES_IN)
    refresh_expires_in = positive_or(response["refresh_token_expires_in"], MAX_REFRESH_EXPIRES_IN)

    # Zendesk rotates the refresh token, so the replacement must be kept. When a
    # response omits it, the previous one is still valid.
    refresh_token = response["refresh_token"]
    refresh_token = previous_refresh_token if refresh_token.to_s.empty?

    @store.write(
      "access_token" => access_token,
      "expires_at" => Time.now.to_i + expires_in,
      "refresh_token" => refresh_token,
      "refresh_expires_at" => Time.now.to_i + refresh_expires_in,
      "domain" => @domain,
      "client_id" => @client_id
    )

    access_token
  end

  private

  def fresh?(record)
    return false unless usable?(record)
    return false if record["access_token"].to_s.empty?

    record["expires_at"].to_i - EXPIRY_SKEW_SECONDS > Time.now.to_i
  end

  # Changing instance or client requires authorizing again.
  def usable?(record)
    return false unless record.is_a?(Hash)
    return false unless record["domain"] == @domain
    return false unless record["client_id"] == @client_id

    true
  end

  def refresh!(record)
    refresh_token = record["refresh_token"] if usable?(record)
    raise AuthorizationRequired if refresh_token.to_s.empty?

    expiry = record["refresh_expires_at"].to_i
    raise AuthorizationRequired, "The refresh token expired." if expiry.positive? && expiry <= Time.now.to_i

    response = begin
      post_token_request(
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id,
        "scope" => @scopes,
        "expires_in" => MAX_EXPIRES_IN,
        "refresh_token_expires_in" => MAX_REFRESH_EXPIRES_IN
      )
    rescue StandardError => e
      raise AuthorizationRequired, "Zendesk refused the refresh token: #{e.message}."
    end

    save_token_response(response, previous_refresh_token: refresh_token)
  end

  def positive_or(value, fallback)
    number = value.to_i
    return fallback unless number.positive?

    number
  end

  def post_token_request(params)
    uri = URI("https://#{@domain}#{TOKEN_PATH}")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request.body = JSON.generate(params)

    response = ZendeskHttp.client(uri).request(request)
    unless response.code.to_i.between?(200, 299)
      raise "HTTP #{response.code}: #{response.body}"
    end

    JSON.parse(response.body)
  end
end
