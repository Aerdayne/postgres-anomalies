# frozen_string_literal: true

module Service
  module Mixins
    module Retryable
      def call
        super
      rescue Exception => e
        raise unless retry_on.include?(e.class)

        App[:logger].info("-> raised #{e.class} #{e.message.strip}")
        @retrying = true
        retry
      end
    end
  end
end
