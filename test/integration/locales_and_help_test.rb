require "test_helper"

class LocalesAndHelpTest < ActionDispatch::IntegrationTest
  setup { reset_vault! }
  teardown { Vault::Store.close! }

  # The one test that keeps the second language from quietly falling behind the
  # first. Without it a new string lands in English and German only later, or
  # never, and nobody notices until a user switches.
  test "both locale files carry exactly the same keys" do
    en = flatten_keys(YAML.load_file(Rails.root.join("config/locales/en.yml"))["en"])
    de = flatten_keys(YAML.load_file(Rails.root.join("config/locales/de.yml"))["de"])

    assert_empty (en - de), "missing in de.yml: #{(en - de).join(', ')}"
    assert_empty (de - en), "missing in en.yml: #{(de - en).join(', ')}"
  end

  test "no locale value is left empty" do
    %w[en de].each do |locale|
      values = flatten_values(YAML.load_file(Rails.root.join("config/locales/#{locale}.yml"))[locale])
      empty  = values.select { |_key, value| value.to_s.strip.empty? }
      assert_empty empty, "empty values in #{locale}.yml: #{empty.keys.join(', ')}"
    end
  end

  test "the help panel is on by default and can be switched off" do
    create_and_unlock

    get root_path
    assert_select "aside.help", 1

    patch settings_path, params: { setting: { help_mode: "0" } }
    get root_path
    assert_select "aside.help", 0
  end

  # Two ways out of a help box, answering two different questions: the setting
  # is "I have read these", the close link is "not on this screen right now".
  # Only offering the setting makes somebody switch off all the help to get past
  # one box — and it does not come back, which is not what they meant.
  test "a help panel can be closed for now without switching the explanations off" do
    create_and_unlock

    get root_path
    assert_select "aside.help[data-controller=?]", "dismissable"
    assert_select "aside.help button[data-action=?]", "dismissable#dismiss",
      text: I18n.t("help.close")

    assert Setting.current.help_mode, "closing one box must not touch the setting"
  end

  test "the interface follows the language setting" do
    create_and_unlock

    patch settings_path, params: { setting: { locale: "de" } }
    get root_path
    assert_select "h1", I18n.t("dashboard.title", locale: :de)

    patch settings_path, params: { setting: { locale: "en" } }
    get root_path
    assert_select "h1", I18n.t("dashboard.title", locale: :en)
  end

  test "changing a setting is recorded in the event log" do
    create_and_unlock
    patch settings_path, params: { setting: { locale: "de" } }

    change = Event.where(kind: "setting_changed").last
    assert_equal "locale", change.detail_hash["setting"]
    assert_equal "de", change.detail_hash["to"]
  end

  # The language chosen on the unlock screen lives in a session cookie, because
  # there is no vault to keep it in yet. Creating one has to move it across, or
  # the application says "Die Datendatei wurde angelegt" and then answers every
  # page after it in English.
  test "the language chosen while creating the data file is the one that stays" do
    get unlock_path(locale: "de")
    without_seeding do
      post unlock_path, params: { passphrase: TEST_PASSPHRASE, passphrase_confirmation: TEST_PASSPHRASE }
    end

    assert_equal "de", Setting.current.locale
    follow_redirect!
    assert_select "h1", I18n.t("dashboard.title", locale: :de)
  end

  test "the unlock screen can be read in German before anything is open" do
    get unlock_path(locale: "de")

    assert_response :success
    assert_includes response.body, I18n.t("unlock.new.warning_title", locale: :de)
  end

  private

  def flatten_keys(hash, prefix = nil)
    hash.flat_map do |key, value|
      path = [ prefix, key ].compact.join(".")
      value.is_a?(Hash) ? flatten_keys(value, path) : [ path ]
    end
  end

  def flatten_values(hash, prefix = nil)
    hash.each_with_object({}) do |(key, value), out|
      path = [ prefix, key ].compact.join(".")
      if value.is_a?(Hash)
        out.merge!(flatten_values(value, path))
      elsif value.is_a?(Array)
        value.each_with_index { |item, i| out["#{path}[#{i}]"] = item }
      else
        out[path] = value
      end
    end
  end
end
