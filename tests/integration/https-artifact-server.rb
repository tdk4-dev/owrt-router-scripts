#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'openssl'
require 'webrick'
require 'webrick/https'

options = { bind: '0.0.0.0' }
OptionParser.new do |parser|
  parser.on('--root PATH') { |value| options[:root] = value }
  parser.on('--cert PATH') { |value| options[:cert] = value }
  parser.on('--key PATH') { |value| options[:key] = value }
  parser.on('--port PORT', Integer) { |value| options[:port] = value }
  parser.on('--bind ADDRESS') { |value| options[:bind] = value }
end.parse!

%i[root cert key port].each do |key|
  abort("missing --#{key}") unless options[key]
end
abort('artifact root is not a directory') unless File.directory?(options[:root])

server = WEBrick::HTTPServer.new(
  BindAddress: options[:bind],
  Port: options[:port],
  DocumentRoot: options[:root],
  SSLEnable: true,
  SSLCertificate: OpenSSL::X509::Certificate.new(File.read(options[:cert])),
  SSLPrivateKey: OpenSSL::PKey::RSA.new(File.read(options[:key])),
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO),
  AccessLog: [[STDOUT, WEBrick::AccessLog::COMBINED_LOG_FORMAT]]
)

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }
server.start
