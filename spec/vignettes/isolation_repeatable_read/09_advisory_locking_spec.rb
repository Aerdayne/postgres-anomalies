RSpec.describe 'Write skews with disjoint sets versus session advisory locks' do
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
      synchronizer[:alice_started] = true
      wait_until do
        synchronizer[:bob_started]
      end

      lock_key = Zlib.crc32('alice:bob')
      execute("SELECT pg_advisory_lock('#{lock_key}')")

      transaction(isolation: :repeatable_read) do
        seat_count = log Booking.where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)

        yield_control

        if seat_count == 2
          Booking.where(customer_name: 'Alice', event_id: 'event_a').update_all(seat_count: 2)
        end

        # Let Bob wait for a bit
        wait_for(seconds: 2)
      end

      execute("SELECT pg_advisory_unlock('#{lock_key}')")

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      synchronizer[:bob_started] = true
      wait_until do
        synchronizer[:alice_started]
      end

      # Let Alice lock first
      wait_for(seconds: 0.5)

      lock_key = Zlib.crc32('alice:bob')
      execute("SELECT pg_advisory_lock('#{lock_key}')")

      transaction(isolation: :repeatable_read) do
        seat_count = log Booking.where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)

        yield_control

        if seat_count == 2
          Booking.where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
        end
      end

      execute("SELECT pg_advisory_unlock('#{lock_key}')")
    end
  end

  specify <<-DESC.lstrip do
    A write skew anomaly is avoided by using session-level advisory locks;
    a session-level advisory lock is not attached to any particular transaction,
    therefore once Bob gets the lock, he starts a new transaction which gets a snapshot in which
    Alice has already committed, thus avoiding a write skew
  DESC
    start_in_order_and_conduct(
      [bob, { execute_without_coordination: true }],
      [alice, { execute_without_coordination: true }]
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # Alice ends up booking the extra seat, while bob correctly does not

    alice_taken_seats = log Booking.where(customer_name: 'Alice', event_id: 'event_a').sum(:seat_count)
    expect(alice_taken_seats).to eq(2)

    bob_taken_seats = log Booking.where(customer_name: 'Bob', event_id: 'event_a').sum(:seat_count)
    expect(bob_taken_seats).to eq(1)
  end
end
