module Helper
  def define(name, &block)
    klass = Class.new(Service::Base)
    klass.define_method(:call, &block)
    klass.set_temporary_name(name)
    klass
  end

  def start_in_order_and_conduct(*services)
    coordinator = Coordinator::Base.new
    synchronizer[:__coordinator] = coordinator
    coordinator.start_in_order(*services)
    coordinator.wait_for_completion
  ensure
    coordinator.threads.each(&:kill)
  end

  def start_in_order_and_conduct_asynchronously(*services)
    coordinator = Coordinator::Base.new
    synchronizer[:__coordinator] = coordinator
    coordinator.start_in_order(*services)
  end

  def wait_for_completion
    coordinator.wait_for_completion
  ensure
    coordinator.threads.each(&:kill)
  end

  def wait_for_timeout(timeout_seconds:)
    coordinator.wait_for_completion(timeout_expected: true, timeout_seconds:)
  ensure
    coordinator.threads.each(&:kill)
  end

  def outcome(service)
    coordinator.outcome(service)
  end

  def outcomes(*services)
    services.map { |service| coordinator.outcome(service) }
  end

  def coordinator
    synchronizer[:__coordinator]
  end

  def synchronizer
    App[:synchronizer]
  end

  def repeat(times: 1, &block)
    results = {}

    0.upto(times - 1) do |i|
      begin
        if i != (times - 1)
          App[:logger].silence { results[i] = block.call }
        else
          results[i] = block.call
        end
      ensure
        buffer.reset
        synchronizer.reset
      end
    end

    results
  end
end

RSpec.configure do |config|
  config.include Helper
  config.include Waitable
  config.include Observable
  config.include Shortcuts

  config.before do
    Booking.reset_column_information
    Event.reset_column_information

    buffer.reset
    synchronizer.reset
  end

  config.after do
    buffer.reset
    synchronizer.reset
  end

  config.around do |example|
    Thread.current.thread_variable_set(:name, 'observer')

    $START_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    absolute_file_path = example.metadata[:absolute_file_path]
    log_file_path = absolute_file_path.sub(/\.rb\z/, '.log')

    File.delete(log_file_path) if File.exist?(log_file_path)

    # Avoid the header line in the log file
    klass = Class.new(Logger::LogDevice) do
      def add_log_header(*); end
    end
    log_device = klass.new(log_file_path)
    logger.reopen(log_device)

    ActiveRecord::Base.clear_cache!

    example.run
  ensure
    Thread.current.thread_variable_set(:name, nil)
  end
end
