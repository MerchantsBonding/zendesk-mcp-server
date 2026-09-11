#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/zendesk_token_store'

class TestZendeskTokenStore < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "nested", "token.json")
    @store = ZendeskTokenStore.new(path: @path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_read_returns_nil_when_no_file_exists
    assert_nil @store.read
  end

  def test_read_returns_nil_for_a_corrupt_file
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "{not json")

    assert_nil @store.read
  end

  def test_write_then_read_round_trips_the_record
    @store.write("access_token" => "abc", "expires_at" => 42)

    assert_equal({ "access_token" => "abc", "expires_at" => 42 }, @store.read)
  end

  def test_write_creates_missing_directories
    @store.write("access_token" => "abc")

    assert File.exist?(@path)
  end

  def test_written_file_is_readable_by_the_owner_only
    @store.write("access_token" => "abc")

    assert_equal 0o600, File.stat(@path).mode & 0o777
  end

  def test_write_tightens_permissions_on_an_existing_loose_file
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "{}")
    File.chmod(0o644, @path)

    @store.write("access_token" => "abc")

    assert_equal 0o600, File.stat(@path).mode & 0o777
  end

  def test_delete_removes_the_record
    @store.write("access_token" => "abc")

    @store.delete

    assert_nil @store.read
  end

  def test_delete_is_safe_when_no_record_exists
    @store.delete
  end

  def test_with_lock_returns_the_block_result
    assert_equal :done, @store.with_lock { :done }
  end

  def test_with_lock_releases_the_lock_when_the_block_raises
    assert_raises(RuntimeError) { @store.with_lock { raise "boom" } }

    assert_equal :recovered, @store.with_lock { :recovered }
  end

  # The refresh token is single use, so two server processes must not refresh at
  # the same time. Prove the lock actually excludes a separate process.
  def test_the_lock_excludes_another_process
    @store.with_lock do
      busy = system(
        RbConfig.ruby, "-e",
        "require_relative '#{File.expand_path("lib/zendesk_token_store.rb")}'; " \
        "exit(ZendeskTokenStore.new(path: '#{@path}').try_lock ? 0 : 3)",
        out: File::NULL, err: File::NULL
      )
      refute busy, "a second process acquired the lock while it was held"
      assert_equal 3, $?.exitstatus
    end
  end

  def test_the_lock_is_available_once_released
    @store.with_lock { :noop }

    acquired = system(
      RbConfig.ruby, "-e",
      "require_relative '#{File.expand_path("lib/zendesk_token_store.rb")}'; " \
      "exit(ZendeskTokenStore.new(path: '#{@path}').try_lock ? 0 : 3)",
      out: File::NULL, err: File::NULL
    )
    assert acquired, "the lock was not released"
  end
end

class TestAtomicWrites < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "token.json")
    @store = ZendeskTokenStore.new(path: @path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # Writing in place truncates the file first, so a crash mid-write destroys the
  # refresh token. Replacing by rename keeps the old record readable until the
  # new one is complete, and swaps the inode rather than reusing it.
  def test_the_record_is_replaced_rather_than_overwritten_in_place
    @store.write("access_token" => "first")
    first_inode = File.stat(@path).ino

    @store.write("access_token" => "second")

    refute_equal first_inode, File.stat(@path).ino,
                 "expected the file to be replaced atomically, not truncated and rewritten"
    assert_equal "second", @store.read["access_token"]
  end

  def test_no_temporary_files_are_left_behind
    @store.write("access_token" => "good")

    leftovers = Dir.children(@dir).reject { |name| name == "token.json" || name.end_with?(".lock") }
    assert_empty leftovers, "the temporary file was not cleaned up"
  end

  def test_a_replacement_write_keeps_owner_only_permissions
    @store.write("access_token" => "first")
    @store.write("access_token" => "second")

    assert_equal 0o600, File.stat(@path).mode & 0o777
  end
end
