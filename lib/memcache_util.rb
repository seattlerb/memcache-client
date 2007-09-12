##
# A utility wrapper around the MemCache client to simplify cache access.  All
# methods silently ignore MemCache errors.

module Cache

  ##
  # Returns the object at +key+ from the cache if successful, or nil if either
  # the object is not in the cache or if there was an error attermpting to
  # access the cache.
  #
  # If there is a cache miss and a block is given the result of the block will
  # be stored in the cache with optional +expiry+, using the +add+ method rather
  # than +set+.

  def self.get(key, expiry = 0)
    start_time = Time.now
    value = CACHE.get key
    elapsed = Time.now - start_time
    debug('MemCache Get (%0.6f)  %s' % [elapsed, key])
    if value.nil? and block_given? then
      value = yield
      add key, value, expiry
    end
    value
  rescue MemCache::MemCacheError => err
    debug "MemCache Error: #{err.message}"
    if block_given? then
      value = yield
      put key, value, expiry
    end
    value
  end

  ##
  # Sets +value+ in the cache at +key+, with an optional +expiry+ time in
  # seconds.

  def self.put(key, value, expiry = 0)
    start_time = Time.now
    CACHE.set key, value, expiry
    elapsed = Time.now - start_time
    debug('MemCache Set (%0.6f)  %s' % [elapsed, key])
    value
  rescue MemCache::MemCacheError => err
    debug "MemCache Error: #{err.message}"
  end

  ##
  # Sets +value+ in the cache at +key+, with an optional +expiry+ time in
  # seconds.  If +key+ already exists in cache, returns nil.

  def self.add(key, value, expiry = 0)
    start_time = Time.now
    response = CACHE.add key, value, expiry
    elapsed = Time.now - start_time
    debug('MemCache Add (%0.6f)  %s' % [elapsed, key])
    (response == "STORED\r\n") ? value : nil
  rescue MemCache::MemCacheError => err
    debug "MemCache Error: #{err.message}"
  end

  ##
  # Deletes +key+ from the cache in +delay+ seconds.

  def self.delete(key, delay = nil)
    start_time = Time.now
    CACHE.delete key, delay
    elapsed = Time.now - start_time
    debug('MemCache Delete (%0.6f)  %s' % [elapsed, key])
  rescue MemCache::MemCacheError => err
    debug "MemCache Error: #{err.message}"
  end

  ##
  # Resets all connections to MemCache servers.

  def self.reset
    CACHE.reset
    debug 'MemCache Connections Reset'
  end

  def self.debug(message)
    return nil unless defined? ActiveRecord
    ActiveRecord::Base.logger.debug message
    nil
  end

end

