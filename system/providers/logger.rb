# frozen_string_literal: true

App.register_provider(:logger) do
  prepare do
    require 'logger'

    $START_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    device =
      if target[:settings].log_to_stdout
        $stdout
      else
        "log/#{DateTime.now.strftime('%Y-%m-%d-%H-%M-%S')}.log"
      end

    logger = Logger.new(device)
    logger.level = target[:settings].log_level
    logger.formatter = proc do |severity, _datetime, _progname, msg|
      thread_identifier = Thread.current.thread_variable_get(:identifier)
      thread_name = Thread.current.thread_variable_get(:name) || 'unknown'
      prefix = ''

      if target[:settings].log_thread_name
        prefix = "[#{thread_name}]".rjust(14)
      end

      if target[:settings].log_tab_offset
        prefix <<
          if thread_identifier.is_a?(Integer) && thread_identifier.positive?
            "\t" * (thread_identifier + 1)
          else
            "\t"
          end
      end

      if target[:settings].log_elapsed_time
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - ($START_TIME || 0)).truncate(4).to_s
        elapsed = elapsed.ljust(8)
        prefix = "#{elapsed} #{prefix}"
      end

      if target[:settings].log_severity
        severity = "[#{severity}]".ljust(8)
        prefix = "#{severity}#{prefix}"
      end

      "#{prefix}#{msg}\n"
    end

    logger.define_singleton_method(:silence) do |&block|
      original_level = level
      self.level = Logger::FATAL
      block.call
    ensure
      self.level = original_level
    end

    register(:logger, logger)
    register(:is_logger_stdout, device == $stdout)
  end
end
