RSpec.describe 'Write skew versus UPDATE SET WHERE' do
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
    Event.create!(id: 'event_a', available_seats: 2)
  end

  let(:alice) do
    define('alice') do
      transaction do
        wait_until do
          synchronizer[:bob_started]
        end

        # ActiveRecord does not seem to support specifying a RETURNING clause in an UPDATE statement,
        # therefore raw SQL is used.
        #
        # Technically, the RETURNING clause is not necessary in this particular example, as UPDATE
        # returns the amount of rows affected, which is enough to determine whether the update went through,
        # as there is only one row to update - this might not be the case in a more realistic scenario.
        updated_event = log execute(<<~SQL.lstrip).to_a
          UPDATE events SET available_seats = available_seats - 1 WHERE id = 'event_a' AND available_seats > 1 RETURNING id
        SQL

        synchronizer[:alice_decremented] = true

        raise ActiveRecord::Rollback if updated_event.first.nil?

        Booking.create!(customer_name: 'Alice', seat_count: 1, event_id: updated_event.first['id'])

        # Wait before committing the transaction to allow Bob to get blocked on his update
        wait_for(seconds: 1)
      end
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        synchronizer[:bob_started] = true

        wait_until do
          synchronizer[:alice_decremented]
        end

        # Bob's update starts after Alice has decremented available_seats, but before Alice has committed her transaction.
        # The update is blocked until Alice commits her transaction.
        #
        # After Bob gets unblocked, the WHERE condition is rechecked with an up-to-date booking version
        # and it no longer satisfies, as available_seats is now 1.
        updated_event = log execute(<<~SQL.lstrip).to_a
          UPDATE events SET available_seats = available_seats - 1 WHERE id = 'event_a' AND available_seats > 1 RETURNING id
        SQL

        raise ActiveRecord::Rollback if updated_event.first.nil?

        Booking.create!(customer_name: 'Bob', seat_count: 1, event_id: updated_event.first['id'])
      end
    end
  end

  specify <<-DESC.lstrip do
    Bob and Alice avoid a write skew: Alice ends up booking a seat, while Bob does not;
    they determine whether they want to go by checking if event's available_seats is greater than 1
    in a single statement, which decrements available_seats in case the check is successful;
    using the RETURNING clause, they check whether their conditional update went through before proceeding with booking,
    which makes them avoid the lost update anomaly and a situation in which they both book a seat concurrently
  DESC
    initially_available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(initially_available_seats).to eq(2)

    start_in_order_and_conduct(
      [alice, { execute_without_coordination: true }],
      [bob, { execute_without_coordination: true }]
    )

    expect(outcomes(bob, alice)).to match_array(%i[success success])

    available_seats = log Event.where(id: 'event_a').pluck(:available_seats).first
    expect(available_seats).to eq(1)

    taken_seats = log Booking.sum(:seat_count)
    expect(taken_seats).to eq(1)
  end
end
