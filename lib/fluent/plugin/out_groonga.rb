# -*- coding: utf-8 -*-
#
# Copyright (C) 2012-2014  Kouhei Sutou <kou@clear-code.com>
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

require "yajl"

require "groonga/client"

module Fluent
  class GroongaOutput < BufferedOutput
    Plugin.register_output("groonga", self)

    def initialize
      super
    end

    config_param :protocol, :default => :http do |value|
      case value
      when "http", "gqtp", "command"
        value.to_sym
      else
        raise ConfigError, "must be http, gqtp or command: <#{value}>"
      end
    end
    config_param :table, :string, :default => nil

    def configure(conf)
      super
      @client = create_client(@protocol)
      @client.configure(conf)

      @emitter = Emitter.new(@client, @table)
    end

    def start
      super
      @client.start
      @emitter.start
    end

    def shutdown
      super
      @emitter.shutdown
      @client.shutdown
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      @emitter.emit(chunk)
    end

    private
    def create_client(protocol)
      case protocol
      when :http, :gqtp
        NetworkClient.new(protocol)
      when :command
        CommandClient.new
      end
    end

    class Schema
      def initialize(client, table_name)
        @client = client
        @table_name = table_name
        @table = nil
        @columns = nil
      end

      def populate
        # TODO
      end

      def update(records)
        ensure_table
        ensure_columns

        nonexistent_columns = {}
        records.each do |record|
          record.each do |key, value|
            column = @columns[key]
            if column.nil?
              nonexistent_columns[key] ||= []
              nonexistent_columns[key] << value
            end
          end
        end

        nonexistent_columns.each do |name, values|
          @columns[name] = create_column(name, values)
        end
      end

      private
      def ensure_table
        return if @table

        table_list = @client.execute("table_list")
        target_table = table_list.find do |table|
          table.name == @table_name
        end
        if target_table
          @table = Table.new(@table_name, target_table.domain)
        else
          # TODO: Check response
          @client.execute("table_create",
                          "name"  => @table_name,
                          "flags" => "TABLE_NO_KEY")
          @table = Table.new(@table_name, nil)
        end
      end

      def ensure_columns
        return if @columns

        column_list = @client.execute("column_list", "table" => @table_name)
        @columns = {}
        column_list.each do |column|
          vector_p = column.flags.split("|").include?("COLUMN_VECTOR")
          @columns[column.name] = Column.new(column.name,
                                             column.range,
                                             vector_p)
        end
      end

      def create_column(name, sample_values)
        guesser = TypeGuesser.new(sample_values)
        value_type = guesser.guess
        vector_p = guesser.vector?
        if vector_p
          flags = "COLUMN_VECTOR"
        else
          flags = "COLUMN_SCALAR"
        end
        # TODO: Check response
        @client.execute("column_create",
                        "table" => @table_name,
                        "name" => name,
                        "flags" => flags,
                        "type" => value_type)
        @columns[name] = Column.new(name, value_type, vector_p)
      end

      class TypeGuesser
        def initialize(sample_values)
          @sample_values = sample_values
        end

        def guess
          return "Time"          if time_values?
          return "Int32"         if int32_values?
          return "Int64"         if int64_values?
          return "Float"         if float_values?
          return "WGS84GeoPoint" if geo_point_values?

          "Text"
        end

        def vector?
          @sample_values.any? do |sample_value|
            sample_value.is_a?(Array)
          end
        end

        private
        def time_values?
          now = Time.now.to_i
          year_in_seconds = 365 * 24 * 60 * 60
          window = 10 * year_in_seconds
          new = now + window
          old = now - window
          recent_range = old..new
          @sample_values.all? do |sample_value|
            sample_value.is_a?(Integer) and
              recent_range.cover?(sample_value)
          end
        end

        def int32_values?
          int32_min = -(2 ** 31)
          int32_max = 2 ** 31 - 1
          range = int32_min..int32_max
          @sample_values.all? do |sample_value|
            sample_value.is_a?(Integer) and
              range.cover?(sample_value)
          end
        end

        def int64_values?
          @sample_values.all? do |sample_value|
            sample_value.is_a?(Integer)
          end
        end

        def float_values?
          @sample_values.all? do |sample_value|
            sample_value.is_a?(Float) or
              sample_value.is_a?(Integer)
          end
        end

        def geo_point_values?
          @sample_values.all? do |sample_value|
            sample_value.is_a?(String) and
              /\A-?\d+(?:\.\d+)[,x]-?\d+(?:\.\d+)\z/ =~ sample_value
          end
        end
      end

      class Table
        def initialize(name, key_type)
          @name = name
          @key_type = key_type
        end
      end

      class Column
        def initialize(name, value_type, vector_p)
          @name = name
          @value_type = value_type
          @vector_p = vector_p
        end
      end
    end

    class Emitter
      def initialize(client, table)
        @client = client
        @table = table
        @schema = nil
      end

      def start
        @schema = Schema.new(@client, @table)
      end

      def shutdown
      end

      def emit(chunk)
        records = []
        chunk.msgpack_each do |message|
          tag, _, record = message
          if /\Agroonga\.command\./ =~ tag
            name = $POSTMATCH
            unless records.empty?
              store_records(records)
              records.clear
            end
            @client.execute(name, record)
          else
            records << record
          end
        end
        store_records(records) unless records.empty?
      end

      private
      def store_records(records)
        return if @table.nil?

        @schema.update(records)

        arguments = {
          "table" => @table,
          "values" => Yajl::Encoder.encode(records),
        }
        @client.execute("load", arguments)
      end
    end

    class BaseClient
      private
      def build_command(name, arguments={})
        command_class = Groonga::Command.find(name)
        command_class.new(name, arguments)
      end
    end

    class NetworkClient < BaseClient
      include Configurable

      config_param :host, :string, :default => nil
      config_param :port, :integer, :default => nil

      def initialize(protocol)
        super()
        @protocol = protocol
      end

      def start
        @client = nil
      end

      def shutdown
        return if @client.nil?
        @client.close
      end

      def execute(name, arguments={})
        command = build_command(name, arguments)
        @client ||= Groonga::Client.new(:protocol => @protocol,
                                        :host     => @host,
                                        :port     => @port,
                                        :backend  => :synchronous)
        @client.execute(command)
      end
    end

    class CommandClient < BaseClient
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
        run_groonga
      end

      def shutdown
        @input.close
        read_output("shutdown")
        @output.close
        @error.close
        Process.waitpid(@pid)
      end

      def execute(name, arguments={})
        command = build_command(name, arguments)
        body = nil
        if command.name == "load"
          body = command.arguments.delete(:values)
        end
        uri = command.to_uri_format
        @input.write("#{uri}\n")
        if body
          body.each_line do |line|
            @input.write("#{line}\n")
          end
        end
        @input.flush
        read_output(uri)
      end

      private
      def run_groonga
        env = {}
        input = IO.pipe("ASCII-8BIT")
        output = IO.pipe("ASCII-8BIT")
        error = IO.pipe("ASCII-8BIT")
        input_fd = input[0].to_i
        output_fd = output[1].to_i
        options = {
          input_fd => input_fd,
          output_fd => output_fd,
          :err => error[1],
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
        input[0].close
        @input = input[1]
        output[1].close
        @output = output[0]
        error[1].close
        @error = error[0]
      end

      def read_output(context)
        output_message = ""
        error_message = ""

        loop do
          readables = IO.select([@output, @error], nil, nil, 0)
          break if readables.nil?

          readables.each do |readable|
            case readable
            when @output
              output_message << @output.gets
            when @error
              error_message << @error.gets
            end
          end
        end

        unless output_message.empty?
          Engine.log.debug("[output][groonga][output]",
                           :context => context,
                           :message => output_message)
        end
        unless error_message.empty?
          Engine.log.error("[output][groonga][error]",
                           :context => context,
                           :message => error_message)
        end
      end
    end
  end
end
