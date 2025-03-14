RSpec.describe 'Write skews with disjoint sets versus transaction ordering' do
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
      transaction(isolation: :serializable) do
        seat_count = log buffer[:booking_model].where(customer_name: %w[Alice Bob], event_id: 'event_a').sum(:seat_count)
        yield_control

        if seat_count == 2
          buffer[:booking_model].where(customer_name: 'Alice', event_id: 'event_a').update_all(seat_count: 2)
        end
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction(isolation: :serializable) do
        buffer[:booking_model].where(id: 2).update_all(seat_count: 2)
      end

      yield_control
    end
  end

  specify <<-DESC.lstrip do
    A write skew anomaly with disjoint write sets is not avoided, because the final state is consistent
    with one possible serial order, in which Alice's transaction happens before Bob's;
    serializable isolation level only prevents situations where the final state is impossible
    to achieve with non-concurrent serial order of transactions;
    in this case, serializability is not violated as such order exists
  DESC
    start_in_order_and_conduct(alice, bob)

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # The final state is unfortunate, but correct. Bob does not coordinate, therefore it's possible
    # for Alice to run her transaction first before Bob, avoiding the check that Alice implements -
    # this is exactly what happens in this case.

    alice_taken_seats = log buffer[:booking_model].where(customer_name: 'Alice', event_id: 'event_a').sum(:seat_count)
    expect(alice_taken_seats).to eq(2)

    bob_taken_seats = log buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').sum(:seat_count)
    expect(bob_taken_seats).to eq(2)
  end
end
