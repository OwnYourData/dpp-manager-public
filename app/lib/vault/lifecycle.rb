module Vault
  # The three things that happen to a vault from the outside — creating it,
  # opening it, closing it — together with the log entries that go with them.
  #
  # Kept apart from Store so that Store stays about the file and this stays
  # about the application's account of what happened.
  module Lifecycle
    # Failed attempts are slowed down deliberately. Argon2id already makes each
    # guess expensive; this makes a run of them expensive in wall-clock time as
    # well, and it is the only rate limit that exists in a single-user local
    # application.
    FAILURE_DELAY = 1.5

    module_function

    # `seed` puts the product types the image ships with into the new vault.
    # An argument rather than a constant because the test suite creates a vault
    # per test and must not reach a repository, and because a caller that wants
    # an empty vault should be able to say so.
    #
    # `locale` is the language the person was reading when they chose their
    # passphrase. Until this moment that choice lived in a session cookie,
    # because there was no vault to keep it in; it has to be written into the
    # settings here or the application answers the next request in English —
    # having just addressed them in German.
    #
    # It is set BEFORE seeding, so the product types the image brings are
    # labelled in the same language rather than in whichever one the default
    # happened to be.
    def create!(passphrase, seed: true, locale: I18n.locale)
      Store.create!(passphrase)

      settings = Setting.current
      settings.update!(locale: locale.to_s) if Setting::LOCALES.include?(locale.to_s)

      Event.record!(:vault_created, kdf_profile: Session.profile)
      Soya::Seed.install!(settings.locale) if seed
      true
    end

    def unlock!(passphrase)
      Store.open!(passphrase)
      Setting.current

      # The log lives inside the vault, so a failed attempt cannot be written
      # when it happens — there is nothing open to write to. The process counts
      # them instead and the count is entered here, on the first unlock that
      # succeeds. What survives a restart is therefore only what was followed by
      # a successful unlock; a run of failures that never succeeded leaves no
      # trace, and no design that keeps the log inside the vault can change that.
      if failures_since_last_unlock.positive?
        Event.record!(:vault_open_failed, attempts: failures_since_last_unlock)
      end
      clear_failures!

      Event.record!(:vault_opened, kdf_profile: Session.profile)
      true
    rescue LockedError
      register_failure
      sleep FAILURE_DELAY
      false
    end

    def lock!(reason: "manual")
      Event.record!(:vault_locked, reason: reason) if Store.open?
      Store.close!
      true
    end

    def failures_since_last_unlock
      @failures ||= 0
    end

    def register_failure
      @failures = failures_since_last_unlock + 1
    end

    def clear_failures!
      @failures = 0
    end
  end
end
