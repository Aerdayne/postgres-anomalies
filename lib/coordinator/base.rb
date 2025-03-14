# frozen_string_literal: true

module Coordinator
  class Base
    include Waitable
    include Observable

    attr_reader :threads

    def initialize
      @mutex = Mutex.new
      @cvar = ConditionVariable.new

      @threads = []
    end

    class << self
      def inherited(subclass)
        super

        subclass.prepend(
          Module.new do
            def call
              super

              @threads.each(&:kill)
            end
          end
        )
      end
    end

    def wait_for_completion(**kwargs)
      wait_until(
        **kwargs.merge(
          on_timeout: -> do
            @threads.each do |th|
              th.raise Waitable::TimeoutExceeded, 'Wait period has expired'
              sleep(0.2) if th.alive?
            end
          end
        )
      ) do
        @threads.none?(&:alive?)
      end
    end

    def start_in_order(*service_klasses)
      index = 0

      registered_service_klasses = Set.new

      service_klasses.map do |service_klass|
        kwargs = { mutex: @mutex, cvar: @cvar }

        if service_klass.is_a?(Array)
          service_klass, additional_kwargs = service_klass
          if additional_kwargs.delete(:execute_without_coordination)
            kwargs.delete(:mutex)
            kwargs.delete(:cvar)
          end
          kwargs.merge!(additional_kwargs)
        end

        raise "Service #{service_klass} already registered" if registered_service_klasses.include?(service_klass)

        registered_service_klasses << service_klass

        service = service_klass.new(**kwargs)

        index += 1

        cleanup_mutex = Mutex.new

        cleanup_mutex.synchronize do
          thread = Thread.new(
            cleanup_mutex,
            service_klass,
            service,
            index
          ) do |scoped_cleanup_mutex, scoped_service_klass, scoped_service, scoped_index|
            Thread.current.report_on_exception = false
            Thread.current.abort_on_exception = false
            Thread.current.thread_variable_set(:name, App[:inflector].demodulize(scoped_service_klass).downcase)
            Thread.current.thread_variable_set(:identifier, scoped_index)
            Thread.current.thread_variable_set(:service, scoped_service)

            scoped_service.call
          rescue StandardError => e
            scoped_cleanup_mutex.synchronize do
              Thread.current.thread_variable_set(:exception, e)

              App[:logger].info("-> raised #{e.class} #{e.message.strip}")

              @threads.each do |th|
                next if th == Thread.current

                th.thread_variable_get(:service).allowed_to_finish = true
                # Make sure to let the other thread finish in case it waits for this one
                th.thread_variable_get(:service).cvar&.signal
              end
            end

            raise e
          end

          @threads << thread
        end

        service.startup_mutex.synchronize do
          wait_until do
            service.startup_cvar.wait(service.startup_mutex, 0.05) || service.started_up
          end
        end
      end
    end

    def outcome(service_klass)
      @threads.each do |thread|
        next unless thread.thread_variable_get(:service).instance_of?(service_klass)

        return thread.thread_variable_get(:exception) if thread.thread_variable_get(:exception)

        case thread.status
        in 'aborting'
          return :aborted
        in 'sleep'
          return :sleeping
        in 'run'
          return :running
        in nil
          begin
            return thread.value
          rescue => e
            return e
          end
        in false
          return :success
        end
      end

      nil
    end
  end
end
