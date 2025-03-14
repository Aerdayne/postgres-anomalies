RSpec.describe 'Read skew versus a non-volatile function' do
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
    Event.create!(id: 'event_a', available_seats: 3)

    Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
    Booking.create!(customer_name: 'Bob', seat_count: 2, event_id: 'event_a')
  end

  let(:alice) do
    define('alice') do
      transaction do
        Booking.where(customer_name: 'Alice').update_all(seat_count: 2)

        yield_control

        Booking.where(customer_name: 'Bob').update_all(seat_count: 1)
      end
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        yield_control

        buffer(
          :bob_sum,
          Booking.where(customer_name: %w[Alice Bob]).sum(:seat_count)
        )
      end

      yield_control
    end
  end

  specify <<-DESC.lstrip do
    Bob avoids a read skew anomaly by using a single SUM operator to calculate the seat count;
    this is possible in case a single statement uses a non-volatile function such as SUM,
    which is evaluated fully within the same snapshot
  DESC
    start_in_order_and_conduct(bob, alice)

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    expect(buffer[:bob_sum]).to eq(3)

    final_seat_amount = log Booking.sum(:seat_count)
    expect(final_seat_amount).to eq(3)
  end
end
