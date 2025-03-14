# frozen_string_literal: true

App.register_provider(:active_record) do
  prepare do
    require 'active_record'
  end

  start do
    target.start(:logger)

    ActiveRecord::Base.establish_connection(
      adapter: 'postgresql',
      encoding: 'unicode',
      database: target[:settings].db_name,
      username: target[:settings].db_user,
      password: target[:settings].db_password,
      host: target[:settings].db_host,
      port: target[:settings].db_port,
      pool: 5,
      prepared_statements: false
    )

    # Disable the default log subscriber
    ActiveRecord::Base.logger = Logger.new(nil)

    if App.env == :development
      unless ActiveRecord::Base.connection.table_exists?(:events)
        ActiveRecord::Schema.define do
          create_table :events, id: :string do |t|
            t.integer :available_seats
          end
        end
      end

      unless ActiveRecord::Base.connection.table_exists?(:bookings)
        ActiveRecord::Schema.define do
          create_table :bookings, id: :uuid, default: 'gen_random_uuid()' do |t|
            t.string :customer_name
            t.integer :seat_count

            t.string :event_id
          end
        end
      end
    end

    ActiveRecord::Base.connection_handler.clear_active_connections!

    log_subscriber = Class.new(ActiveRecord::LogSubscriber) do
      def sql(event)
        payload = event.payload
        return if ['SCHEMA', 'EXPLAIN'].include?(payload[:name])

        sql_lines = payload[:sql].split("\n")
        line_count = sql_lines.size
        sql_lines.each_with_index do |sql_line, index|
          sql_lines = sql_line.squeeze(' ')
          next if sql_line.empty?
          next if sql_line == 'SELECT 1;'

          sql_line << "\t(#{event.duration.round(1)}ms)" if line_count - 1 == index && App[:settings].log_sql_runtime
          sql_line = color(sql_line, sql_color(sql_line), bold: true) if App[:is_logger_stdout]
          info(sql_line)
        end
      end
      subscribe_log_level :sql, :info

      def logger
        App[:logger]
      end
    end

    log_subscriber.attach_to(:active_record)
  end
end
