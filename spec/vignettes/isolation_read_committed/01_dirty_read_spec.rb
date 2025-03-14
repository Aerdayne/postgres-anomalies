RSpec.describe 'Dirty read' do
  around do |example|
    execute <<~SQL
      CREATE TABLE bookings (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        customer_name text NOT NULL,
        seat_count integer NOT NULL,
        PRIMARY KEY (id)
      );
    SQL

    example.run
  ensure
    execute 'DROP TABLE IF EXISTS bookings;'
  end

  let(:alice) do
    define('alice') do
      transaction do
        Booking.create!(customer_name: 'Alice', seat_count: 1)

        yield_control
      end
    end
  end

  let(:bob) do
    define('bob') do
      transaction do
        Booking.create!(customer_name: 'Bob', seat_count: 1)

        yield_control

        buffer(
          :own_changes,
          Booking.where(customer_name: 'Bob').pluck(:customer_name)
        )
        buffer(
          :uncommitted_changes,
          Booking.where(customer_name: 'Alice').pluck(:customer_name)
        )
      end
    end
  end

  specify <<-DESC.lstrip do
    Bob does not encounter a dirty read;
    he does not see Alice's uncommitted changes
  DESC
    start_in_order_and_conduct(bob, alice)

    expect(buffer[:own_changes]).to match_array(['Bob'])
    expect(buffer[:uncommitted_changes]).to be_empty

    committed_bookings = log(Booking.pluck(:customer_name))
    expect(committed_bookings).to match_array(%w[Alice Bob])
  end
end
