# frozen_string_literal: true

App.register_provider(:buffer) do
  prepare do
    register(:buffer, SharedBuffer.new)
    register(:synchronizer, SharedBuffer.new)
  end
end
