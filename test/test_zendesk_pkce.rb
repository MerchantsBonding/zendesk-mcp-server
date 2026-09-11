#!/usr/bin/env ruby

require 'minitest/autorun'
require 'digest'
require_relative '../lib/zendesk_pkce'

class TestZendeskPkce < Minitest::Test
  def test_verifier_length_is_within_the_range_zendesk_accepts
    100.times do
      verifier = ZendeskPkce.new.verifier
      assert_operator verifier.length, :>=, 43
      assert_operator verifier.length, :<=, 128
    end
  end

  def test_verifier_uses_only_unreserved_characters
    50.times do
      assert_match(/\A[A-Za-z0-9\-._~]+\z/, ZendeskPkce.new.verifier)
    end
  end

  def test_each_instance_generates_a_different_verifier
    verifiers = Array.new(50) { ZendeskPkce.new.verifier }
    assert_equal 50, verifiers.uniq.length
  end

  def test_challenge_is_the_base64url_sha256_of_the_verifier
    pkce = ZendeskPkce.new
    expected = [Digest::SHA256.digest(pkce.verifier)].pack("m0").tr("+/", "-_").delete("=")

    assert_equal expected, pkce.challenge
  end

  def test_challenge_carries_no_base64_padding_or_unsafe_characters
    pkce = ZendeskPkce.new

    refute_includes pkce.challenge, "="
    refute_includes pkce.challenge, "+"
    refute_includes pkce.challenge, "/"
  end

  def test_method_is_s256
    assert_equal "S256", ZendeskPkce::METHOD
  end

  def test_a_supplied_verifier_is_used_unchanged
    verifier = "a" * 64
    pkce = ZendeskPkce.new(verifier)

    assert_equal verifier, pkce.verifier
  end
end
