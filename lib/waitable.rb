# frozen_string_literal: true

module Waitable
  class TimeoutExceeded < StandardError; end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def wait_for(seconds:)
    sleep(seconds)
  end

  def wait_until(timeout_seconds: 5, timeout_expected: false, on_timeout: Proc.new {}, &block)
    started_at = now
    deadline = started_at + timeout_seconds

    condition_satisfied = false

    until condition_satisfied
      condition_satisfied = block.call

      remaining = deadline - now

      if remaining <= 0.05
        if timeout_expected
          on_timeout.call
          return nil
        else
          Thread.list.each do |thread|
            prefix = "Thread #{thread.native_thread_id} #{thread.name}"
            meta = "#{thread.thread_variable_get(:name)} #{thread.thread_variable_get(:index)}"
            App[:logger].warn("#{prefix} #{meta}")
            if thread.backtrace
              App[:logger].warn(thread.backtrace.join("\n"))
            else
              App[:logger].warn('<no backtrace>')
            end
          end

          on_timeout.call
          raise TimeoutExceeded, 'Wait period has expired'
        end
      end

      sleep(0.05)
    end

    condition_satisfied
  end
end
