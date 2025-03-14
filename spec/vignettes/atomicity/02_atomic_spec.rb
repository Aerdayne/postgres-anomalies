RSpec.describe 'Atomic operation' do
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
        raise StandardError

        Booking.create!(customer_name: 'Bob', seat_count: 1)
      end
    end
  end

  specify <<-DESC.lstrip do
    Alice's update is atomic;
    neither booking is committed
  DESC
    start_in_order_and_conduct(alice)

    expect(outcome(alice)).to be_a(StandardError)
    expect(log(Booking.pluck(:customer_name))).to match_array([])
  end
end
