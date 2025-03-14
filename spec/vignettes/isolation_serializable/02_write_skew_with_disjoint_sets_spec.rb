RSpec.describe 'Write skews with disjoint sets versus different predicates' do
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
        id integer PRIMARY KEY,
        customer_name text NOT NULL,
        seat_count integer NOT NULL,
        event_id text NOT NULL,
        FOREIGN KEY (event_id) REFERENCES events (id)
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

      belongs_to :event
    end
    booking_klass.set_temporary_name('booking_with_int_pk')
    buffer[:booking_model] = booking_klass

    transaction do
      Event.create!(id: 'event_a', available_seats: 4)

      buffer[:booking_model].create!(id: 1, customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
      buffer[:booking_model].create!(id: 2, customer_name: 'Bob', seat_count: 1, event_id: 'event_a')
    end
  end

  let(:alice) do
    define('alice') do
      # Alice does not use `WHERE customer_name = 'Alice'` at all
      # and instead refers to rows by their primary key.
      transaction(isolation: :serializable) do
        seat_count = log buffer[:booking_model].where(id: [1, 2]).sum(:seat_count)

        yield_control

        if seat_count == 2
          buffer[:booking_model].where(id: 1).update_all(seat_count: 2)
        end
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      # Bob uses customer_name when referring to rows instead of primary keys.
      transaction(isolation: :serializable) do
        seat_count = log buffer[:booking_model].where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)

        yield_control

        if seat_count == 2
          buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
        end
      end
    end
  end

  specify <<-DESC.lstrip do
    A write skew anomaly with disjoint write sets is still avoided,
    despite the fact that Alice and Bob fetch rows in different ways
  DESC
    # Bob still gets a serialization failure
    start_in_order_and_conduct(
      alice,
      [bob, { retry_on: [ActiveRecord::SerializationFailure] }]
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    alice_taken_seats = log buffer[:booking_model].where(customer_name: 'Alice', event_id: 'event_a').sum(:seat_count)
    expect(alice_taken_seats).to eq(2)

    bob_taken_seats = log buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').sum(:seat_count)
    expect(bob_taken_seats).to eq(1)
  end
end
