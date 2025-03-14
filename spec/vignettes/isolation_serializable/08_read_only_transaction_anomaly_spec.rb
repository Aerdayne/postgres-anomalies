RSpec.describe 'Read-only transaction anomaly versus serializable isolation level' do
  around do |example|
    execute <<~SQL
      CREATE TABLE events (
        id text NOT NULL,
        available_seats integer NOT NULL CHECK (available_seats >= 0),
        PRIMARY KEY (id)
      );
    SQL

    execute <<~SQL
      CREATE TABLE bookings (
        id integer PRIMARY KEY,
        customer_name text NOT NULL,
        seat_count integer NOT NULL,
        event_id text NOT NULL,
        FOREIGN KEY (event_id) REFERENCES events (id)
      );
    SQL

    example.run
  ensure
    execute 'DROP TABLE IF EXISTS bookings;'
    execute 'DROP TABLE IF EXISTS events;'
  end

  before do
    booking_klass = Class.new(ActiveRecord::Base) do
      self.table_name = 'bookings'

      belongs_to :event
    end
    booking_klass.set_temporary_name('booking_with_int_pk')
    buffer[:booking_model] = booking_klass

    transaction do
      Event.create!(id: 'event_a', available_seats: 2)

      buffer[:booking_model].create!(id: 1, customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
      buffer[:booking_model].create!(id: 2, customer_name: 'Bob', seat_count: 1, event_id: 'event_a')
    end
  end

  let(:alice) do
    define('alice') do
      wait_until do
        synchronizer[:bob_update_staged]
      end

      transaction(isolation: :serializable) do
        buffer[:booking_model].where(id: 1).update_all(seat_count: 2)
      end

      synchronizer[:alice_update_committed] = true
    end
  end

  let(:bob) do
    define('bob') do
      transaction(isolation: :serializable) do
        seat_count = log buffer[:booking_model].where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)
        if seat_count == 2
          buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
        else
          buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 0)
        end

        synchronizer[:bob_update_staged] = true

        wait_until do
          synchronizer[:observer_read_about_to_start]
        end

        # Let the observer transaction wait
        wait_for(seconds: 2)
      end
    end
  end

  specify <<~DESC do
    A read-only transaction anomaly is prevented and serialization failure is avoided;
    it is possible to declare a transaction as READ ONLY and DEFERRABLE, which makes the transaction
    wait until it is safe for it to proceed, which avoids a serialization failure caused by its read;
    in this case, Bob does not have to retry and the order of transactions, as well as the final state,
    is not altered
  DESC
    start_in_order_and_conduct_asynchronously(
      [bob, { execute_without_coordination: true }],
      [alice, { execute_without_coordination: true }]
    )

    wait_until do
      synchronizer[:alice_update_committed]
    end

    # ActiveRecord does not seem to support specifying that a transaction should be read only and deferrable.
    execute('BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE;')
    synchronizer[:observer_read_about_to_start] = true

    # The observer sees a consistent final state, avoiding the read-only transaction anomaly
    # since it waits until both Alice and Bob commit.
    snapshot = log buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count)
    expect(snapshot).to match_array(
      [
        ['Alice', 2],
        ['Bob', 2]
      ]
    )
    execute('COMMIT;')

    wait_for_completion

    # The final state is consistent with the initial order of transactions

    snapshot = log(buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count))
    expect(snapshot).to match_array(
      [
        ['Alice', 2],
        ['Bob', 2]
      ]
    )
  end
end
