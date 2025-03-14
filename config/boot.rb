# frozen_string_literal: true

ENV['APP_ENV'] ||= 'development'

require 'bundler'
Bundler.setup

require 'dotenv/load'

require 'dry/configurable'
require 'dry-types'
require 'dry/system'
require 'dry/system/provider_sources'
require 'zlib'

module Types
  include Dry.Types
end
