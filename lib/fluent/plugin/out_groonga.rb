# -*- coding: utf-8 -*-
#
# Copyright (C) 2012  Kouhei Sutou <kou@clear-code.com>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License version 2.1 as published by the Free Software Foundation.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

require "fileutils"
require "cgi/util"

module Fluent
  class GroongaOutput < BufferedOutput
    Plugin.register_output("groonga", self)

    def initialize
      super
    end

    config_param :protocol, :string, :default => "http"
    config_param :table, :string, :default => nil

    def configure(conf)
      super
      case @protocol
      when "http"
        @client = HTTPClient.new
      when "gqtp"
        @client = GQTPClient.new
      when "command"
        @client = CommandClient.new
      end
      @client.configure(conf)
    end

    def start
      super
      @client.start
    end

    def shutdown
      super
      @client.shutdown
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      chunk.msgpack_each do |tag, time, parameters|
        if /\Agroonga\.command\./ =~ tag
          command = $POSTMATCH
          @client.send(command, parameters)
        else
          store_chunk(chunk)
        end
      end
    end

    private
    def store_chunk(chunk)
      return if @table.nil?

      data = []
      chunk.each do |time, parameters|
        data << parameters
      end
      parameters = {
        "table" => @table,
        "data" => Yajl::Enocder.encode(data),
      }
      @client.send("load", parameters)
    end

    class HTTPClient
      include Configurable

      config_param :host, :string, :default => "localhost"
      config_param :port, :integer, :default => 10041

      def start
        @loop = Coolio::Loop.new
      end

      def shutdown
        @loop.shutdown
        @thread.join if @thread
      end

      def send(command, arguments)
        path = "/d/#{command}"
        http_arguments = arguments.collect do |key, value|
          "#{CGI.escape(key)}=#{CGI.escape(value)}"
        end
        unless http_arguments.empty?
          path << "?#{http_arguments.join('&')}"
        end
        client = GroongaHTTPClient.connect(@host, @port)
        client.request("GET", path)
        @loop.attach(client)
        if @thread.nil?
          @thread = Thread.new do
            @loop.run
            @thread = nil
          end
        end
      end

      class GroongaHTTPClient < Coolio::HttpClient
      end
    end

    class GQTPClient
      include Configurable

      config_param :host, :string, :default => "localhost"
      config_param :port, :integer, :default => 10041
    end

    class CommandClient
      include Configurable

      config_param :groonga, :string, :default => "groonga"
      config_param :database, :string
      config_param :arguments, :default => [] do |value|
        Shellwords.split(value)
      end

      def initialize
        super
      end

      def configure(conf)
        super
      end

      def start
        env = {}
        @input = IO.pipe("ASCII-8BIT")
        @output = IO.pipe("ASCII-8BIT")
        @error = IO.pipe("ASCII-8BIT")
        input_fd = @input[0].to_i
        output_fd = @output[1].to_i
        options = {
          input_fd => input_fd,
          output_fd => output_fd,
          :err => @error[1],
        }
        arguments = @arguments
        arguments += [
          "--input-fd", input_fd.to_s,
          "--output-fd", output_fd.to_s,
        ]
        unless File.exist?(@database)
          FileUtils.mkdir_p(File.dirname(@database))
          arguments << "-n"
        end
        arguments << @database
        @pid = spawn(env, @groonga, *arguments, options)
        @input[0].close
        @output[1].close
        @error[1].close
      end

      def shutdown
        @input[1].close
        @output[0].close
        @error[0].close
        Process.waitpid(@pid)
      end

      def send(command, arguments={})
        body = nil
        if command == "load"
          body = arguments.delete("data")
        end
        url_encoded_arguments = arguments.collect do |key, value|
          "#{CGI.escape(key)}=#{CGI.escape(value)}"
        end
        path = "/d/#{command}"
        unless url_encoded_arguments.empty?
          path << "?#{url_encoded_arguments.join('&')}"
        end
        @input[1].write("#{path}\n")
        if body
          body.each_line do |line|
            @input[1].write("#{line}\n")
          end
        end
        @input[1].flush
        # p @output[0].gets
      end
    end
  end
end
