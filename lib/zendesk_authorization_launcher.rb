require 'fileutils'
require 'rbconfig'
require_relative 'zendesk_token_store'

# Runs inside the MCP server, whose STDOUT carries the JSON-RPC stream. Two
# rules hold throughout: never block, and never let the child touch STDOUT.
class ZendeskAuthorizationLauncher
  LOG_BASENAME = "authorize.log"
  MARKER_BASENAME = "authorize.started"
  LOCK_BASENAME = "authorize.lock"
  # How long a started flow is assumed to still be waiting.
  IN_PROGRESS_SECONDS = 180

  def self.browser_available?
    RUBY_PLATFORM.include?("darwin") || RUBY_PLATFORM.include?("linux")
  end

  # Launching is on by default. ZENDESK_AUTO_AUTHORIZE=0 turns it off.
  def self.enabled?(env = ENV)
    !%w[0 false no].include?(env["ZENDESK_AUTO_AUTHORIZE"].to_s.downcase)
  end

  def initialize(script_path:, cache_dir: File.dirname(ZendeskTokenStore.default_path),
                 enabled: self.class.enabled?, browser_available: self.class.browser_available?,
                 spawner: nil)
    @script_path = script_path
    @cache_dir = cache_dir
    @enabled = enabled
    @browser_available = browser_available
    @spawner = spawner || method(:spawn_detached)
  end

  # Never raises, never blocks.
  def launch(reason)
    return manual_message(reason) unless @enabled
    return manual_message(reason) unless @browser_available

    FileUtils.mkdir_p(@cache_dir, mode: 0o700)
    return in_progress_message(reason) unless claim_attempt

    @spawner.call(authorize_command, log_path)
    started_message(reason)
  rescue StandardError
    # A tool call must still answer, even when the flow cannot be started.
    manual_message(reason)
  end

  def spawn_options(log_path)
    {
      # Redirect away from the parent. Inheriting STDOUT would corrupt the
      # JSON-RPC stream with the authorizer's own output.
      out: [log_path, "a"],
      err: %i[child out],
      # Survive the server process, and stay out of its process group.
      pgroup: true
    }
  end

  def log_path
    File.join(@cache_dir, LOG_BASENAME)
  end

  private

  def authorize_command
    [RbConfig.ruby, @script_path, "--authorize"]
  end

  def spawn_detached(command, log_path)
    pid = Process.spawn(*command, **spawn_options(log_path))
    Process.detach(pid)
    pid
  end

  # Several server processes can reach this at once, so the check and the write
  # happen under a lock.
  def claim_attempt
    with_lock do
      next false if attempt_in_progress?

      File.write(marker_path, Time.now.to_i.to_s)
      true
    end
  end

  def attempt_in_progress?
    return false unless File.exist?(marker_path)

    started = File.read(marker_path).to_i
    Time.now.to_i - started < IN_PROGRESS_SECONDS
  rescue SystemCallError
    false
  end

  # A lock of its own, so this never waits on a token refresh.
  def with_lock
    File.open(File.join(@cache_dir, LOCK_BASENAME), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      begin
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end
  end

  def marker_path
    File.join(@cache_dir, MARKER_BASENAME)
  end

  def started_message(reason)
    prefixed(reason,
             "A browser has opened for you to approve access. Approve it, then " \
             "run this request again. If no browser opened, the link is in #{log_path}.")
  end

  def in_progress_message(reason)
    prefixed(reason,
             "Authorization is already in progress. Approve it in your browser, " \
             "then run this request again. The link is in #{log_path}.")
  end

  def manual_message(reason)
    prefixed(reason, "Run: ruby #{@script_path} --authorize")
  end

  def prefixed(reason, text)
    return text if reason.to_s.strip.empty?

    "#{reason.strip} #{text}"
  end
end
