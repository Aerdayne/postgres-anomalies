# frozen_string_literal: true

App.register_provider(:settings, from: :dry_system) do
  settings do
    setting :db_name, constructor: Types::Strict::String
    setting :db_user, constructor: Types::Strict::String
    setting :db_password, constructor: Types::Strict::String
    setting :db_host, constructor: Types::Strict::String
    setting :db_port, constructor: Types::Strict::String

    setting :log_to_stdout, constructor: Types::Params::Bool, default: false
    setting :log_level, constructor: Types::Params::Symbol, default: :info
    setting :log_thread_name, constructor: Types::Params::Bool, default: true
    setting :log_elapsed_time, constructor: Types::Params::Bool, default: true
    setting :log_severity, constructor: Types::Params::Bool, default: true
    setting :log_tab_offset, constructor: Types::Params::Bool, default: true
    setting :log_sql_runtime, constructor: Types::Params::Bool, default: true
  end
end
