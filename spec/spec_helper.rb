ENV['RACK_ENV'] = ENV['APP_ENV'] = ENV['RAILS_ENV'] = 'test'

require_relative '../config/app'

App.finalize!

Dir[App.root.join('spec/support/**/*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.mock_with :rspec do |mocks|
    mocks.verify_doubled_constant_names = true
    mocks.verify_partial_doubles = true
  end

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.define_derived_metadata do |meta|
    meta[:aggregate_failures] = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
end

RSpec::Matchers.define_negated_matcher :not_change, :change
