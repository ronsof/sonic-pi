#!/usr/bin/env ruby
#--
# This file is part of Sonic Pi: http://sonic-pi.net
# Full project source: https://github.com/samaaron/sonic-pi
# License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
#
# Copyright 2013, 2014, 2015, 2016 by Sam Aaron (http://sam.aaron.name).
# All rights reserved.
#
# Permission is granted for use, copying, modification, and
# distribution of modified versions of this work as long as this
# notice is included.
#++

require_relative "../core.rb"

require 'optparse'
require 'rubame'
require 'webrick'
require 'json'

require_relative "../sonicpi/lib/sonicpi/studio"
require_relative "../sonicpi/lib/sonicpi/runtime"
require_relative "../sonicpi/lib/sonicpi/server"
require_relative "../sonicpi/lib/sonicpi/util"
require_relative "../sonicpi/lib/sonicpi/rcv_dispatch"

require "memoist"

include SonicPi::Util

ws_out = Queue.new
web_server = nil
web_server_ip = "127.0.0.1"

sonic_pi_ports = {
  server_port: 4557,
  scsynth_port: 4556,
  scsynth_send_port: 4556,
  osc_cues_port: 4559,
  osc_midi_in_port: 4561,
  osc_midi_out_port: 4562,
  erlang_port: 4560 }

OptionParser.new do |opts|
  opts.banner = "Usage: example.rb [options]"

  opts.on("--ws_ip", "IP address to bind web server to", String) do |ip|
    web_server_ip = ip
  end
end.parse!

at_exit do
  puts "Exiting - shutting down web server..."
  web_server.shutdown if web_server
end

puts "starting server stuff"
# This is pretty klunky at the moment
# Find a way to hide it from clients...
user_methods = Module.new
name = "SonicPiSpiderUser1" # this should be autogenerated
klass = Object.const_set name, Class.new(SonicPi::Runtime)


klass.send(:include, user_methods)
klass.send(:include, SonicPi::Lang::Core)
klass.send(:include, SonicPi::Lang::Sound)
klass.send(:extend, Memoist)

puts "starting sp"
$sp =  klass.new "127.0.0.1", sonic_pi_ports, ws_out, user_methods
puts "finished starting sp"
$rd = SonicPi::RcvDispatch.new($sp, ws_out)
$clients = []


# Send stuff out from Sonic Pi jobs out to GUI
out_t = Thread.new do
  loop do
    begin
      message = ws_out.pop
      if debug_mode
        raise "message not a Hash!" unless message.is_a? Hash
      end
      message[:ts] = Time.now.strftime("%H:%M:%S")

      if debug_mode
        puts "sending:"
        puts "#{JSON.fast_generate(message)}"
        puts "---"
      end
      $clients.each{|c| c.send(JSON.fast_generate(message))}
    rescue Exception => e
      puts e.message
      puts e.backtrace.inspect
    end
  end
end

# Receive events from the GUI to Sonic Pi (potentially creating new jobs)

ws_server = Rubame::Server.new(web_server_ip, 8001)

in_t = Thread.new do
  while true
    ws_server.run do |client|
      client.onopen do
        client.send(JSON.fast_generate({:type => :message, :val => "Connection initiated..."}))
        $clients << client
        puts "New Websocket Client: \n#{client.frame} \n #{client.socket} \n"

      end
      client.onmessage do |msg|
        begin
          parsed = JSON.parse(msg)
          $rd.dispatch parsed
        rescue Exception => e
          puts "Unable to parse: #{msg}"
          puts "Reason: #{e}"
          puts "Backtrace: #{e.backtrace}"
        end
      end
      client.onclose do
        $clients.delete client
        warn("Connection closed...")
      end
    end
  end
end

$web_server = WEBrick::HTTPServer.new :Port => 8000, :BindAddress => web_server_ip , :DocumentRoot => html_public_path

web_t = Thread.new { $web_server.start}



out_t.join
in_t.join
web_t.join
