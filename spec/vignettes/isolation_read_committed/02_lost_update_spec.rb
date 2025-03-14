RSpec.describe 'Lost update' do
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
        available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first

        yield_control

        Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
        Event.where(id: 'event_a').update_all(available_seats: available_seats - 1)
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first

        yield_control

        Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')
        Event.where(id: 'event_a').update_all(available_seats: available_seats - 1)
      end

      yield_control
    end
  end

  specify <<-DESC.lstrip do
    Bob encounters a lost update anomaly:
    both he and Alice start transactions and see the same amount of seats available;
    Bob commits first, at which point available_seats is decremented by 1;
    Alice then commits, setting the available_seats to 1 as well since her value is based on stale data;
    Bob's update is lost since it is overwritten by Alice's;
    2 seats end up being booked, while event's available seat capacity becomes 1, even though it should be 0
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(2)

    start_in_order_and_conduct(bob, alice)

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(1)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(2)
  end
end
