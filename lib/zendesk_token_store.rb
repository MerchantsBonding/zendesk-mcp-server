require 'json'
require 'fileutils'

# Reads and writes the OAuth token record, and guards it with an exclusive file
# lock.
#
# The lock matters. Zendesk rotates refresh tokens on every use and accepts each
# one only once. An MCP client starts one server process per session, so without
# the lock two sessions can refresh with the same token, and the loser is left
# holding a token Zendesk has already retired.
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

  def write(record)
    ensure_directory
    File.write(@path, JSON.generate(record))
    File.chmod(0o600, @path)
    record
  end

  def delete
    File.delete(@path) if File.exist?(@path)
  rescue SystemCallError
    nil
  end

  # Holds an exclusive lock for the duration of the block. The lock lives in a
  # file of its own, so replacing the token file never drops it.
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

  # Takes the lock without blocking, and keeps it until the process exits.
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
