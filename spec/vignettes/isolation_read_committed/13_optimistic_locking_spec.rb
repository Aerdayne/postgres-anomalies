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
      # Alice's transaction happens fully between Bob's 2 transactions
      transaction do
        booking = buffer[:booking_model].select(:id, :seat_count, :lock_version).find_by!(customer_name: 'Alice')

        if booking.seat_count == 1
          Event.decrement_counter(:available_seats, 'event_a', by: 1)
          booking.update!(seat_count: 2)
        end
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      # It is not necessary to wrap this single statement in a transaction explicitly - this
      # is done for consistency.
      alice_booking = transaction { buffer[:booking_model].find_by!(customer_name: 'Alice') }

      # Something happens between the transactions - Bob might take
      # some time to make a decision
      if alice_booking.seat_count == 1
        updated_attributes = {
          customer_name: 'Bob',
          seat_count: 2
        }

        yield_control

        transaction do
          Event.decrement_counter(:available_seats, 'event_a', by: 1)
          # Bob's update fails since the lock version is already updated at this point by Alice
          alice_booking.update!(updated_attributes)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    Optimistic locking works across transactions;
    in case conflicts are not expected to be common, this way of locking allows to avoid
    long running transactions and explicit locks being held for long periods of time
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(3)

    start_in_order_and_conduct(bob, alice)

    expect(outcome(bob)).to be_a(ActiveRecord::StaleObjectError)
    expect(outcome(alice)).to eq(:success)

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(2)

    taken_seats = log buffer[:booking_model].sum(:seat_count)
    expect(taken_seats).to eq(2)
  end
end
