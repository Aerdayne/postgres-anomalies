RSpec.describe 'Write skews with disjoint sets' do
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
      transaction(isolation: :repeatable_read) do
        seat_count = log Booking.where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)

        yield_control

        if seat_count == 2
          Booking.where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    A write skew anomaly occurs with disjoint write sets;
    Alice and Bob are given 1 extra free seat - for the sake of the example, they do not need to
    adjust events.available_seats, they just need to update the seat_count of one of their bookings;
    in the end, the extra seat must be added to only one of their bookings;
    they update only their own bookings, which does not trigger the serialization anomaly at the
    repeatable read isolation level, since they are disjoint sets - i.e. both transactions
    do not update any common rows
  DESC
    start_in_order_and_conduct(alice, bob)

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # As a result, both Bob and Alice end up booking 1 extra seat each,
    # even though they were given only 1 in total.

    alice_taken_seats = log Booking.where(customer_name: 'Alice', event_id: 'event_a').sum(:seat_count)
    expect(alice_taken_seats).to eq(2)

    bob_taken_seats = log Booking.where(customer_name: 'Bob', event_id: 'event_a').sum(:seat_count)
    expect(bob_taken_seats).to eq(2)
  end
end
