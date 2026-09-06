require "test_helper"

# Putting the bundled product types into a vault, and the fallback that makes
# them work without a network.
class SoyaSeedTest < ActiveSupport::TestCase
  FORM = { "schema" => { "properties" => { "watt" => { "type" => "integer" } } }, "ui" => {} }.freeze

  test "a new vault starts with the bundled types, form and transformation included" do
    with_open_vault do
      offline { Soya::Seed.install! }

      type = ProductType.find_by(structure_name: "DppLedLamp")
      assert type, "the image ships a lamp and the vault does not have it"
      assert_equal "DppLedLampToEN18223", type.transformation_name
      assert type.fetched?, "a seeded type that still has to be fetched is no use to anybody"
      assert type.transformation_fetched?, "without this the passport cannot be submitted"
      assert_equal %w[en de].sort, type.forms_by_language.keys.sort
    end
  end

  # The whole point of bundling: the first start on a machine with no network
  # still ends with a usable product type.
  test "seeding needs no repository" do
    with_open_vault do
      offline { Soya::Seed.install! }

      type = ProductType.find_by(structure_name: "DppLedLamp")
      assert_equal JSON.parse(Soya::Bundled.fetch("DppLedLamp").jsonld), JSON.parse(type.jsonld)
    end
  end

  # "Fetch again" has to mean the repository, or the button is a lie. The copy
  # in the image is the fallback, never the first answer.
  test "the repository is asked first and the image only when it does not answer" do
    with_open_vault do
      from_repo = Soya::Repository::Structure.new(name: "DppLedLamp", jsonld: '{"@graph":["newer"]}',
                                                  yaml: "meta:\n", dri: "z-newer")

      stubbing(Soya::Repository, :fetch, ->(_base, _name) { from_repo }) do
        stubbing(Soya::WebCli, :form, ->(*, **) { FORM }) do
          Soya::Seed.install!
        end
      end

      type = ProductType.find_by(structure_name: "DppLedLamp")
      assert_equal '{"@graph":["newer"]}', type.jsonld
      assert_equal "z-newer", type.dri
    end
  end

  # A type nobody bundled has nothing to fall back to. Storing an empty one
  # would leave a row that says "fetched" and renders no form.
  test "a structure the image does not carry still fails when the repository is down" do
    with_open_vault do
      type = ProductType.create!(label: "Something", structure_name: "SomethingElse",
                                 repo_base_url: "https://soya.example")

      result = offline { Soya::Import.refresh(type) }

      assert_not result.ok?
      assert_not type.reload.fetched?
    end
  end

  # The structure is stored before the forms are generated, so a first fetch
  # that dies in soya-web-cli would otherwise leave a row that claims to be
  # ready and renders an empty form.
  test "a type whose form could never be generated does not claim to be ready" do
    with_open_vault do
      type = ProductType.create!(label: "Lamp", structure_name: "DppLedLamp",
                                 repo_base_url: "https://soya.ownyourdata.eu")

      result = stubbing(Soya::Repository, :fetch, ->(*) { raise Soya::Error, "unreachable" }) do
        stubbing(Soya::WebCli, :form, ->(*, **) { raise Soya::Error, "no_web_cli" }) do
          Soya::Import.refresh(type)
        end
      end

      assert_not result.ok?
      type.reload
      assert_not type.fetched?, "a row with no form must not appear in the list of usable types"
      assert type.jsonld.present?, "what was fetched is still kept — only the claim is withdrawn"
    end
  end

  test "seeding twice adds nothing and touches nothing" do
    with_open_vault do
      offline { Soya::Seed.install! }
      type = ProductType.find_by(structure_name: "DppLedLamp")
      type.update!(label: "My own name for it")

      result = offline { Soya::Seed.install! }

      assert_empty result.installed
      assert_equal 1, ProductType.where(structure_name: "DppLedLamp").count
      assert_equal "My own name for it", type.reload.label,
        "a seeded type belongs to the operator afterwards"
    end
  end

  test "pending? says whether there is anything left to add" do
    with_open_vault do
      assert Soya::Seed.pending?
      offline { Soya::Seed.install! }
      assert_not Soya::Seed.pending?
    end
  end

  test "the label follows the language the vault was created in" do
    with_open_vault do
      I18n.with_locale(:de) { offline { Soya::Seed.install! } }
      assert_equal "LED-Lampe", ProductType.find_by(structure_name: "DppLedLamp").label
    end
  end

  private

  # No repository and no soya-web-cli — the state a fresh installation on a
  # disconnected machine is in, and the one the test suite is always in.
  def offline(&block)
    stubbing(Soya::Repository, :fetch, ->(*) { raise Soya::Error, "unreachable" }) do
      stubbing(Soya::WebCli, :form, ->(*, **) { FORM }, &block)
    end
  end
end
