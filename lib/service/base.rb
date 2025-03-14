# frozen_string_literal: true

module Service
  class Base
    include Waitable
    include Observable
    include Shortcuts

    class << self
      def inherited(subclass)
        super

        subclass.prepend(Mixins::Coordinatable)
        subclass.prepend(Mixins::Retryable)
      end
    end

    attr_reader :retry_on

    def initialize(retry_on: [])
      @retry_on = *retry_on
    end
  end
end
