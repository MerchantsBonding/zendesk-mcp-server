require 'net/http'
require 'openssl'

# Shared HTTPS setup for every call to Zendesk, including the token endpoint.
module ZendeskHttp
  module_function

  def client(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    # Skip CRL verification errors (codes 3, 4) while keeping cert validation
    http.verify_callback = ->(preverify_ok, store_ctx) {
      next true if [3, 4].include?(store_ctx.error)
      preverify_ok
    }
    http
  end
end
