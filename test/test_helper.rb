ENV["RAILS_ENV"] ||= "test"

# Every test works on a real, throw-away vault in a temporary directory. There
# is no fixture database and no schema load: the vault is created the way the
# application creates it, because the creation path is one of the things under
# test.
require "tmpdir"
ENV["DPP_DATA_DIR"] ||= Dir.mktmpdir("dpp-manager-test-")

require_relative "../config/environment"
require "rails/test_help"

# The migrations run inside every test, because every test creates its own
# vault. Their output is noise here.
ActiveRecord::Migration.verbose = false

class ActiveSupport::TestCase
  # Deliberately not parallelised: there is one vault, one connection and one
  # process-wide key holder. Parallel workers would fight over all three.

  # Transactional tests open a transaction before the test body runs — which
  # means connecting before any vault exists, and the adapter has no key at that
  # point. Each test creates and throws away its own vault instead, which is
  # closer to what actually happens in the application anyway.
  self.use_transactional_tests = false

  # There are no fixtures in this project and there cannot be: the schema only
  # exists inside a vault that a passphrase has opened, and the fixture loader
  # reaches for a connection in before_setup, before any test body has run. So
  # the fixture hooks are turned off outright rather than pointed at an empty
  # directory, which still connects.
  def setup_fixtures(*) = nil
  def teardown_fixtures(*) = nil

  TEST_PASSPHRASE = "correct horse battery staple".freeze

  def with_open_vault(passphrase = TEST_PASSPHRASE)
    reset_vault!
    # No seeding: the bundled product types would send every test to a
    # repository over the network and to a soya-web-cli that is not running.
    # The one test that is about seeding turns it on itself.
    Vault::Lifecycle.create!(passphrase, seed: false)
    yield
  ensure
    Vault::Store.close!
  end

  # A request sets I18n.locale for the whole process and nothing puts it back, so
  # one test that switches to German leaves every later test in German. That was
  # harmless until creating a vault started storing the language it was created
  # in — after which a test's outcome depended on which test ran before it.
  teardown { I18n.locale = I18n.default_locale }

  def reset_vault!
    Vault::Store.close!
    Dir.glob(File.join(Vault::Store.data_dir, "*")).each { |f| FileUtils.rm_f(f) }
    Vault::Lifecycle.clear_failures!
  end

  # Minitest 6 no longer ships minitest/mock, and replacing a module function
  # outright leaks the replacement into every later test in the same process.
  # This puts the original back afterwards.
  #
  #   stubbing(Did::Oyd, :mint, ->(_content = {}) { { did: "did:oyd:…" } }) do
  #     post setup_mint_identity_path
  #   end
  def stubbing(mod, name, replacement)
    original = mod.method(name)
    mod.define_singleton_method(name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    yield
  ensure
    mod.define_singleton_method(name) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
  end

  def data_dir_entries
    Dir.glob(File.join(Vault::Store.data_dir, "*")).map { |f| File.basename(f) }.sort
  end
end

class ActionDispatch::IntegrationTest
  def create_and_unlock(passphrase = ActiveSupport::TestCase::TEST_PASSPHRASE)
    without_seeding do
      post unlock_path, params: { passphrase: passphrase, passphrase_confirmation: passphrase }
    end
  end

  # Creating a vault through the controller also fills it with the product types
  # the image ships with — which means a repository over the network and a
  # soya-web-cli that is not running. Every test that is not about seeding wants
  # that skipped; the ones that are about it call Seed themselves.
  def without_seeding(&block)
    stubbing(Soya::Seed, :install!, ->(*) { Soya::Seed::Result.new(installed: [], failed: []) }, &block)
  end
end
