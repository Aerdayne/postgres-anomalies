RSpec.describe 'Read skew' do
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
        Booking.where(customer_name: 'Bob').update_all(seat_count: 1)
      end

      yield_control
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        alice_seat_count = buffer(
          :first_seat_count_reading,
          Booking.where(customer_name: 'Alice').pluck(:seat_count)
        ).first

        yield_control

        bob_seat_count = buffer(
          :second_seat_count_reading,
          Booking.where(customer_name: 'Bob').pluck(:seat_count)
        ).first

        buffer(:total_seat_count, alice_seat_count + bob_seat_count)
      end
    end
  end

  specify <<-DESC.lstrip do
    Bob encounters a read skew anomaly;
    he sees Alice's booking as it was before her transaction committed
    and his own booking as it was after her transaction committed;
    the total seat count he calculates is 2, which is inconsistent
  DESC
    start_in_order_and_conduct(bob, alice)

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    expect(buffer[:first_seat_count_reading]).to eq([1])
    expect(buffer[:second_seat_count_reading]).to eq([1])
    expect(buffer[:total_seat_count]).to eq(2)

    final_seat_amount = log Booking.sum(:seat_count)
    expect(final_seat_amount).to eq(3)
  end
end
