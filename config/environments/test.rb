require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :none
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
  config.i18n.raise_on_missing_translations = true

  # rails/test_help calls maintain_test_schema!, which connects and compares the
  # schema. There is no schema file here and no connection before a passphrase,
  # so that check has to be off: the tests create a real vault themselves.
  config.active_record.maintain_test_schema = false
end
