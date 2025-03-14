RSpec.describe 'Optimistic locking' do
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
        lock_version integer NOT NULL DEFAULT 0,
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
    booking_klass = Class.new(ActiveRecord::Base) do
      self.table_name = 'bookings'
      self.locking_column = :lock_version

      belongs_to :event
    end
    booking_klass.set_temporary_name('event_with_optimistic_locking')
    buffer[:booking_model] = booking_klass

    Event.create!(id: 'event_a', available_seats: 3)

    buffer[:booking_model].create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
  end

  let(:alice) do
    define('alice') do
      transaction do
        booking = buffer[:booking_model].select(:id, :seat_count, :lock_version).find_by!(customer_name: 'Alice')
        log [booking.seat_count, booking.lock_version]

        yield_control

        if booking.seat_count == 1
          Event.decrement_counter(:available_seats, 'event_a', by: 1)

          # Alice's update fails since the `update!` uses a stale lock version,
          # which was concurrently incremented by Bob's update.
          # Transaction is rolled back along with the event's available_seats decrement.
          booking.update!(seat_count: 2)
        end
      end
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        alice_booking = buffer[:booking_model].select(:id, :seat_count, :lock_version).find_by!(customer_name: 'Alice')
        log [alice_booking.seat_count, alice_booking.lock_version]

        yield_control

        if alice_booking.seat_count == 1
          Event.decrement_counter(:available_seats, 'event_a', by: 1)
          # Bob's update goes through, since lock version is still the same.
          # The check is made automatically by Rails, look into SQL logs to see it.
          alice_booking.update!(seat_count: 2)
        end
      end

      yield_control
    end
  end

  specify <<-DESC.lstrip do
    The booking system now allows multiple customers to control and edit shared bookings;
    Alice has made a booking for only one seat by mistake;
    she and Bob try to rectify this by concurrently updating the booking to have two seats;
    they both use optimistic locking to avoid lost updates and write skews
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(3)

    start_in_order_and_conduct(bob, alice)

    expect(outcome(bob)).to eq(:success)
    expect(outcome(alice)).to be_a(ActiveRecord::StaleObjectError)

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(2)

    taken_seats = log buffer[:booking_model].sum(:seat_count)
    expect(taken_seats).to eq(2)
  end
end
