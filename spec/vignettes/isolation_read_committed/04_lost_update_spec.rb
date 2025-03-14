RSpec.describe 'Lost update versus UPDATE SET WHERE' do
  around do |example|
    execute <<~SQL
      CREATE TABLE events (
        id text NOT NULL,
        available_seats integer NOT NULL,
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
        # Alice's transaction gets blocked on this UPDATE
        Event.decrement_counter(:available_seats, 'event_a', by: 1)

        Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        Event.decrement_counter(:available_seats, 'event_a', by: 1)

        yield_control

        Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')
      end
    end
  end

  specify <<-DESC.lstrip do
    Concurrent UPDATE is blocked the moment it is initiated, not when the transaction commits;
    Alice's transaction gets blocked on UPDATE since it waits for Bob's transaction to commit
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(2)

    start_in_order_and_conduct_asynchronously(bob, alice)
    wait_for_timeout(timeout_seconds: 3)

    expect(outcome(alice)).to be_a(Waitable::TimeoutExceeded)

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(2)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(0)
  end
end
