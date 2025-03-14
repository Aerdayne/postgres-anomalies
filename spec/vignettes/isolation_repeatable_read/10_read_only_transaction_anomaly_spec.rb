RSpec.describe 'Read-only transaction anomaly' do
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

      # Alice executes her transaction after Bob has already made his decision,
      # but before he commits
      transaction(isolation: :repeatable_read) do
        buffer[:booking_model].where(id: 1).update_all(seat_count: 2)
      end

      synchronizer[:alice_update_committed] = true
    end
  end

  let(:bob) do
    define('bob') do
      transaction(isolation: :repeatable_read) do
        # Read the bookings data before Alice commits
        seat_count = log buffer[:booking_model].where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)
        # Since Alice has not committed yet, Bob makes a decision to update his own booking
        if seat_count == 2
          buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
        else
          buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 0)
        end

        synchronizer[:bob_update_staged] = true

        wait_until do
          synchronizer[:observer_read_about_to_start]
        end

        # Give the observer transaction a chance to wait
        # (it won't in the case of repeatable read)
        wait_for(seconds: 2)
      end
    end
  end

  specify <<~DESC do
    A read-only transaction anomaly occurs;
    Bob and Alice decide to use the gifted extra third seat for their friend;
    Alice decides to simply update her booking to 2 seats;
    Bob is more careful and first checks whether Alice has already updated her booking:
    if she has, he returns his own seat by updating his booking to have 0 seats;
    he sets it to 0 because due to miscommunication, he thinks that Alice will add 2 seats to her existing booking;
    if she has not updated her booking yet, he updates his own booking to have 2 seats,
    assuming that Alice will not do anything with her booking;
    the observer sees the result of Alice's transaction, but not Bob's,
    even though than logically Alice's transaction happens after Bob's,
    since otherwise Alice's booking would have 2 seats and Bob's would have 0 seats in the end;
    the actual end state is Alice having 2 seats and Bob having 2 seats;
    what the observer sees should not be possible - the observer sees an inconsistent state
  DESC
    start_in_order_and_conduct_asynchronously(
      [bob, { execute_without_coordination: true }],
      [alice, { execute_without_coordination: true }]
    )

    wait_until do
      synchronizer[:alice_update_committed]
    end

    # Start a transaction after Alice has committed, but before Bob has
    transaction(isolation: :repeatable_read, begin_immediately: false) do
      synchronizer[:observer_read_about_to_start] = true

      snapshot = log buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count)
      expect(snapshot).to match_array(
        [
          ['Alice', 2],
          ['Bob', 1]
        ]
      )
    end

    wait_for_completion

    # The end result is unfortunate, but it is correct, since Alice does not coordinate with Bob.
    # Both end up with 2 seats each, 4 in total, even though they needed only 3.

    snapshot = log(buffer[:booking_model].where(customer_name: %w[Alice Bob]).pluck(:customer_name, :seat_count))
    expect(snapshot).to match_array(
      [
        ['Alice', 2],
        ['Bob', 2]
      ]
    )
  end
end
