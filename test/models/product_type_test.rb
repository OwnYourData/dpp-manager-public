require "test_helper"

class ProductTypeTest < ActiveSupport::TestCase
  FORMS = {
    "en" => { "schema" => { "properties" => { "name" => { "type" => "string" }, "watt" => { "type" => "integer" } } }, "ui" => {} },
    "de" => { "schema" => { "properties" => { "name" => { "type" => "string" } } }, "ui" => {} }
  }.freeze

  test "a structure name has to be something that survives being put in a URL" do
    with_open_vault do
      %w[Lamp lamp-2 A.b_c].each do |name|
        assert build(structure_name: name).valid?, "#{name} should be allowed"
      end

      [ "with space", "sla/sh", "", "ü", "~tilde" ].each do |name|
        assert_not build(structure_name: name).valid?, "#{name.inspect} should be refused"
      end
    end
  end

  test "the repository must be an http address" do
    with_open_vault do
      assert_not build(repo_base_url: "not a url").valid?
      assert_not build(repo_base_url: "ftp://soya.example").valid?
      assert build(repo_base_url: "https://soya.example").valid?
    end
  end

  test "a bare host is read as https and the trailing slash goes" do
    with_open_vault do
      type = create(repo_base_url: "soya.example/")
      assert_equal "https://soya.example", type.repo_base_url
    end
  end

  test "the same structure can come from two repositories but not twice from one" do
    with_open_vault do
      create(structure_name: "Lamp", repo_base_url: "https://a.example")
      assert build(structure_name: "Lamp", repo_base_url: "https://b.example").valid?
      assert_not build(structure_name: "Lamp", repo_base_url: "https://a.example").valid?
    end
  end

  # The name handed to soya-web-cli is not the structure's name, because
  # soya-js keeps a pulled structure for half an hour and a refresh inside that
  # window would otherwise be generated from the copy it already had.
  test "the resolvable name changes when the structure is fetched again" do
    with_open_vault do
      type = create
      first = type.resolvable_name

      travel 5.seconds do
        type.update!(fetched_at: Time.current)
        assert_not_equal first, type.resolvable_name
      end
    end
  end

  test "a resolvable name finds its row again" do
    with_open_vault do
      type = create
      assert_equal type, ProductType.resolve(type.resolvable_name)
    end
  end

  # The name is carried alongside the id for exactly this: a request that pairs
  # one type's id with another's name is a mistake somewhere, and answering it
  # would serve the wrong structure to a form that asked for a different one.
  test "a resolvable name whose parts disagree resolves to nothing" do
    with_open_vault do
      type = create(structure_name: "Lamp")
      assert_nil ProductType.resolve("Bulb~#{type.id}~#{type.fetched_at.to_i}")
      assert_nil ProductType.resolve("Lamp~999999~1")
    end
  end

  test "a form is looked up by language and falls back rather than coming back empty" do
    with_open_vault do
      type = create(forms: FORMS.to_json)

      assert_equal 1, type.form_for("de").dig("schema", "properties").size
      assert_equal 2, type.form_for("en").dig("schema", "properties").size
      # Neither language is there: better an untranslated form than none.
      assert_not_nil type.form_for("fr")
    end
  end

  test "the summary counts what the structure actually declares" do
    with_open_vault do
      structure = {
        "@graph" => [
          { "@type" => "soya:Base", "name" => "Lamp" },
          { "@type" => "soya:OverlayAnnotation" },
          { "@type" => "soya:OverlayValidation" },
          { "@type" => [ "soya:OverlayForm" ] }
        ]
      }

      summary = create(jsonld: structure.to_json).summary
      assert_equal 1, summary[:bases]
      assert_equal({ "Annotation" => 1, "Validation" => 1, "Form" => 1 }, summary[:overlays])
    end
  end

  test "a structure that is not there yet has no summary and does not raise" do
    with_open_vault { assert_nil ProductType.new.summary }
  end

  private

  def attributes(**overrides)
    {
      label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example",
      fetched_at: Time.current
    }.merge(overrides)
  end

  def build(**overrides) = ProductType.new(attributes(**overrides))
  def create(**overrides) = ProductType.create!(attributes(**overrides))
end
