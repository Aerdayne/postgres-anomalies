# frozen_string_literal: true

require_relative 'boot'

class App < Dry::System::Container
  use :env, inferrer: -> { ENV.fetch('APP_ENV').to_sym }
  use :zeitwerk, eager_load: true

  configure do |config|
    config.root = Pathname(Dir.getwd)

    config.component_dirs.add 'lib' do |dir|
      dir.auto_register = false
    end

    config.component_dirs.add 'app' do |dir|
      dir.namespaces.add 'models', const: nil
      dir.auto_register = false
    end
  end

  register(:inflector) { Dry::Inflector.new }
end
