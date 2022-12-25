#!/usr/bin/env ruby

require 'fileutils'
require 'socket'
require 'time'

class TimeoutPrioQueue
  class Elem
    attr_reader :expiration, :ft

    def initialize(ft)
      @expiration = ft.expiration
      @ft = ft
    end

    def <=>(other)
      return @expiration <=> other
    end
  end

  def initialize
    @elements = []
  end

  def <<(ft)
    elem = Elem.new ft
    idx = @elements.bsearch_index { |e| e.expiration > elem } ||
      @elements.length
    @elements.insert(idx, elem)
  end

  def seconds_to_next
    if @elements.length > 0
      return [(@elements[0].expiration - Time.now + 0.5).to_i, 0].max
    else
      return nil
    end
  end

  def pop_before(t)
    idx = @elements.bsearch_index { |e| e.expiration > t } || @elements.length
    return @elements.slice!(0, idx)
  end
end

class FileTree
  attr_accessor :timeout, :file, :expiration

  def initialize(timeout)
    @timeout = timeout
  end

  def commit!
    if !file.nil?
      @file.close()
      @file = nil
    end

    @expiration = nil
  end
end

def main
  # FIXME: Read config file!
  fifo_path = "/tmp/foo"
  root_path = "/tmp/maul-tree"
  default_timeout = 5

  if !File::exists?(fifo_path)
    # FIXME: Check for errors!
    File::mkfifo(fifo_path)
  end

  at_exit do
    STDERR.puts "Terminating..."
    File::unlink(fifo_path)
  end

  timeoutq = TimeoutPrioQueue.new
  leave = false
  fifo = nil
  trees = {}

  while !leave do
    if fifo.nil?
      fifo = File::open(fifo_path, File::RDONLY | File::NONBLOCK)
    end

    timeout = timeoutq.seconds_to_next
    STDERR.puts "Going with timeout of %s" % [timeout || "INFINITE"]
    rs, = File::select([fifo], nil, nil, timeout)

    if rs == nil
      for elem in timeoutq.pop_before Time.now do
        if elem.expiration <= elem.ft.expiration
          elem.ft.commit!
          STDERR.puts "COMMITED FILE: %s" % [elem.ft]
        end
      end
    else
      leave = false
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
          ft = trees[tree]
          if !ft.nil?
            ft.commit!
          end
        when "timeout"
          # FIXME: Create tree here as well, and sync timeout to config
          # file. Currently it is necessary to have logged first to
          # update timeout, which is broken.

          # XXX: Resetting timeout does not affect existing expiration.
          ft = trees[tree]
          if !ft.nil?
            ft.timeout = payload.to_i
          end
        when "log"
          if trees[tree].nil?
            trees[tree] = FileTree.new default_timeout
          end

          ft = trees[tree]
          now = Time.now

          if ft.file.nil?
            dir = File.join(root_path, tree, now.year.to_s, now.month.to_s)
            FileUtils.mkdir_p(dir)
            path = File.join(dir, now.iso8601.gsub(/:/, "") + ".txt")
            ft.file = File::open(path, "a+")
          end

          payload = payload.gsub(/\\n/, "\n")
          ft.file.write payload
          ft.file.flush

          if ft.timeout == 0
            ft.commit!
          else
            ft.expiration = now + ft.timeout
            timeoutq << ft
          end
        end
      end

      fifo.close()
      fifo = nil
    end
  end
end

if __FILE__ == $0
  main()
end
