# vim: syntax=Ruby

require 'hoe'

require './lib/memcache'

DEV_DOC_PATH = "Libraries/memcache-client"

hoe = Hoe.new 'memcache-client', MemCache::VERSION do |p|
  p.summary = 'A Ruby memcached client'
  p.description = 'memcache-client is a pure-ruby client to Danga\'s memcached.'
  p.author = ['Eric Hodel', 'Robert Cottrell']
  p.email = 'eric@robotcoop.com'
  p.url = "http://dev.robotcoop.com/#{DEV_DOC_PATH}"
  p.changes = File.read('History.txt').scan(/\A(=.*?)^=/m).first.first

  p.rubyforge_name = 'seattlerb'
  p.extra_deps << ['ZenTest', '>= 3.4.2']
end

SPEC = hoe.spec

begin
  require '../tasks'
rescue LoadError
end

