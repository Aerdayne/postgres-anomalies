# frozen_string_literal: true

class SharedBuffer
  attr_reader :data

  def initialize
    @mutex = Mutex.new

    @data = {}
  end

  def [](key)
    @mutex.synchronize do
      data[key] ||= []
      data[key].size > 1 ? data[key] : data[key].first
    end
  end

  def []=(key, value)
    @mutex.synchronize do
      data[key] ||= []
      data[key] << value
    end
  end

  def reset
    @mutex.synchronize do
      @data = {}
    end
  end

  def inspect
    data.inspect
  end

  def to_s
    data.inspect
  end
end
