RSpec.describe 'Lost update versus a database-level constraint' do
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
    Event.create!(id: 'event_a', available_seats: 1)
  end

  let(:alice) do
    define('alice') do
      transaction do
        Event.decrement_counter(:available_seats, 'event_a', by: 1)

        Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')

        yield_control

        Event.decrement_counter(:available_seats, 'event_a', by: 1)
      end
    end
  end

  specify <<-DESC.lstrip do
    Lost update is avoided since events.available_seats is decremented in a single statement,
    and the database level constraint prevents events.available_seats from dropping below zero
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(1)

    start_in_order_and_conduct(bob, alice)

    expect(outcome(bob)).to be_a(ActiveRecord::StatementInvalid)
    expect(outcome(bob).message).to match(/violates check constraint "events_available_seats_check"/)
    expect(outcome(alice)).to eq(:success)

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(0)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(1)
  end
end
