#!/usr/bin/env ruby

# Copyright (c) 2023 Shawn M. Chapla <shawn@chapla.email>
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'fileutils'
require 'socket'
require 'time'
require 'yaml'

# FIXME: Make config nicer, as in lumberjill.rb.

module Maul
  VERSION = "0.1.0"
end

class TimeoutPrioQueue
  class Elem
    attr_reader :expiration, :ft

    def initialize(ft)
      @expiration = ft.expiration
      @ft = ft
    end

    def needs_commit?
      !@ft.expiration.nil? && @ft.expiration <= @expiration
    end
  end

  def initialize
    @elements = []
  end

  def <<(ft)
    elem = Elem.new ft
    idx = @elements.bsearch_index { |e| e.expiration > elem.expiration } ||
      @elements.length
    @elements.insert(idx, elem)
  end

  def seconds_to_next
    if @elements.length > 0
      # XXX: Add an extra second to avoid repeated 0 second timeouts
      # when close to expiration.
      [(@elements[0].expiration - Time.now + 1.5).to_i, 0].max
    else
      nil
    end
  end

  def pop_before(t)
    idx = @elements.bsearch_index { |e| e.expiration >= t } || @elements.length
    @elements.slice!(0, idx)
  end
end

class FileTree
  attr_reader :expiration

  def initialize(config, tree)
    @default_timeout = config.default_timeout
    @tree_path = File.join(config.root_path, tree)
    @config_path = File.join(@tree_path, ".config.yaml")
  end

  def commit!
    if !@file.nil?
      @file.close()
      @file = nil
    end

    @expiration = nil
  end

  def grab_file(timeoutq, &block)
    now = Time.now

    if @file.nil?
      dir = File.join(@tree_path, now.year.to_s, '%02d' % now.month)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, now.iso8601.gsub(/:/, "") + ".txt")
      @file = File::open(path, "a+")
    end

    block.call @file

    t = timeout
    if t == 0
      commit!
    else
      @expiration = now + t
      timeoutq << self
    end
  end

  def timeout
    # XXX: This would probably perform better with some sort of
    # intelligent caching, but this level of performance should be
    # sufficient for most applications.
    begin
      config_text = File.read(@config_path)
      config = YAML.load(config_text)
    rescue Errno::ENOENT
      config = {}
    end

    config.default = {}

    (config["maul"]["timeout"] || @default_timeout).to_i
  end

  def timeout=(t)
    # XXX: Again, caching would definitely speed this up, but in
    # practice it probably isn't an issue.
    FileUtils.mkdir_p(@tree_path)
    File.open(@config_path, "w") do |f|
      f.write YAML.dump({"maul" => {"timeout" => t}})
    end
  end
end

class MaulConfig
  attr_reader :fifo_path, :root_path, :default_timeout

  def initialize
    # Set defaults. Timeout is in seconds.
    @fifo_path = "/tmp/maul.fifo"
    @root_path = "/tmp/maul"
    @default_timeout = 900

    # Load configuration from user and system files.
    load_config File.join("/", "etc", "maul", "config.yaml")
    load_config File.join(Dir.home, ".config", "maul", "config.yaml")

    # Ensure types are correct.
    @fifo_path = @fifo_path.to_s
    @root_path = @root_path.to_s
    @default_timeout = @default_timeout.to_i
  end

  private

  def load_config(path)
    begin
      config_text = File.read(path)
    rescue Errno::ENOENT
      return false
    end

    config = YAML.load(config_text)
    config.default = {}

    load_config_for = -> (name) do
      c = config["maul"][name]
      if !c.nil?
        self.instance_variable_set("@" + name, c)
      end
    end

    load_config_for.call "fifo_path"
    load_config_for.call "root_path"
    load_config_for.call "default_timeout"
  end
end

class MaulFifo
  def initialize(path)
    @fifo_path = path
    @fifo = nil

    if !File::exists?(@fifo_path)
      # XXX: This will fail with an exception if for some reason the
      # file cannot be created at the desired path.
      File::mkfifo(@fifo_path)
    end

    at_exit do
      release
      File::unlink(@fifo_path)
    end
  end

  def reserve
    if @fifo.nil?
      @fifo = File::open(@fifo_path, File::RDONLY | File::NONBLOCK)
    end

    @fifo
  end

  def release
    if !@fifo.nil?
      @fifo.close
      @fifo = nil
    end
  end
end

def main
  config = MaulConfig.new
  timeoutq = TimeoutPrioQueue.new
  fifo = MaulFifo.new config.fifo_path

  trees = {}
  trees.default_proc = proc { |d, k| d[k] = FileTree.new(config, k) }

  loop do
    timeout = timeoutq.seconds_to_next
    rs, = File::select([fifo.reserve], nil, nil, timeout)

    if rs == nil
      for elem in timeoutq.pop_before Time.now do
        if elem.needs_commit?
          elem.ft.commit!
        end
      end
    else
      rs[0].readlines.each do |line|
        split_line = line.split(':', 3)
        if split_line.length != 3
          next
        end

        command, tree, payload = split_line

        case command
        when "quit"
          return 0
        when "commit"
          trees[tree].commit!
        when "timeout"
          # XXX: Resetting timeout does not affect existing expiration
          # times.
          trees[tree].timeout = payload.to_i
        when "log"
          trees[tree].grab_file(timeoutq) do |ft_file|
            ft_file.write payload.gsub(/\\n/, "\n")
            ft_file.flush
          end
        end
      end

      fifo.release
    end
  end
end

if __FILE__ == $0
  exit main
end
