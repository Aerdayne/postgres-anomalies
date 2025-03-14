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
    A read-only transaction anomaly is prevented;
    the observer sees the intermediate state, just like with repeatable read isolation level,
    however in this case, the Bob's commit that follows fails and he's forced to restart his transaction;
    from the observer's perspective Alice has committed but Bob hasn't, even though logically Bob's
    transaction happens before Alice's in this case, which leads to the final state of Alice and
    Bob both having 2 seats;
    since the impossible state in which Alice's booking has 2 seats and Bob's has 1 seat was observed,
    the database makes it real - it forces Bob to restart his transaction, essentially re-ordering all
    transactions: after retrying, Bob's transaction logically happens after Alice's and after the
    observer's read, altering the final state of Alice having 2 seats and Bob having 0 seats;
    the observer ends up altering the initial order of transactions
  DESC
    start_in_order_and_conduct_asynchronously(
      [bob, { execute_without_coordination: true, retry_on: [ActiveRecord::SerializationFailure] }],
      [alice, { execute_without_coordination: true }]
    )

    wait_until do
      synchronizer[:alice_update_committed]
    end

    transaction(isolation: :serializable, begin_immediately: false) do
      synchronizer[:observer_read_about_to_start] = true

      # The observer sees the state that should be impossible, just like with repeatable read isolation level
      snapshot = log buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count)
      expect(snapshot).to match_array(
        [
          ['Alice', 2],
          ['Bob', 1]
        ]
      )
    end

    wait_for_completion

    # Bob's commit raises a serialization failure, forcing him to restart his transaction,
    # which re-orders all 3 transactions, making the final state different and the state that
    # the observer had seen consistent.

    snapshot = log(buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count))
    expect(snapshot).to match_array(
      [
        ['Alice', 2],
        ['Bob', 0]
      ]
    )
  end
end
