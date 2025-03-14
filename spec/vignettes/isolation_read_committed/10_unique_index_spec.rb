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
      CREATE UNIQUE INDEX index_bookings_one_per_customer ON bookings (customer_name, event_id);
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

        # Thi following INSERT is blocked until session A commits.
        # If A rolls back, then this INSERT succeeds - but not in this case.
        Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')

        Event.decrement_counter(:available_seats, 'event_a', by: 1)
      end
    end
  end

  specify <<-DESC.lstrip do
    Bob accidentally starts the process of booking a seat for an event twice;
    a unique index helps preserve the invariant that a customer can only book a seat for an event once;
    if there was no unique index and the decision was made based on a SELECT before the UPDATE,
    a write skew would have been possible
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(4)

    start_in_order_and_conduct(
      [bob_session_a, { execute_without_coordination: true }],
      [bob_session_b, { execute_without_coordination: true }]
    )

    expect(outcome(bob_session_a)).to eq(:success)
    # Session B fails with a unique index violation
    expect(outcome(bob_session_b)).to be_a(ActiveRecord::RecordNotUnique)

    # Only one booking had been created for Bob despite his 2 concurrent attempts to book a seat.
    booking_count = log Booking.where(customer_name: 'Bob').count
    expect(booking_count).to eq(1)
  end
end
