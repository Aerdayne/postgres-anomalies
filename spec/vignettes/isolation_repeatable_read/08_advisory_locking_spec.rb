RSpec.describe 'Write skews with disjoint sets versus transaction advisory locks' do
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
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        customer_name text NOT NULL,
        seat_count integer NOT NULL,
        event_id text NOT NULL,
        FOREIGN KEY (event_id) REFERENCES events (id),
        PRIMARY KEY (id)
      );
    SQL

    example.run
  ensure
    execute 'DROP TABLE IF EXISTS bookings;'
    execute 'DROP TABLE IF EXISTS events;'
  end

  before do
    transaction do
      Event.create!(id: 'event_a', available_seats: 4)

      Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
      Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')
    end
  end

  let(:alice) do
    define('alice') do
      transaction(isolation: :repeatable_read) do
        synchronizer[:alice_started] = true
        wait_until do
          synchronizer[:bob_started]
        end

        lock_key = Zlib.crc32('alice:bob')
        execute("SELECT pg_advisory_xact_lock('#{lock_key}')")

        seat_count = log Booking.where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)

        yield_control

        if seat_count == 2
          Booking.where(customer_name: 'Alice', event_id: 'event_a').update_all(seat_count: 2)
        end

        # Let Bob wait for a bit
        wait_for(seconds: 2)
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction(isolation: :repeatable_read) do
        synchronizer[:bob_started] = true
        wait_until do
          synchronizer[:alice_started]
        end

        # Let Alice lock first
        wait_for(seconds: 0.5)

        lock_key = Zlib.crc32('alice:bob')
        execute("SELECT pg_advisory_xact_lock('#{lock_key}')")

        seat_count = log Booking.where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)

        yield_control

        if seat_count == 2
          Booking.where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    A write skew anomaly is not avoided by using transaction-level advisory locks;
    an advisory lock is not bound to a particular row or a table,
    but the application is fully responsible for managing them;
    however, the application is fully responsible for managing them;
    a lock key is an integer, but arbitrary data can be mapped to it, e.g using a hash function;
    a transaction-level advisory lock does not work in this case, since the snapshot
    is locked the moment the first SELECT statement is issued, which is before Alice's transaction commits;
    after Bob gets the lock, he sees the old snapshot, and the anomaly occurs again
  DESC
    start_in_order_and_conduct(
      [bob, { execute_without_coordination: true }],
      [alice, { execute_without_coordination: true }]
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # Both end up booking the extra seat

    alice_taken_seats = log Booking.where(customer_name: 'Alice', event_id: 'event_a').sum(:seat_count)
    expect(alice_taken_seats).to eq(2)

    bob_taken_seats = log Booking.where(customer_name: 'Bob', event_id: 'event_a').sum(:seat_count)
    expect(bob_taken_seats).to eq(2)
  end
end
