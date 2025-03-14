RSpec.describe 'Lost update versus an application-level constraint' do
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
    event_klass = Class.new(ActiveRecord::Base) do
      self.table_name = 'events'

      has_many :bookings
      validates :available_seats, numericality: { greater_than_or_equal_to: 0 }
    end
    event_klass.set_temporary_name('event_with_validation')
    buffer[:event_model] = event_klass

    event_klass.create!(id: 'event_a', available_seats: 1)
  end

  let(:alice) do
    define('alice') do
      transaction do
        event = buffer[:event_model].select(:available_seats).find_by!(id: 'event_a')
        if event.available_seats > 0
          event.update!(available_seats: event.available_seats - 1)
        end

        Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')

        event = buffer[:event_model].select(:available_seats).find_by!(id: 'event_a')
        if event.available_seats > 0
          yield_control
          # The update passes validation and goes through because the application
          # operates on a stale value of 0 which it read before Alice's transaction
          # had committed.
          event.update!(available_seats: event.available_seats - 1)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    Application-level validation makes a lost update possible since
    the decision to decrement the seat count is based on a stale value;
    events.available_seats can still go below zero
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(1)

    start_in_order_and_conduct(bob, alice)

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(1)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(2)
  end
end
