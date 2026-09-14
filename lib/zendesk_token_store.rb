require 'json'
require 'fileutils'

# Zendesk accepts each refresh token once, and an MCP client runs one server
# process per session, so writes here must be locked.
class ZendeskTokenStore
  def self.default_path
    base = ENV["XDG_CACHE_HOME"]
    base = File.join(Dir.home, ".cache") if base.nil? || base.empty?
    File.join(base, "zendesk-mcp-server", "token.json")
  end

  attr_reader :path

  def initialize(path: self.class.default_path)
    @path = path
  end

  def read
    return nil unless File.exist?(@path)

    JSON.parse(File.read(@path))
  rescue JSON::ParserError, SystemCallError, IOError
    nil
  end

  # Replaces the record by rename. Writing in place would truncate the file
  # first, so a crash mid-write would destroy the refresh token.
  def write(record)
    ensure_directory
    temp = "#{@path}.#{Process.pid}.tmp"

    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(record))
    end
    File.rename(temp, @path)
    record
  ensure
    File.delete(temp) if temp && File.exist?(temp)
  end

  def delete
    File.delete(@path) if File.exist?(@path)
  rescue SystemCallError
    nil
  end

  # The lock file is separate, so replacing the token file never drops the lock.
  def with_lock
    ensure_directory
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      begin
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end
  end

  # Used by the tests to prove the lock excludes another process.
  def try_lock
    ensure_directory
    lock = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
    return false unless lock.flock(File::LOCK_EX | File::LOCK_NB)

    @held_lock = lock
    true
  end

  def lock_path
    "#{@path}.lock"
  end

  private

  def ensure_directory
    FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
  end
end
