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

  # Who made it, and the name of the house leads out to the web. In a new tab:
  # an application holding an open vault must not navigate away from itself
  # because somebody read the footer.
  test "the footer says OwnYourData developed it and links to it in a new tab" do
    with_open_vault do
      create_and_unlock

      get root_path

      assert_select "footer p.by", text: /\ADeveloped by OwnYourData — everything is kept in one encrypted file on this machine\.\z/
      assert_select "footer p.by a.quiet[href=?][target=?][rel=?]",
        "https://www.ownyourdata.eu/en/", "_blank", "noopener", text: "OwnYourData"
    end
  end

  # As in the footers of the DPP Service and the DPP Linter: where the other
  # DPP tools are, the source and the version. The tools are always those of
  # OwnYourData, whichever service this installation submits to.
  test "the footer leads to the DPP tools and the source, and names the version" do
    with_open_vault do
      create_and_unlock
      Setting.current.update!(service_base_url: "https://dpp.example.org", service_audience: "https://dpp.example.org")

      get root_path

      assert_select "footer p.links a.quiet[href=?][target=?][rel=?]", "https://dpp-service.ownyourdata.eu",
        "_blank", "noopener", text: "DPP Service, Knowledge Base, Linter and Validator"
      assert_select "footer p.links a.quiet[href=?][target=?][rel=?]", "https://github.com/OwnYourData/dpp-manager-public",
        "_blank", "noopener", text: "Source code"
      assert_select "footer p.links", text: /·\s+Version #{Regexp.escape(DppManager::VERSION)}\z/
    end
  end

  test "the footer speaks German in German" do
    with_open_vault do
      create_and_unlock
      Setting.current.update!(locale: "de")

      get root_path

      assert_select "footer p.by", text: /\AEntwickelt von OwnYourData — alles liegt in einer verschlüsselten Datei auf diesem Rechner\.\z/
      assert_select "footer p.by a[href=?]", "https://www.ownyourdata.eu/"
      assert_select "footer p.links a", text: "DPP Service, Knowledge Base, Linter und Validator"
      assert_select "footer p.links a", text: "Quelltext"
    end
  end

  # On the right of the bar, as in the bars of the DPP Linter and the Validator:
  # the DPP Service this installation submits to, in a tab of its own.
  test "the bar links to the DPP Service that is set up, and before setup to the one setup suggests" do
    with_open_vault do
      create_and_unlock

      get root_path
      assert_select "header nav > a.service:last-child[href=?][target=?][rel=?]", "https://dpp-service.ownyourdata.eu",
        "_blank", "noopener", text: "DPP Service"

      Setting.current.update!(service_base_url: "https://dpp.example.org", service_audience: "https://dpp.example.org")
      get events_path
      assert_select "header nav > a.service[href=?]", "https://dpp.example.org", text: "DPP Service"
      assert_select "header a.service", 1
    end
  end

  # Below that line, in smaller type, the funding of PACE-DPP. Its links leave
  # the application, so they open in a new tab like the one above.
  test "the footer names the funding of PACE-DPP" do
    with_open_vault do
      create_and_unlock

      get root_path

      assert_select "footer p.funding[lang=?]", "en", text: /\AThe DPP Manager is part of PACE-DPP\./
      assert_select "footer p.funding a.quiet[href=?][target=?][rel=?]",
        "https://projekte.ffg.at/projekt/5128301", "_blank", "noopener", text: "917177"
      assert_select "footer p.funding a", 3
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
