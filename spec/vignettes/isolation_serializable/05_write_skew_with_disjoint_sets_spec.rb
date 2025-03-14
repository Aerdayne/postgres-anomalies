RSpec.describe 'Write skews with disjoint sets versus a false positive serialization failure' do
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
        buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').update_all(seat_count: 2)
      end

      yield_control
    end
  end

  specify <<-DESC.lstrip do
    A write skew anomaly with disjoint write sets can be accidentally avoided;
    Bob uses the same predicate as Alice now, which makes her transaction raise a serialization failure;
    while this might seem like a correct result, even though desired, it is a false positive;
    as can be seen in the previous example, the final state is consistent with one of the serial orders;
    serializable isolation level can trigger such false positives, forcing one of the transactions
    to retry, even though they technically do not violate serializability
  DESC
    # Alice encounters a serialization failure and retries
    start_in_order_and_conduct(
      [alice, { retry_on: [ActiveRecord::SerializationFailure] }],
      bob
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    # The result is accidentally correct

    alice_taken_seats = log buffer[:booking_model].where(customer_name: 'Alice', event_id: 'event_a').sum(:seat_count)
    expect(alice_taken_seats).to eq(1)

    bob_taken_seats = log buffer[:booking_model].where(customer_name: 'Bob', event_id: 'event_a').sum(:seat_count)
    expect(bob_taken_seats).to eq(2)
  end
end
