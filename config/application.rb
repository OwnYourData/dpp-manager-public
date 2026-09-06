require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

# The oydid gem loads a multicodec table from a CSV that is not ASCII. With no
# locale set — which is the normal state of a container — Ruby's default
# external encoding is US-ASCII and the gem cannot even be required, several
# frames deep in a CSV parser. The Dockerfile sets LANG; this makes the
# application say so itself rather than depend on the environment being right.
Encoding.default_external = Encoding::UTF_8 if Encoding.default_external != Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8 if Encoding.default_internal.nil?

module DppManager
  VERSION = "0.1.0".freeze

  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    config.generators.system_tests = nil

    # --- Booting without a database -----------------------------------------
    #
    # The vault is encrypted with a key derived from a passphrase nobody has
    # entered yet when the process starts. So the application comes up with no
    # connection at all, serves the unlock page, and only then calls
    # establish_connection. That is what makes "starts without a network, and
    # cannot be reached around the passphrase" a property of the architecture
    # rather than a promise.
    #
    # Two Rails conveniences would connect on their own and are therefore off:
    config.active_record.migration_error = false        # the CheckPending middleware
    config.active_record.dump_schema_after_migration = false

    # Migrations run from Vault::Store after unlocking, not from a rake task,
    # so there is no schema file to keep in step.
    config.paths["db/migrate"] = [ "db/migrate" ]

    config.i18n.available_locales = %i[en de]
    config.i18n.default_locale = :en
    config.i18n.fallbacks = [ :en ]

    config.time_zone = "UTC"
  end
end
