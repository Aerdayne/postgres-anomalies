RSpec.describe 'Explicit locking' do
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
    Event.create!(id: 'event_a', available_seats: 4)
  end

  let(:alice) do
    define('alice') do
      transaction do
        synchronizer[:alice_started] = true
        wait_until do
          synchronizer[:bob_started]
        end

        # Alice locks the event to prevent write skew
        Event.lock.where(id: 'event_a').to_a

        # Since there are now more available seats, Alice can't use the previous check
        # She needs to explicitly find a booking that Bob might have created
        bob_bookings = log Booking.where(customer_name: 'Bob').pluck(:id)
        raise ActiveRecord::Rollback unless bob_bookings.empty?

        Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: 'event_a')
        # Whilst otherwise susceptible to lost updates, SELECTing before doing an UPDATE can
        # be safe if wrapped in the same explicit lock by all participating transactions.
        original_available_seats = Event.where(id: 'event_a').pluck(:available_seats).first
        Event.where(id: 'event_a').update_all(available_seats: original_available_seats - 1)

        # Let Bob wait for a bit
        wait_for(seconds: 2)
      end
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        synchronizer[:bob_started] = true
        wait_until do
          synchronizer[:alice_started]
        end

        # Let Alice lock the event first
        wait_for(seconds: 0.5)

        # Bob waits until Alice has committed her transaction before checking if he should book a seat
        Event.lock.where(id: 'event_a').to_a

        alice_bookings = log Booking.where(customer_name: 'Alice').pluck(:id)
        raise ActiveRecord::Rollback unless alice_bookings.empty?

        Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: 'event_a')
        # Whilst otherwise susceptible to lost updates, SELECTing before doing an UPDATE can
        # be safe if wrapped in the same explicit lock by all participating transactions.
        original_available_seats = Event.where(id: 'event_a').pluck(:available_seats).first
        Event.where(id: 'event_a').update_all(available_seats: original_available_seats - 1)
      end
    end
  end

  specify <<-DESC.lstrip do
    It is now possible for more than 2 people to go to the event;
    this makes the previous 'events.available_seats > 1' check insufficient;
    write skew is avoided since both Alice and Bob obtain an exclusive lock on the event;
    they do that before checking if they should book a seat,
    which guarantees that the other person will not book a seat concurrently
    as long as the other person also tries to lock the event before creating a booking
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(4)

    start_in_order_and_conduct(
      [alice, { execute_without_coordination: true }],
      [bob, { execute_without_coordination: true }]
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(3)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(1)
  end
end
