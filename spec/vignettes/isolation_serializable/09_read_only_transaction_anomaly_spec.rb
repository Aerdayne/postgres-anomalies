RSpec.describe 'Not a read-only transaction anomaly' do
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

  let(:bob) do
    define('bob') do
      wait_until do
        synchronizer[:alice_update_staged]
      end

      transaction(isolation: :serializable) do
        seat_count = log buffer[:booking_model].where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)
        if seat_count == 2
          buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
        else
          buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 0)
        end
      end

      synchronizer[:bob_update_committed] = true
    end
  end

  let(:alice) do
    define('alice') do
      transaction(isolation: :serializable) do
        buffer[:booking_model].where(id: 1).update_all(seat_count: 2)

        synchronizer[:alice_update_staged] = true

        wait_until do
          synchronizer[:observer_read_about_to_start]
        end

        # Let the observer transaction wait
        wait_for(seconds: 2)
      end
    end
  end

  specify <<~DESC do
    A read-only transaction anomaly does not occur because there is no anomaly to begin with;
    this time Bob's transaction also logically happens before Alice's transaction, but it commits first;
    as a result, the observer sees the result of Bob's transaction, but not Alice's - which is correct,
    because Alice's transaction logically happens after Bob's transaction;
    the state the observer sees is consistent with the order of transactions - it is interleaved between
    Bob's and Alice's transactions
  DESC
    start_in_order_and_conduct_asynchronously(
      [bob, { execute_without_coordination: true }],
      [alice, { execute_without_coordination: true }]
    )

    wait_until do
      synchronizer[:bob_update_committed]
    end

    transaction(isolation: :serializable, begin_immediately: false) do
      synchronizer[:observer_read_about_to_start] = true

      # The observer sees the intermediate consistent state in which Bob's transaction has committed,
      # but Alice's transaction has not.

      snapshot = log buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count)
      expect(snapshot).to match_array(
        [
          ['Alice', 1],
          ['Bob', 2]
        ]
      )
    end

    wait_for_completion

    # Alice's transaction has committed by now, which logically happens after Bob's and observer's transactions.
    # There is no read-only transaction anomaly.

    snapshot = log(buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count))
    expect(snapshot).to match_array(
      [
        ['Alice', 2],
        ['Bob', 2]
      ]
    )
  end
end
