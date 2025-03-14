RSpec.describe 'Write skew' do
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
      transaction do
        # Alice does not want to go to the event if Bob is going
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
      transaction do
        # Bob does not want to go to the event if Alice is going
        if Event.where(id: 'event_a').pluck(:available_seats).first > 1
          Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')

          yield_control

          Event.decrement_counter(:available_seats, 'event_a', by: 1)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    Bob and Alice both don't want to go to the event if the other is going;
    they encounter a write skew anomaly since they make a decision based on data
    that becomes stale in case the other concurrent transaction commits first
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(2)

    start_in_order_and_conduct(bob, alice)

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # Alice and Bob both book a seat despite not wanting to go to the event

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(0)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(2)
  end
end
