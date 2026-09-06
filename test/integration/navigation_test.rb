require "test_helper"

# The bar.
#
# What is worth a test here is not the markup but the one piece of reasoning in
# it: which group is marked as the one you are in. With eight flat links that
# was `current_page?` and needed no thought; with the pages inside groups it has
# to hold for pages one level down too, which is most of them.
class NavigationTest < ActionDispatch::IntegrationTest
  test "the group holding the page is marked, and only that one" do
    with_open_vault do
      create_and_unlock

      { "/product-types" => "Passports",
        "/passports"     => "Passports",
        "/setup"         => "Identity",
        "/vault"         => "Administration",
        "/events"        => "Administration",
        "/settings"      => "Administration" }.each do |path, group|
        get path
        assert_response :success
        assert_equal [ group ], marked_groups, "#{path} should mark exactly #{group}"
      end
    end
  end

  # The case the old bar could not express: a passport being edited is under
  # /passports but is not /passports, so `current_page?` says no and the bar
  # would go blank exactly where the operator is doing the work.
  test "a page one level down still marks its group" do
    with_open_vault do
      create_and_unlock
      type = ProductType.create!(label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example",
                                 jsonld: '{"@graph":[]}', forms: "{}", fetched_at: Time.current)

      get edit_product_type_path(type)

      assert_response :success
      assert_equal [ "Passports" ], marked_groups
    end
  end

  # Overview is flat, so no group may claim it — and "/" must not be treated as
  # a prefix, or every page would be inside every group.
  test "the overview is its own entry and marks no group" do
    with_open_vault do
      create_and_unlock

      get root_path

      assert_response :success
      assert_empty marked_groups
      assert_select "nav > a.on", text: "Overview"
    end
  end

  # The title is a link now. Both ways home exist on purpose: that a wordmark
  # leads home is a convention not everyone knows.
  test "the title leads to the overview" do
    with_open_vault do
      create_and_unlock
      get events_path

      assert_select "a.brand[href=?]", root_path
    end
  end

  # The footer names the file the whole application is about, so the words that
  # name it lead to the page about it — quietly, in the colour of the sentence
  # around them.
  test "the footer's mention of the file leads to the file's own page" do
    with_open_vault do
      create_and_unlock

      get root_path

      assert_select "footer a.quiet[href=?]", vault_path, text: "encrypted file"
    end
  end

  test "the identity is offered only once there is one" do
    with_open_vault do
      create_and_unlock

      get events_path
      assert_select "nav a[href=?]", identity_path, count: 0

      Identity.create!(did: "did:oyd:zQmWxYzabcdefgh", origin: "minted", document_key: "k")
      get events_path
      assert_select "nav a[href=?]", identity_path, count: 1
    end
  end

  private

  def marked_groups
    css_select("nav details.on summary").map { |node| node.text.strip }
  end
end
