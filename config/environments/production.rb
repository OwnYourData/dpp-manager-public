require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  # Propshaft serves the precompiled assets: there is no separate web server in
  # front of this, it runs as one process on the operator's own machine.
  config.public_file_server.enabled = true

  # Plain HTTP on purpose. This listens on the loopback interface of the
  # operator's own computer; a self-signed certificate there would buy nothing
  # and cost every user a browser warning. Nothing leaves the machine except the
  # calls the application makes outward to the DPP Service, which are HTTPS.
  config.force_ssl = false
  config.assume_ssl = false

  config.log_tags = [ :request_id ]
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.log_formatter = Logger::Formatter.new

  config.cache_store = :memory_store

  config.active_support.report_deprecations = false
  config.i18n.fallbacks = true

  config.active_record.dump_schema_after_migration = false
  config.active_record.maintain_test_schema = false
end
