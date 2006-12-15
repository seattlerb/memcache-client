$TESTING = defined? $TESTING

require 'socket'
require 'thread'
require 'timeout'
require 'rubygems'

class String

  ##
  # Uses the ITU-T polynomial in the CRC32 algorithm.

  def crc32_ITU_T
    n = length
    r = 0xFFFFFFFF

    n.times do |i|
      r ^= self[i]
      8.times do
        if (r & 1) != 0 then
          r = (r>>1) ^ 0xEDB88320
        else
          r >>= 1
        end
      end
    end

    r ^ 0xFFFFFFFF
  end

end

##
# A Ruby client library for memcached.
#
# This is intended to provide access to basic memcached functionality.  It
# does not attempt to be complete implementation of the entire API.

class MemCache

  ##
  # The version of MemCache you are using.

  VERSION = '1.2.1'

  ##
  # Default options for the cache object.

  DEFAULT_OPTIONS = {
    :namespace   => nil,
    :readonly    => false,
    :multithread => false,
  }

  ##
  # Default memcached port.

  DEFAULT_PORT = 11211

  ##
  # Default memcached server weight.

  DEFAULT_WEIGHT = 1

  ##
  # The amount of time to wait for a response from a memcached server.  If a
  # response is not completed within this time, the connection to the server
  # will be closed and an error will be raised.

  attr_accessor :request_timeout

  ##
  # The namespace for this instance

  attr_reader :namespace

  ##
  # The multithread setting for this instance

  attr_reader :multithread

  ##
  # Accepts a list of +servers+ and a list of +opts+.  +servers+ may be
  # omitted.  See +servers=+ for acceptable server list arguments.
  # 
  # Valid options for +opts+ are:
  #
  #   [:namespace]   Prepends this value to all keys added or retrieved.
  #   [:readonly]    Raises an exeception on cache writes when true.
  #   [:multithread] Wraps cache access in a Mutex for thread safety.

  def initialize(*args)
    servers = []
    opts = {}

    case args.length
    when 0 then # NOP
    when 1 then
      arg = args.shift
      case arg
      when Hash   then opts = arg
      when Array  then servers = arg
      when String then servers = [arg]
      else raise ArgumentError, 'first argument must be Array, Hash or String'
      end
    when 2 then
      servers, opts = args
    else
      raise ArgumentError, "wrong number of arguments (#{args.length} for 2)"
    end

    opts = DEFAULT_OPTIONS.merge opts
    @namespace   = opts[:namespace]
    @readonly    = opts[:readonly]
    @multithread = opts[:multithread]
    @mutex       = Mutex.new if @multithread
    @buckets     = []
    self.servers = servers
  end

  ##
  # Return a string representation of the cache object.

  def inspect
    sprintf("<MemCache: %s servers, %s buckets, ns: %p, ro: %p>",
            @servers.length, @buckets.length, @namespace, @readonly)
  end

  ##
  # Returns whether there is at least one active server for the object.

  def active?
    not @servers.empty?
  end

  ##
  # Returns whether the cache was created read only.

  def readonly?
    @readonly
  end

  ##
  # Set the servers that the requests will be distributed between.  Entries
  # can be either strings of the form "hostname:port" or
  # "hostname:port:weight" or MemCache::Server objects.

  def servers=(servers)
    # Create the server objects.
    @servers = servers.collect do |server|
      case server
      when String
        host, port, weight = server.split ':', 3
        port ||= DEFAULT_PORT
        weight ||= DEFAULT_WEIGHT
        Server.new self, host, port, weight
      when Server
        if server.memcache.multithread != @multithread then
          raise ArgumentError, "can't mix threaded and non-threaded servers"
        end
        server
      else
        raise TypeError, "cannot convert #{server.class} into MemCache::Server"
      end
    end

    # Create an array of server buckets for weight selection of servers.
    @buckets = []
    @servers.each do |server|
      server.weight.times { @buckets.push(server) }
    end
  end

  ##
  # Retrieves +key+ from memcache.

  def get(key)
    raise MemCacheError, 'No active servers' unless active?
    cache_key = make_cache_key key
    server = get_server_for_key cache_key

    raise MemCacheError, 'No connection to server' if server.socket.nil?

    value = if @multithread then
              threadsafe_cache_get server, cache_key
            else
              cache_get server, cache_key
            end

    return nil if value.nil?

    # Return the unmarshaled value.
    return Marshal.load(value)
  rescue ArgumentError, TypeError, SystemCallError, IOError => err
    server.close
    new_err = MemCacheError.new err.message
    new_err.set_backtrace err.backtrace
    raise new_err
  end

  ##
  # Retrieves multiple values from memcached in parallel, if possible.
  #
  # The memcached protocol supports the ability to retrieve multiple
  # keys in a single request.  Pass in an array of keys to this method
  # and it will:
  #
  # 1. map the key to the appropriate memcached server
  # 2. send a single request to each server that has one or more key values
  #
  # Returns a hash of values.
  #
  #   >> CACHE["a"] = 1
  #   => 1
  #   >> CACHE["b"] = 2
  #   => 2
  #   >> CACHE.get_multi(["a","b"])
  #   => {"a"=>1, "b"=>2}
  #
  # Here's a benchmark showing the speedup:
  #
  #   CACHE["a"] = 1
  #   CACHE["b"] = 2
  #   CACHE["c"] = 3
  #   CACHE["d"] = 4
  #   keys = ["a","b","c","d","e"]
  #   Benchmark.bm do |x|
  #     x.report { for i in 1..1000; keys.each{|k| CACHE.get(k);} end }
  #     x.report { for i in 1..1000; CACHE.get_multi(keys); end }
  #   end
  #
  # returns:
  #
  #       user     system      total        real
  #   0.180000   0.130000   0.310000 (  0.459418)
  #   0.200000   0.030000   0.230000 (  0.269632)
  #--
  # There's a fair amount of non-DRY between get_multi and get (and
  # threadsafe_cache_get/multi_threadsafe_cache_get and
  # cache_get/multi_cache_get for that matter) but I think it's worth it
  # since the extra overhead to handle multiple return values is unneeded
  # for a single-key get (which is by far the most common case).

  def get_multi(*keys)
    raise MemCacheError, 'No active servers' unless active?

    keys.flatten!
    key_count = keys.length
    cache_keys_keys = {}
    servers_cache_keys = Hash.new { |h,k| h[k] = [] }

    # retrieve the server to key mapping so that we know which servers to
    # send the requests to (different keys can come from different servers)
    keys.each do |key|
      cache_key = make_cache_key key
      cache_keys_keys[cache_key] = key
      server = get_server_for_key cache_key
      raise MemCacheError, 'No connection to server' if server.socket.nil?
      servers_cache_keys[server] << cache_key
    end

    values = {}

    servers_cache_keys.keys.each do |server|
      values.merge!(if @multithread then
        multi_threadsafe_cache_get server, servers_cache_keys[server].join(" ")
      else
        multi_cache_get server, servers_cache_keys[server].join(" ")
      end)
    end

    # Return the unmarshaled value.
    return_values = {}
    values.each_pair do |k,v|
      return_values[cache_keys_keys[k]] = Marshal.load v
    end

    return return_values
  rescue ArgumentError, TypeError, SystemCallError, IOError => err
    server.close
    new_err = MemCacheError.new err.message
    new_err.set_backtrace err.backtrace
    raise new_err
  end

  ##
  # Add +key+ to the cache with value +value+ that expires in +expiry+
  # seconds.

  def set(key, value, expiry = 0)
    @mutex.lock if @multithread

    raise MemCacheError, "No active servers" unless self.active?
    raise MemCacheError, "Update of readonly cache" if @readonly
    cache_key = make_cache_key(key)
    server = get_server_for_key(cache_key)

    sock = server.socket
    raise MemCacheError, "No connection to server" if sock.nil?

    marshaled_value = Marshal.dump value
    command = "set #{cache_key} 0 #{expiry} #{marshaled_value.size}\r\n#{marshaled_value}\r\n"

    begin
      sock.write command
      sock.gets
    rescue SystemCallError, IOError => err
      server.close
      raise MemCacheError, err.message
    end
  ensure
    @mutex.unlock if @multithread
  end

  ##
  # Removes +key+ from the cache in +expiry+ seconds.

  def delete(key, expiry = 0)
    @mutex.lock if @multithread

    raise MemCacheError, "No active servers" unless active?
    cache_key = make_cache_key key
    server = get_server_for_key cache_key

    sock = server.socket
    raise MemCacheError, "No connection to server" if sock.nil?

    begin
      sock.write "delete #{cache_key} #{expiry}\r\n"
      sock.gets
    rescue SystemCallError, IOError => err
      server.close
      raise MemCacheError, err.message
    end
  ensure
    @mutex.unlock if @multithread
  end

  ##
  # Reset the connection to all memcache servers.  This should be called if
  # there is a problem with a cache lookup that might have left the connection
  # in a corrupted state.

  def reset
    @servers.each { |server| server.close }
  end

  ##
  # Returns statistics for each memcached server.  An explanation of the
  # statistics can be found in the memcached docs:
  #
  # http://code.sixapart.com/svn/memcached/trunk/server/doc/protocol.txt
  #
  # Example:
  #
  #   >> pp CACHE.stats
  #   {"localhost:11211"=>
  #     {"bytes"=>"4718",
  #      "pid"=>"20188",
  #      "connection_structures"=>"4",
  #      "time"=>"1162278121",
  #      "pointer_size"=>"32",
  #      "limit_maxbytes"=>"67108864",
  #      "cmd_get"=>"14532",
  #      "version"=>"1.2.0",
  #      "bytes_written"=>"432583",
  #      "cmd_set"=>"32",
  #      "get_misses"=>"0",
  #      "total_connections"=>"19",
  #      "curr_connections"=>"3",
  #      "curr_items"=>"4",
  #      "uptime"=>"1557",
  #      "get_hits"=>"14532",
  #      "total_items"=>"32",
  #      "rusage_system"=>"0.313952",
  #      "rusage_user"=>"0.119981",
  #      "bytes_read"=>"190619"}}
  #   => nil

  def stats
    raise MemCacheError, "No active servers" unless active?
    server_stats = {}

    @servers.each do |server|
      sock = server.socket
      raise MemCacheError, "No connection to server" if sock.nil?

      value = nil
      begin
        sock.write "stats\r\n"
        stats = {}
        while line = sock.gets
          break if (line.strip rescue "END") == "END"
          line =~ /^STAT ([\w]+) ([\d.]+)/
          stats[$1] = $2
        end
        server_stats["#{server.host}:#{server.port}"] = stats.clone
      rescue SystemCallError, IOError => err
        server.close
        raise MemCacheError, err.message
      end
    end

    server_stats
  end


  ##
  # Shortcut to get a value from the cache.

  alias [] get

  ##
  # Shortcut to save a value in the cache.  This method does not set an
  # expiration on the entry.  Use set to specify an explicit expiry.

  def []=(key, value)
    set key, value
  end

  protected unless $TESTING

  ##
  # Create a key for the cache, incorporating the namespace qualifier if
  # requested.

  def make_cache_key(key)
    if namespace.nil? then
      key
    else
      "#{@namespace}:#{key}"
    end
  end

  ##
  # Pick a server to handle the request based on a hash of the key.

  def get_server_for_key(key)
    raise MemCacheError, "No servers available" if @servers.empty?
    return @servers.first if @servers.length == 1

    hkey = hash_for key

    20.times do |try|
      server = @buckets[hkey % @buckets.nitems]
      return server if server.alive?
      hkey += hash_for "#{try}#{key}"
    end

    raise MemCacheError, "No servers available"
  end

  ##
  # Returns an interoperable hash value for +key+.  (I think, docs are
  # sketchy for down servers).

  def hash_for(key)
    (key.crc32_ITU_T >> 16) & 0x7fff
  end

  ##
  # Fetches the raw data for +cache_key+ from +server+.  Returns nil on cache
  # miss.

  def cache_get(server, cache_key)
    socket = server.socket
    socket.write "get #{cache_key}\r\n"
    text = socket.gets # "VALUE <key> <flags> <bytes>\r\n"
    return nil if text == "END\r\n"

    text =~ /(\d+)\r/
    value = socket.read $1.to_i
    socket.read 2 # "\r\n"
    socket.gets   # "END\r\n"
    return value
  end

  def threadsafe_cache_get(socket, cache_key) # :nodoc:
    @mutex.lock
    cache_get socket, cache_key
  ensure
    @mutex.unlock
  end

  def multi_threadsafe_cache_get(socket, cache_key) # :nodoc:
    @mutex.lock
    multi_cache_get(socket, cache_key)
  ensure
    @mutex.unlock
  end

  def multi_cache_get(server, cache_key)
    values = {}
    socket = server.socket
    socket.write "get #{cache_key}\r\n"

    while keyline = socket.gets
      break if (keyline.strip rescue "END") == "END"
      keyline =~ /^VALUE (.+) (.+) (.+)/
      key, data_length = $1, $3
      values[$1] = socket.read data_length.to_i
      socket.read(2) # "\r\n"
    end

    return values
  end

  ##
  # This class represents a memcached server instance.

  class Server

    ##
    # The amount of time to wait to establish a connection with a memcached
    # server.  If a connection cannot be established within this time limit,
    # the server will be marked as down.

    CONNECT_TIMEOUT = 0.25

    ##
    # The amount of time to wait before attempting to re-establish a
    # connection with a server that is marked dead.

    RETRY_DELAY = 30.0

    ##
    # The host the memcached server is running on.

    attr_reader :host

    ##
    # The port the memcached server is listening on.

    attr_reader :port

    ##
    # The weight given to the server.

    attr_reader :weight

    ##
    # The time of next retry if the connection is dead.

    attr_reader :retry

    ##
    # A text status string describing the state of the server.

    attr_reader :status

    ##
    # Create a new MemCache::Server object for the memcached instance
    # listening on the given host and port, weighted by the given weight.

    def initialize(memcache, host, port = DEFAULT_PORT, weight = DEFAULT_WEIGHT)
      raise ArgumentError, "No host specified" if host.nil? or host.empty?
      raise ArgumentError, "No port specified" if port.nil? or port.to_i.zero?

      @memcache = memcache
      @host   = host
      @port   = port.to_i
      @weight = weight.to_i

      @multithread = @memcache.multithread
      @mutex = Mutex.new

      @sock   = nil
      @retry  = nil
      @status = 'NOT CONNECTED'
    end

    ##
    # Return a string representation of the server object.

    def inspect
      sprintf("<MemCache::Server: %s:%d [%d] (%s)>",
              @host, @port, @weight, @status)
    end

    ##
    # Check whether the server connection is alive.  This will cause the
    # socket to attempt to connect if it isn't already connected and or if
    # the server was previously marked as down and the retry time has
    # been exceeded.

    def alive?
      !self.socket.nil?
    end

    ##
    # Try to connect to the memcached server targeted by this object.
    # Returns the connected socket object on success or nil on failure.

    def socket
      @mutex.lock if @multithread
      return @sock if @sock and not @sock.closed?

      @sock = nil

      # If the host was dead, don't retry for a while.
      return if @retry and @retry > Time.now

      # Attempt to connect if not already connected.
      begin
        @sock = timeout CONNECT_TIMEOUT do
          TCPSocket.new @host, @port
        end
        @retry  = nil
        @status = 'CONNECTED'
      rescue SocketError, SystemCallError, IOError, Timeout::Error => err
        mark_dead err.message
      end

      return @sock
    ensure
      @mutex.unlock if @multithread
    end

    ##
    # Close the connection to the memcached server targeted by this
    # object.  The server is not considered dead.

    def close
      @mutex.lock if @multithread
      @sock.close if @sock && !@sock.closed?
      @sock   = nil
      @retry  = nil
      @status = "NOT CONNECTED"
    ensure
      @mutex.unlock if @multithread
    end

    private

    ##
    # Mark the server as dead and close its socket.

    def mark_dead(reason = "Unknown error")
      @sock.close if @sock && !@sock.closed?
      @sock   = nil
      @retry  = Time.now + RETRY_DELAY

      @status = sprintf "DEAD: %s, will retry at %s", reason, @retry
    end

  end

  ##
  # Base MemCache exception class.

  class MemCacheError < RuntimeError; end

end

