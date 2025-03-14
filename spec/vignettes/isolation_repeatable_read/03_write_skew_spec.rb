RSpec.describe 'Write skew versus repeatable read isolation level' do
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
    Event.create!(id: 'event_a', available_seats: 2)
  end

  let(:alice) do
    define('alice') do
      transaction(isolation: :repeatable_read) do
        if Event.where(id: 'event_a').pluck(:available_seats).first > 1
          Event.decrement_counter(:available_seats, 'event_a', by: 1)

          Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
        end
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction(isolation: :repeatable_read) do
        if Event.where(id: 'event_a').pluck(:available_seats).first > 1
          Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')

          yield_control

          Event.decrement_counter(:available_seats, 'event_a', by: 1)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    Write skew anomaly is avoided if transactions update the same rows concurrently;
    one of the transactions will fail with a serialization failure and will have to be retried;
    when Bob retries, the condition is evaluated again and he does not create a booking
    the invariant is preserved in the end
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(2)

    # Bob should retry after encountering a serialization failure
    start_in_order_and_conduct(
      [bob, { retry_on: [ActiveRecord::SerializationFailure] }],
      alice
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # Bob ends up not booking a seat since Alice has already booked one

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(1)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(1)

    has_bob_booked = log Booking.where(customer_name: 'Bob').exists?
    expect(has_bob_booked).to eq(false)
  end
end
