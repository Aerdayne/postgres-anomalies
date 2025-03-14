RSpec.describe 'Lost update versus repeatable read isolation level' do
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
    Lost update anomaly is avoided with a repeatable read isolation level;
    Alice starts a repeatable read transaction which detects
    the fact that the event was updated concurrently;
    a serialization failure is raised instead of Bob's update being lost
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(2)

    start_in_order_and_conduct(bob, alice)

    expect(outcome(bob)).to eq(:success)
    expect(outcome(alice)).to be_a(ActiveRecord::SerializationFailure)

    # Only one seat ends up being booked

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(1)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(1)
  end
end
