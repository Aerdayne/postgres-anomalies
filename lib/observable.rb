# frozen_string_literal: true

module Observable
  def log(result)
    result.tap do
      logger.info("=> #{result}")
    end
  end

  def buffer(key = nil, result = nil, log = true)
    if key.nil?
      App[:buffer]
    else
      log(result) if log
      App[:buffer][key] = result
    end
  end

  def logger
    App[:logger]
  end
end
