require "test_helper"

class SoyaImportTest < ActiveSupport::TestCase
  STRUCTURE = Soya::Repository::Structure.new(
    name: "Lamp", jsonld: '{"@graph":[]}', yaml: "meta:\n  name: Lamp\n", dri: "zLamp"
  )

  FORM = { "schema" => { "properties" => { "watt" => { "type" => "integer" } } }, "ui" => {}, "options" => [] }.freeze

  test "a refresh stores the structure and a form for each language" do
    with_open_vault do
      type = create

      with_repository_and_web_cli do
        assert Soya::Import.refresh(type).ok?
      end

      type.reload
      assert_equal "zLamp", type.dri
      assert type.fetched?
      assert_equal %w[en de].sort, type.forms_by_language.keys.sort
      assert_nil type.fetch_error
    end
  end

  # The order is not cosmetic. Generating a form means asking soya-web-cli, and
  # soya-web-cli answers by pulling the structure back out of this application —
  # so it has to be stored before the first form is asked for, not after.
  test "the structure is readable from the local repository before a form is asked for" do
    with_open_vault do
      type = create
      seen = nil

      stubbing(Soya::Repository, :fetch, ->(*) { STRUCTURE }) do
        stubbing(Soya::WebCli, :form, ->(name, **) {
          seen = ProductType.resolve(name)&.jsonld
          FORM
        }) { Soya::Import.refresh(type) }
      end

      assert_equal '{"@graph":[]}', seen, "the form was generated before the structure was there to pull"
    end
  end

  test "a failed refresh says why and leaves the copy that worked" do
    with_open_vault do
      type = create
      with_repository_and_web_cli { Soya::Import.refresh(type) }
      fetched_at = type.reload.fetched_at

      stubbing(Soya::Repository, :fetch, ->(*) { raise Soya::Error, "timeout" }) do
        result = Soya::Import.refresh(type)
        assert_not result.ok?
        assert_equal "timeout", result.error
      end

      type.reload
      assert_equal "timeout", type.fetch_error
      assert_equal fetched_at.to_i, type.fetched_at.to_i, "the previous copy must survive a failed refresh"
      assert type.forms_by_language.any?, "and so must the forms made from it"
    end
  end

  # One language failing is a shortfall worth reporting; it is not a reason to
  # throw away a form that does work.
  test "a language that fails to generate is left out rather than taking the rest with it" do
    with_open_vault do
      type = create

      stubbing(Soya::Repository, :fetch, ->(*) { STRUCTURE }) do
        stubbing(Soya::WebCli, :form, ->(_name, language: nil, **) {
          raise Soya::Error, "no overlay" if language == "de"
          FORM
        }) do
          assert Soya::Import.refresh(type).ok?
        end
      end

      assert_equal %w[en], type.reload.forms_by_language.keys
    end
  end

  test "no language generating at all is a failed refresh, not an empty type" do
    with_open_vault do
      type = create

      stubbing(Soya::Repository, :fetch, ->(*) { STRUCTURE }) do
        stubbing(Soya::WebCli, :form, ->(*, **) { raise Soya::Error, "web-cli is down" }) do
          assert_not Soya::Import.refresh(type).ok?
        end
      end

      assert_empty type.reload.forms_by_language
    end
  end

  test "both outcomes end up in the event log" do
    with_open_vault do
      type = create

      with_repository_and_web_cli { Soya::Import.refresh(type) }
      stubbing(Soya::Repository, :fetch, ->(*) { raise Soya::Error, "timeout" }) { Soya::Import.refresh(type) }

      kinds = Event.pluck(:kind)
      assert_includes kinds, "product_type_fetched"
      assert_includes kinds, "product_type_fetch_failed"
      assert_nil Event.verify_chain, "the log must still be intact"
    end
  end

  # The finding that this test exists for: asking soya-web-cli for a form in a
  # language is not enough. A structure carrying a form overlay for that
  # language still answers with the *generated* form unless the tag is passed
  # too — no error, no warning, and the author's grouping silently gone.
  test "a structure with one tagged form for a language is asked again with that tag" do
    with_open_vault do
      type = create
      asked = []

      options = [ { "language" => "en" }, { "language" => "de" },
                  { "language" => "en", "tag" => "dpp" }, { "language" => "de", "tag" => "dpp" } ]

      stubbing(Soya::Repository, :fetch, ->(*) { STRUCTURE }) do
        stubbing(Soya::WebCli, :form, ->(_name, language: nil, tag: nil) {
          asked << [ language, tag ]
          FORM.merge("options" => options, "ui" => { "type" => tag ? "Categorization" : "Group" })
        }) { Soya::Import.refresh(type) }
      end

      assert_includes asked, [ "de", "dpp" ]
      assert_equal "Categorization", type.reload.form_for("de").dig("ui", "type"),
        "the author's form was there and the generated one was stored instead"
    end
  end

  # Two forms for one language is a decision, not a default. Picking one would
  # be wrong half the time and would look like it had worked.
  test "several tags for a language are left to the operator" do
    with_open_vault do
      type = create
      options = [ { "language" => "de", "tag" => "dpp" }, { "language" => "de", "tag" => "short" } ]

      stubbing(Soya::Repository, :fetch, ->(*) { STRUCTURE }) do
        stubbing(Soya::WebCli, :form, ->(_name, language: nil, tag: nil) {
          FORM.merge("options" => options, "chosen" => tag)
        }) { Soya::Import.refresh(type) }
      end

      type.reload
      assert_nil type.form_for("de")["chosen"], "a tag was guessed"
      assert type.ambiguous_form_choice?, "the type must say that a choice is outstanding"
      assert_equal %w[dpp short], type.form_tags_for("de").sort
    end
  end

  test "a tag the operator set is used as given and nothing is guessed" do
    with_open_vault do
      type = create(form_tag: "short")
      asked = []

      stubbing(Soya::Repository, :fetch, ->(*) { STRUCTURE }) do
        stubbing(Soya::WebCli, :form, ->(_name, language: nil, tag: nil) {
          asked << tag
          FORM.merge("options" => [ { "language" => "de", "tag" => "dpp" } ])
        }) { Soya::Import.refresh(type) }
      end

      assert_equal [ "short", "short" ], asked
    end
  end

  private

  def with_repository_and_web_cli
    stubbing(Soya::Repository, :fetch, ->(*) { STRUCTURE }) do
      stubbing(Soya::WebCli, :form, ->(*, **) { FORM }) { yield }
    end
  end

  def create(**overrides)
    ProductType.create!({ label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example" }.merge(overrides))
  end
end
