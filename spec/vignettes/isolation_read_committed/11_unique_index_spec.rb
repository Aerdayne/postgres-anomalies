RSpec.describe 'Unique index' do
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

    execute <<~SQL
      CREATE UNIQUE INDEX index_bookings_one_per_customer ON bookings (customer_name, event_id)
    SQL

    example.run
  ensure
    execute 'DROP TABLE IF EXISTS bookings;'
    execute 'DROP TABLE IF EXISTS events;'
    execute 'DROP INDEX IF EXISTS index_bookings_one_per_customer;'
  end

  before do
    Event.create!(id: 'event_a', available_seats: 4)
  end

  let(:bob_session_a) do
    define('bob_session_a') do
      transaction do
        synchronizer[:session_a_started] = true
        wait_until do
          synchronizer[:session_b_started]
        end

        Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')
        Event.decrement_counter(:available_seats, 'event_a', by: 1)

        # Let session B wait for a bit
        wait_for(seconds: 2)
      end
    end
  end

  let(:bob_session_b) do
    define('bob_session_b') do
      transaction do
        synchronizer[:session_b_started] = true
        wait_until do
          synchronizer[:session_a_started]
        end

        # Let session A create a booking first
        wait_for(seconds: 0.5)

        result = Booking.upsert(
          { customer_name: 'Bob', seat_count: 2, event_id: 'event_a' },
          on_duplicate: Arel.sql('"seat_count" = "bookings"."seat_count" + 1'),
          unique_by: :index_bookings_one_per_customer,
          returning: Arel.sql("CASE WHEN xmax != 0 THEN 'updated' ELSE 'inserted' END AS status;")
        ).to_a.first

        case result['status']
        in 'inserted'
          Event.decrement_counter(:available_seats, 'event_a', by: 2)
        in 'updated'
          Event.decrement_counter(:available_seats, 'event_a', by: 1)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    Bob books one seat in session A, but then immediately remembers that he wants to book two seats;
    once he remembers that, he starts session B, but he's not sure if session A has committed yet;
    he wants to avoid creating 2 separate bookings, but he also wants to avoid restarting session B
    if session A has already committed;
    using an INSERT ON CONFLICT DO UPDATE statement with a unique index, he resolves
    the concurrent INSERT from session A and UPDATE from session B while preserving the invariant
    and avoiding a potential write skew, which would have failed with a unique index violation,
    and a potential lost update, which could have happened if there was a second concurrent session
    similar to session B
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(4)

    start_in_order_and_conduct(
      [bob_session_a, { execute_without_coordination: true }],
      [bob_session_b, { execute_without_coordination: true }]
    )

    expect(outcomes(bob_session_a, bob_session_b)).to match_array(%i[success success])

    booking_count = log Booking.where(customer_name: 'Bob').count
    expect(booking_count).to eq(1)

    # 2 seats should have been booked in total
    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(2)

    # The same booking should have been updated to have 2 seats
    seat_count = log Booking.where(customer_name: 'Bob').first.seat_count
    expect(seat_count).to eq(2)
  end
end
