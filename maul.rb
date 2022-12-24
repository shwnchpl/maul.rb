#!/usr/bin/env ruby

require 'fileutils'
require 'socket'
require 'time'

# FIXME: Replace this with something good.
class NaivePriorityQueue
  def initialize
    @elements = []
  end

  def <<(element)
    @elements << element
  end

  def pop
    last_element_index = @elements.size - 1
    @elements.sort_by! { |elem| elem.expiration }
    @elements.delete_at(last_element_index)
  end

  def peek
    if @elements.length > 0 then
      @elements.sort_by! { |elem| elem.expiration }
      return @elements[0]
    else
      return nil
    end
  end

  def length
    return @elements.length
  end
end

class FileTree
  attr_accessor :timeout, :file, :expiration

  def initialize(timeout)
    @timeout = timeout
  end

  def commit!
    puts "Committing file!"

    if !file.nil? then
      @file.close()
      @file = nil
    end

    @expiration = nil
  end
end

# FIXME: Read config file!
fifo_path = "/tmp/foo"
root_path = "/tmp/maul-tree"
default_timeout = 5
timeoutq = NaivePriorityQueue.new

if !File::exists?(fifo_path) then
  # FIXME: Check for errors!
  File::mkfifo(fifo_path)
end

leave = false
fifo = nil
trees = {}
while !leave
  # FIXME: Figure out if there is a better solution to this.
  # RDONLY has data available after first read. RDWR never
  # gets the data. The current workaround is to simply close
  # the fifo, which is okay, but a little weird.
  if fifo.nil? then
    fifo = File::open(fifo_path, File::RDONLY | File::NONBLOCK)
  end

  timeout = nil
  ft = timeoutq.peek
  if !ft.nil? then
    now = Time.now
    timeout = [(ft.expiration - now + 0.5).to_i, 0].max
  end

  puts "Going with timeout of %s" % [timeout || "INFINITE"]
  rs, = File::select([fifo], nil, nil, timeout)

  if rs == nil then
    while timeoutq.length > 0 do
      now = Time.now
      ft = timeoutq.peek
      if ft.expiration - now <= 0 then
        timeoutq.pop
        ft.commit!
        puts "COMMITED FILE: %s" % [ft]
      else
        break
      end
    end
  else
    leave = false
    rs[0].readlines.each do |line|
      split_line = line.split(':', 3)
      if split_line.length != 3 then
        next
      end

      command, tree, payload = split_line

      case command
      when "quit"
        leave = true
      when "commit"
        ft = trees[tree]
        if !ft.nil? then
          ft.commit!
        end
      when "timeout"
        # FIXME: Create tree here as well, and sync timeout to config
        # file. Currently it is necessary to have logged first to
        # update timeout, which is broken.

        # XXX: Resetting timeout does not affect existing expiration.
        ft = trees[tree]
        if !ft.nil? then
          ft.timeout = payload.to_i
        end
      when "log"
        if trees[tree].nil? then
          trees[tree] = FileTree.new(default_timeout)
        end

        ft = trees[tree]
        now = Time.now

        if ft.file.nil? then
          dir = File.join(root_path, tree, now.year.to_s, now.month.to_s)
          FileUtils.mkdir_p(dir)
          path = File.join(dir, now.iso8601.gsub(/:/, "") + ".txt")
          ft.file = File::open(path, "a+")
        end

        payload = payload.gsub(/\\n/, "\n")
        ft.file.write(payload)

        if ft.timeout == 0 then
          ft.commit!
        else
          # FIXME: Remove any existing entries in the timeout queue!
          # They are no longer relevant! Honestly, since there aren't
          # many trees, it probably just makes more sense to store
          # timeout times in the priority queue and then simply scan
          # each tree to see if it is expired.
          ft.expiration = now + ft.timeout
          timeoutq << ft
        end
      end
    end

    fifo.close()
    fifo = nil
  end
end

puts "Exiting!"
File::unlink(fifo_path)
