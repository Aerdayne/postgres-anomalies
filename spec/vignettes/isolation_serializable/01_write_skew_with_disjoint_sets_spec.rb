RSpec.describe 'Write skews with disjoint sets versus serializable isolation level' do
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
      transaction(isolation: :serializable) do
        seat_count = log Booking.where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)

        yield_control

        if seat_count == 2
          Booking.where(customer_name: 'Alice', event_id: 'event_a').update_all(seat_count: 2)
        end
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction(isolation: :serializable) do
        seat_count = log Booking.where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)

        yield_control

        if seat_count == 2
          Booking.where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    A write skew anomaly with disjoint write sets is avoided;
    transactions with serializable isolation level detect the dependency between
    reading the sum of booked seats and updating separate bookings
  DESC
    # Bob will encounter a serialization failure and retry the transaction
    start_in_order_and_conduct(
      alice,
      [bob, { retry_on: [ActiveRecord::SerializationFailure] }]
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    alice_taken_seats = log Booking.where(customer_name: 'Alice', event_id: 'event_a').sum(:seat_count)
    expect(alice_taken_seats).to eq(2)

    # Bob does not update his booking since he sees that Alice has already
    # taken the extra seat after retrying his transaction.

    bob_taken_seats = log Booking.where(customer_name: 'Bob', event_id: 'event_a').sum(:seat_count)
    expect(bob_taken_seats).to eq(1)
  end
end
