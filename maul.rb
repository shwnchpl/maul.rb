#!/usr/bin/env ruby

require 'fileutils'
require 'socket'
require 'time'

# TODO: Remove unnecessary logging.
# Actually load and sync to configs using YAML.

class TimeoutPrioQueue
  class Elem
    attr_reader :expiration, :ft

    def initialize(ft)
      @expiration = ft.expiration
      @ft = ft
    end

    def needs_commit?
      return !@ft.expiration.nil? && @ft.expiration <= @expiration
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
      return [(@elements[0].expiration - Time.now + 1.5).to_i, 0].max
    else
      return nil
    end
  end

  def pop_before(t)
    idx = @elements.bsearch_index { |e| e.expiration >= t } || @elements.length
    return @elements.slice!(0, idx)
  end
end

class FileTree
  attr_accessor :timeout
  attr_reader :expiration

  def initialize(config, tree)
    # FIXME: Load/create configuration file. Update config file on
    # timeout update as well.

    @timeout = config.default_timeout
    @tree_path = File.join(config.root_path, tree)
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
      dir = File.join(@tree_path, now.year.to_s, now.month.to_s)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, now.iso8601.gsub(/:/, "") + ".txt")
      @file = File::open(path, "a+")
    end

    block.call(@file)

    if @timeout == 0
      commit!
    else
      @expiration = now + @timeout
      timeoutq << self
    end
  end
end

class MaulConfig
  attr_reader :fifo_path, :root_path, :default_timeout

  def initialize
    # Set defaults.
    @fifo_path = "/tmp/maul.fifo"
    @root_path = "/tmp/maul"
    @default_timeout = 900          # 15 minutes

    # FIXME: Read config file!
    # First check for a user configuration file in ~/.maulrc.
    # If that doesn't exist, check for a system config file in
    # /etc/maulrc.
  end
end

class MaulFifo
  def initialize(path)
    @fifo_path = path
    @fifo = nil

    if !File::exists?(@fifo_path)
      # XXX: Should this check for errors or just fail?
      File::mkfifo(@fifo_path)
    end

    # FIXME: Is this atexit call really the best?
    at_exit do
      STDERR.puts "Terminating..."
      File::unlink(@fifo_path)
    end
  end

  def reserve
    if @fifo.nil?
      @fifo = File::open(@fifo_path, File::RDONLY | File::NONBLOCK)
    end

    return @fifo
  end

  def release
    @fifo.close
    @fifo = nil
  end
end

def main
  config = MaulConfig.new
  timeoutq = TimeoutPrioQueue.new
  fifo = MaulFifo.new config.fifo_path

  trees = {}
  trees.default_proc = proc { |d, k| d[k] = FileTree.new(config, k) }

  leave = false
  while !leave do
    timeout = timeoutq.seconds_to_next
    STDERR.puts "Going with timeout of %s" % [timeout || "INFINITE"]
    rs, = File::select([fifo.reserve], nil, nil, timeout)

    if rs == nil
      for elem in timeoutq.pop_before Time.now do
        if elem.needs_commit?
          elem.ft.commit!
          STDERR.puts "COMMITED FILE ON TIMEOUT: %s" % [elem.ft]
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
          leave = true
        when "commit"
          trees[tree].commit!
          STDERR.puts "COMMITED FILE ON COMMAND!"
        when "timeout"
          # XXX: Resetting timeout does not affect existing expiration.
          trees[tree].timeout = payload.to_i
        when "log"
          payload = payload.gsub(/\\n/, "\n")
          trees[tree].grab_file(timeoutq) do |ft_file|
            ft_file.write payload
            ft_file.flush
          end
        end
      end

      fifo.release
    end
  end
end

if __FILE__ == $0
  main()
end
