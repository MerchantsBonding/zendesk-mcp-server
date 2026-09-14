require 'securerandom'
require 'digest'

# Zendesk requires PKCE for public OAuth clients.
class ZendeskPkce
  METHOD = "S256"
  # Zendesk accepts 43 to 128 characters. 64 bytes encode to 86.
  VERIFIER_BYTES = 64

  attr_reader :verifier

  def initialize(verifier = self.class.generate_verifier)
    @verifier = verifier
  end

  def challenge
    base64url(Digest::SHA256.digest(@verifier))
  end

  def self.generate_verifier
    SecureRandom.urlsafe_base64(VERIFIER_BYTES, false)
  end

  private

  # Uses pack, because base64 is no longer a default gem.
  def base64url(bytes)
    [bytes].pack("m0").tr("+/", "-_").delete("=")
  end
end
