# frozen_string_literal: true

module Shortcuts
  def execute(...)
    ActiveRecord::Base.connection.execute(...)
  end

  def transaction(begin_immediately: true, **options, &block)
    ActiveRecord::Base.transaction(**{ isolation: :read_committed }.merge(options)) do
      # Rails does not execute BEGIN immediately after transaction block
      # starts - it waits until the first query is executed instead.
      # The order of BEGIN statements may matter in some scenarios, therefore
      # we execute a dummy query to force Rails to start the transaction immediately.
      # SELECT 1 queries are filtered out from logs in the custom subscriber.
      ActiveRecord::Base.connection.execute('SELECT 1;') if begin_immediately
      block.call
    end
  end

  def define_schema(&block)
    ActiveRecord::Schema.define(&block)
  end
end
