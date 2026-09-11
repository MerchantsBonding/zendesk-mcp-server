#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/zendesk_authorization_launcher'

SCRIPT = "/somewhere/zendesk_mcp_server.rb"
REASON = "The refresh token expired."

class TestAuthorizationLauncher < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @spawns = []
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build(enabled: true, browser_available: true, spawner: nil)
    spawner ||= ->(command, log_path) { @spawns << [command, log_path]; 4242 }
    ZendeskAuthorizationLauncher.new(
      script_path: SCRIPT,
      cache_dir: @dir,
      enabled: enabled,
      browser_available: browser_available,
      spawner: spawner
    )
  end

  def test_a_flow_is_started_when_none_is_running
    message = build.launch(REASON)

    assert_equal 1, @spawns.length
    assert_includes message, "browser"
  end

  def test_the_spawned_command_runs_the_authorize_step
    build.launch(REASON)

    command, = @spawns.first
    assert_equal SCRIPT, command[1]
    assert_equal "--authorize", command[2]
    assert_includes command[0], "ruby"
  end

  def test_the_message_names_the_log_file_for_when_no_browser_opens
    message = build.launch(REASON)

    assert_includes message, File.join(@dir, "authorize.log")
  end

  def test_the_message_repeats_the_reason
    assert_includes build.launch(REASON), REASON
  end

  def test_the_message_asks_for_the_request_to_be_retried
    assert_match(/again/i, build.launch(REASON))
  end

  # Several MCP server processes can fail at the same moment. Only one browser
  # should open, and only one process should claim port 4567.
  def test_a_second_attempt_while_one_is_running_does_not_start_another
    launcher = build
    launcher.launch(REASON)

    message = launcher.launch(REASON)

    assert_equal 1, @spawns.length, "a second browser must not open"
    assert_match(/already in progress/i, message)
  end

  def test_a_separate_launcher_also_sees_a_running_flow
    build.launch(REASON)

    message = build.launch(REASON)

    assert_equal 1, @spawns.length
    assert_match(/already in progress/i, message)
  end

  def test_a_stale_marker_allows_a_new_flow
    launcher = build
    launcher.launch(REASON)

    marker = File.join(@dir, "authorize.started")
    old = Time.now - ZendeskAuthorizationLauncher::IN_PROGRESS_SECONDS - 1
    File.write(marker, old.to_i.to_s)

    launcher.launch(REASON)

    assert_equal 2, @spawns.length
  end

  def test_nothing_is_started_when_disabled
    message = build(enabled: false).launch(REASON)

    assert_empty @spawns
    assert_includes message, "--authorize"
  end

  def test_nothing_is_started_without_a_browser
    message = build(browser_available: false).launch(REASON)

    assert_empty @spawns, "must not open a browser nobody can see"
    assert_includes message, "--authorize"
  end

  # The launcher runs inside a tool call. It must never take the server down.
  def test_a_failure_to_spawn_is_reported_rather_than_raised
    failing = ->(_command, _log) { raise Errno::ENOENT, "ruby" }

    message = build(spawner: failing).launch(REASON)

    assert_includes message, "--authorize"
  end

  # STDOUT of the server process is the JSON-RPC wire. A child that inherits it
  # corrupts every response.
  def test_the_child_never_inherits_the_protocol_stream
    options = build.spawn_options(File.join(@dir, "authorize.log"))

    assert_equal [File.join(@dir, "authorize.log"), "a"], options[:out]
    assert_equal %i[child out], options[:err]
    refute_equal :inherit, options[:out]
  end

  def test_the_child_is_detached_from_the_server_process_group
    assert_equal true, build.spawn_options(File.join(@dir, "authorize.log"))[:pgroup]
  end

  def test_the_cache_directory_is_created_when_missing
    nested = File.join(@dir, "deep", "cache")
    launcher = ZendeskAuthorizationLauncher.new(
      script_path: SCRIPT,
      cache_dir: nested,
      enabled: true,
      browser_available: true,
      spawner: ->(_c, _l) { 1 }
    )

    launcher.launch(REASON)

    assert File.directory?(nested)
  end
end

class TestMessagesWithoutAReason < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @spawns = []
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build
    ZendeskAuthorizationLauncher.new(
      script_path: SCRIPT,
      cache_dir: @dir,
      enabled: true,
      browser_available: true,
      spawner: ->(command, log) { @spawns << [command, log]; 1 }
    )
  end

  # A caller with no specific cause should not produce a doubled or
  # space-prefixed sentence.
  def test_a_started_message_reads_cleanly_without_a_reason
    message = build.launch(nil)

    assert message.start_with?("A browser has opened"), message
  end

  def test_an_in_progress_message_reads_cleanly_without_a_reason
    launcher = build
    launcher.launch(nil)

    message = launcher.launch(nil)

    assert message.start_with?("Authorization is already in progress"), message
  end

  def test_a_manual_message_reads_cleanly_without_a_reason
    launcher = ZendeskAuthorizationLauncher.new(
      script_path: SCRIPT, cache_dir: @dir, enabled: false,
      browser_available: true, spawner: ->(_c, _l) { 1 }
    )

    assert launcher.launch(nil).start_with?("Run: ruby"), launcher.launch(nil)
  end

  def test_an_empty_reason_is_treated_as_no_reason
    assert build.launch("").start_with?("A browser has opened")
  end
end
