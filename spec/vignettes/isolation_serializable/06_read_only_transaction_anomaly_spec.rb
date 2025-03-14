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
          synchronizer[:alice_update_committed]
        end
      end
    end
  end

  specify <<~DESC do
    A read-only transaction anomaly does not happen if there is no third observer transaction;
    normally, there are 2 possible logical outcomes in this scenario:
    Alice's transaction happens before Bob's - Alice's booking ends up having 2 seats and Bob's 0 seats;
    Bob's transaction happens before Alice's - both Alice's and Bob's bookings end up having 2 seats;
    as established, this scenario does not cause a serialization failure becomes the end result
    is consistent with of the possible serial orderings, even though the transactions happen concurrently
  DESC
    start_in_order_and_conduct(
      [bob, { execute_without_coordination: true }],
      [alice, { execute_without_coordination: true }]
    )

    # The final state is consistent with one of the possible serial orderings

    snapshot = log(buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count))
    expect(snapshot).to match_array(
      [
        ['Alice', 2],
        ['Bob', 2]
      ]
    )
  end
end
