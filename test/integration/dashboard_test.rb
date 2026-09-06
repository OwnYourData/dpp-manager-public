require "test_helper"

# The overview is the page somebody lands on every morning, so what it shows has
# to be what they came for. It used to advertise the parts that were not built
# yet; those are all built, and a page that keeps saying otherwise is a page
# that lies to its reader.
class DashboardTest < ActionDispatch::IntegrationTest
  test "before the setup is finished the overview offers the setup" do
    with_open_vault do
      create_and_unlock

      get root_path

      assert_response :success
      assert_select ".card.wide a[href=?]", setup_path
      assert_select ".card.wide", text: /#{Regexp.escape(I18n.t('dashboard.setup.title'))}/
    end
  end

  test "with the setup finished and no passports, the overview invites one" do
    with_open_vault do
      create_and_unlock
      finish_setup!

      get root_path

      assert_select ".card.wide a[href=?]", passports_path
      assert_select ".card.wide", text: /#{Regexp.escape(I18n.t('dashboard.passports.none'))}/
    end
  end

  test "the passports are on the overview, newest first, with what state they are in" do
    with_open_vault do
      create_and_unlock
      finish_setup!
      older = passport("Batch A")
      newer = passport("Batch B")
      newer.update!(status: "submitted", updated_at: 1.minute.from_now)

      get root_path

      assert_select ".card.wide table tr:first-child a[href=?]", edit_passport_path(newer)
      assert_select ".card.wide table", text: /#{I18n.t('passports.states.submitted')}/
      assert_select ".card.wide a[href=?]", edit_passport_path(older)
      assert_select ".card.wide a[href=?]", passports_path
    end
  end

  # The one thing the overview must never stop doing.
  test "a mandate about to run out is named before anything else" do
    with_open_vault do
      create_and_unlock
      finish_setup!
      passport("Batch A").update!(status: "submitted", custodian_collection_id: "7",
                                  delegation_jti: "abc", delegation_expires_at: 2.days.from_now)

      get root_path

      assert_select "div.warning a[href=?]", edit_passport_path(Passport.last)
    end
  end

  private

  def finish_setup!
    Setting.current.update!(service_base_url: "https://svc.example", service_audience: "https://svc.example",
                            setup_completed_at: Time.current)
  end

  def product_type
    ProductType.first || ProductType.create!(label: "Lamp", structure_name: "Lamp",
                                             repo_base_url: "https://soya.example",
                                             jsonld: '{"@graph":[]}', fetched_at: Time.current)
  end

  def passport(label)
    Passport.create!(product_type: product_type, label: label, data: "{}")
  end
end
