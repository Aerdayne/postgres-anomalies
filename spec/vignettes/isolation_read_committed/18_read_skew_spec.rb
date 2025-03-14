RSpec.describe 'Read skew versus UPDATE SET WHERE IN (SELECT)' do
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
      transaction do
        Booking.where(customer_name: 'Bob', event_id: 'event_b').update_all('seat_count = seat_count - 1')
        Event.increment_counter(:available_seats, 'event_b', by: 1)

        synchronizer[:alice_update_started] = true
        wait_for(seconds: 2) # Wait for Bob's inner SELECT statement to finish and UPDATE to start waiting
      end
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        wait_until { synchronizer[:alice_update_started] }

        # ActiveRecord does not seem to support specifying a RETURNING clause in an UPDATE statement,
        # therefore raw SQL is used.
        #
        # The SELECT statement is executed first before Alice's transaction commits.
        # Once it is evaluated, the outer UPDATE statement start being blocked by Alice's transaction.
        #
        # Once Alice's transaction commits, the UPDATE statement is executed and the WHERE
        # condition is re-checked, but the SELECT statement is not re-evaluated.
        # Since no rows were deleted, the result of the re-check is the same as before,
        # since the IDs of previously fetched bookings still exist and remain the same.
        #
        # This makes the UPDATE statement proceed by fetching the latest version of both his bookings,
        # whose seat counts are then decremented by 1.
        #
        # Since Bob first sees the original state of his bookings in the SELECT statement, and implicitly
        # sees latest versions of these bookings re-fetched by the UPDATE statement in order to avoid a
        # lost update anomaly with an atomic decrement, this makes it a read skew anomaly.
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
    The situation is now more complicated: Bob and Alice go to 2 events together;
    Bob booked 2 seats for himself and Alice for each of the events A and B,
    while Alice has already made a separate 1 seat booking for herself for each event;
    Alice tries to fix their bookings for event A by attempting to reduce Bob's booking by 1 seat, while
    Bob decides to fix their bookings for both events using UPDATE SET WHERE with a nested SELECT statement;
    his SELECT statement reads data as it was before Alice's transaction committed,
    but his UPDATE statement executes after the selected data becomes stale;
    as a result, Bob is left without a seat for event A;
    this happens despite the fact that both UPDATE and SELECT are part of the same SQL command
    because they use different snapshots
  DESC
    event_b_initially_available_seats = log Event.where(id: 'event_b').pluck(:available_seats).first
    expect(event_b_initially_available_seats).to eq(4)

    start_in_order_and_conduct(
      [alice, { execute_without_coordination: true }],
      [bob, { execute_without_coordination: true }]
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # 2 seats are returned, which is incorrect from Bob's perspective,
    # who is now left without a seat.
    event_b_available_seats = log Event.where(id: 'event_b').pluck(:available_seats).first
    expect(event_b_available_seats).to eq(6)

    event_b_taken_seats = log Booking.where(event_id: 'event_b').sum(:seat_count)
    expect(event_b_taken_seats).to eq(1)
  end
end
