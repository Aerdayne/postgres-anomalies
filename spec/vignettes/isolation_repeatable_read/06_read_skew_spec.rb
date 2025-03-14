RSpec.describe 'Read skew versus repeatable read isolation level' do
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
      Event.create!(id: 'event_a', available_seats: 3)

      Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
      Booking.create!(customer_name: 'Bob', seat_count: 2, event_id: 'event_a')

      Event.create!(id: 'event_b', available_seats: 4)

      Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_b')
      Booking.create!(customer_name: 'Bob', seat_count: 2, event_id: 'event_b')
    end
  end

  let(:alice) do
    define('alice') do
      transaction(isolation: :repeatable_read) do
        Booking.where(customer_name: 'Bob', event_id: 'event_b').update_all('seat_count = seat_count - 1')
        Event.increment_counter(:available_seats, 'event_b', by: 1)

        synchronizer[:alice_update_started] = true
        wait_for(seconds: 2) # Wait for Bob's inner SELECT statement to finish and UPDATE to start waiting
      end
    end
  end

  let(:bob) do
    define('bob') do
      transaction(isolation: :repeatable_read) do
        wait_until { synchronizer[:alice_update_started] }

        updated_bookings = log execute(<<~SQL.lstrip).to_a
          UPDATE bookings SET seat_count = seat_count - 1
          WHERE bookings.id IN (
            SELECT bookings.id
            FROM bookings
            WHERE bookings.customer_name = 'Bob'
            AND bookings.event_id IN (
              SELECT bookings.event_id
              FROM bookings
              WHERE bookings.customer_name IN ('Bob', 'Alice')
              GROUP BY bookings.event_id
              HAVING (SUM(seat_count) > 2)
            )
          )
          RETURNING id, event_id
        SQL

        updated_bookings.each do |booking|
          Event.increment_counter(:available_seats, booking['event_id'], by: 1)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    Read skew anomaly is avoided;
    serialization failure is raised for Bob since Alice commits her transaction first;
    on retry, Bob sees that Alice has already returned one of his seats and avoids
    accidentally returning his other seat;
    all reads in a repeatable read transaction see the same snapshot of the database;
    the UPDATE sees another snapshot since it has to re-fetch the latest version of the bookings;
    a repeatable read transaction detects this and raises a serialization failure instead of allowing
    the update to proceed
  DESC
    event_b_initially_available_seats = log Event.where(id: 'event_b').pluck(:available_seats).first
    expect(event_b_initially_available_seats).to eq(4)

    start_in_order_and_conduct(
      [alice, { execute_without_coordination: true }],
      [bob, { execute_without_coordination: true, retry_on: [ActiveRecord::SerializationFailure] }]
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # Only one of Bob's seats is returned by Alice.
    # Bob retries his transaction after encountering a serialization failure
    # and sees that Alice has already returned only one of his seats.

    event_b_available_seats = log Event.where(id: 'event_b').pluck(:available_seats).first
    expect(event_b_available_seats).to eq(5)

    event_b_taken_seats = log Booking.where(event_id: 'event_b').sum(:seat_count)
    expect(event_b_taken_seats).to eq(2)
  end
end
