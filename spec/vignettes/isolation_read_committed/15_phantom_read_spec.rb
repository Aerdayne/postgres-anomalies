RSpec.describe 'Phantom read' do
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
  end

  let(:alice) do
    define('alice') do
      Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        buffer(
          :first_booking_reading,
          Booking.where(customer_name: 'Alice').pluck(:seat_count)
        )

        yield_control

        buffer(
          :second_booking_reading,
          Booking.where(customer_name: 'Alice').pluck(:seat_count)
        )
      end
    end
  end

  specify <<-DESC.lstrip do
    Bob encounters a phantom read anomaly;
    his first SELECT query returns only the initial booking, but his second query
    returns both the initial and an entirely new booking which Alice has just committed
  DESC
    start_in_order_and_conduct(bob, alice)

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    expect(buffer[:first_booking_reading]).to eq([1])
    expect(buffer[:second_booking_reading]).to eq([1, 1])
  end
end
