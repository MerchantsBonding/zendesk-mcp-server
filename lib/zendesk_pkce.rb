require 'securerandom'
require 'digest'

# Proof Key for Code Exchange, as Zendesk requires for public OAuth clients.
#
# The verifier stays on this machine. Only its SHA-256 digest travels in the
# authorization URL, so an intercepted authorization code is useless without the
# verifier held here.
class ZendeskPkce
  METHOD = "S256"
  # Zendesk accepts a verifier of 43 to 128 characters. 64 random bytes encode
  # to 86 characters, which sits inside that range.
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

  # Base64url without padding. Built with pack, so this does not depend on the
  # base64 gem, which is no longer a default gem.
  def base64url(bytes)
    [bytes].pack("m0").tr("+/", "-_").delete("=")
  end
end
