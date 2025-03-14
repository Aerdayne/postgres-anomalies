# frozen_string_literal: true

module Service
  module Mixins
    module Coordinatable
      attr_reader :cvar, :startup_mutex, :startup_cvar, :started_up
      attr_writer :allowed_to_finish

      def initialize(*args, mutex: nil, cvar: nil, **kwargs)
        super(*args, **kwargs)

        @mutex = mutex
        @cvar = cvar

        @yield_stack = []
        @retrying = false
        @allowed_to_finish = false

        @startup_mutex = Mutex.new
        @startup_cvar = ConditionVariable.new
        @started_up = false
      end

      def call
        if @mutex.nil?
          synchronize_startup { super }
        else
          @mutex.synchronize do
            synchronize_startup { super }
          end
        end
      end

      private

      def synchronize_startup(&block)
        # Makes it possible to guarantee that a specific service
        # gets to enter the critical section first
        @startup_mutex.synchronize do
          @startup_cvar.signal
        end
        # Without this, the coordinator may miss the initial signal and wait for
        # the startup that has already happened forever
        @started_up = true

        block.call

        # The other thread won't exit its final `yield_control` unless the thread
        # that finishes first signals
        @cvar&.signal
      end

      def yield_control
        return if @mutex.nil? || @cvar.nil?

        return if @allowed_to_finish
        # When retrying, skip coordination points that were already passed
        return if @yield_stack.pop && @retrying

        @retrying = false
        @yield_stack << true

        start = now

        @cvar.signal
        @cvar.wait(@mutex)

        App[:logger].debug { "Waited for #{now - start} seconds" }
      end

      def synchronizer
        App[:synchronizer]
      end
    end
  end
end
