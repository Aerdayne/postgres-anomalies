require 'database_cleaner/active_record'

RSpec.configure do |config|
  config.before(:suite) do
    App[:logger].silence do
      DatabaseCleaner[:active_record, db: ApplicationRecord].strategy = :truncation
      DatabaseCleaner[:active_record, db: ApplicationRecord].clean_with(:truncation)
    end
  end

  config.around do |example|
    if example.metadata[:skip_truncation]
      example.run
    else
      App[:logger].silence do
        DatabaseCleaner[:active_record, db: ApplicationRecord].start
      end

      example.run

      App[:logger].silence do
        DatabaseCleaner[:active_record, db: ApplicationRecord].clean
      end
    end
  end
end
