# frozen_string_literal: true

class Booking < ApplicationRecord
  belongs_to :event
end
