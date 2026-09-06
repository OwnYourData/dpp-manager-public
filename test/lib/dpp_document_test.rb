require "test_helper"

# The document that goes to the service: the envelope of EN 18223 Table 1 plus
# whatever the transformation made of the answers.
#
# The elements are stubbed here on purpose. What they should contain is pinned
# by LampTransformationTest against the published jq; what is under test here is
# the seam — which attributes this application decides, which it leaves to the
# service, and what happens when the transformation is not there.
class DppDocumentTest < ActiveSupport::TestCase
  ELEMENTS = [ { "objectType" => "DataElementCollection", "elementId" => "ProductIdentification" } ].freeze

  test "the envelope carries what only this application knows" do
    with_open_vault do
      passport = ready_passport
      identity = Identity.create!(did: "did:oyd:zQmWxYzabcdefgh", origin: "minted", document_key: "k")

      document = transforming { Dpp::Document.build(passport) }

      assert_equal passport.dpp_id, document["digitalProductPassportId"]
      assert_equal passport.unique_product_identifier, document["uniqueProductIdentifier"]
      assert_equal "item", document["granularity"]
      assert_equal "EN 18223:2026", document["dppSchemaVersion"]
      assert_equal identity.did, document["economicOperatorId"]
      assert_equal ELEMENTS, document["elements"]
    end
  end

  # dppStatus and lastUpdated are the service's to set. A client that sent them
  # would be asserting a state it does not control, and the service would
  # overwrite them anyway — so the only thing sending them could achieve is a
  # document that looks authoritative about something it is not.
  test "the two attributes that belong to the service are absent" do
    with_open_vault do
      document = transforming { Dpp::Document.build(ready_passport) }

      assert_not document.key?("dppStatus")
      assert_not document.key?("lastUpdated")
    end
  end

  # An absent optional attribute is left out rather than sent as null: null is a
  # statement that there is no facility, which is not the same as not saying.
  test "an unanswered optional attribute is omitted, not sent empty" do
    with_open_vault do
      document = transforming { Dpp::Document.build(ready_passport) }
      assert_not document.key?("facilityId")

      passport = ready_passport(facility_id: "https://id.example.com/414/9520123456788")
      document = transforming { Dpp::Document.build(passport) }
      assert_equal "https://id.example.com/414/9520123456788", document["facilityId"]
    end
  end

  test "a type without a transformation says so instead of sending an empty passport" do
    with_open_vault do
      passport = ready_passport(transformation_name: nil)

      error = assert_raises(Dpp::Document::Error) { Dpp::Document.build(passport) }
      assert_equal "no_transformation", error.message
    end
  end

  test "a transformation that was named but never fetched is not silently skipped" do
    with_open_vault do
      passport = ready_passport(transformation_fetched: false)

      error = assert_raises(Dpp::Document::Error) { Dpp::Document.build(passport) }
      assert_equal "transformation_not_fetched", error.message
    end
  end

  # soya-web-cli answering with something that is not a list means the overlay
  # did not run — a jq error comes back as a string, and a string of elements is
  # not a document.
  test "an answer that is not a list of elements is refused" do
    with_open_vault do
      passport = ready_passport

      stubbing(Soya::WebCli, :transform, ->(*) { { "error" => "jq: syntax error" } }) do
        error = assert_raises(Dpp::Document::Error) { Dpp::Document.build(passport) }
        assert_equal "transformation_did_not_yield_elements", error.message
      end
    end
  end

  test "the transformation is asked for under its own cache-busting name" do
    with_open_vault do
      passport = ready_passport
      asked = nil

      stubbing(Soya::WebCli, :transform, ->(name, _data) { asked = name; ELEMENTS }) do
        Dpp::Document.build(passport)
      end

      type = passport.product_type
      assert_equal type.transformation_resolvable_name, asked
      assert_match(/\ADppLedLampToEN18223~#{type.id}~\d+\z/, asked,
        "a refreshed transformation must not be shadowed by soya-js's copy of the previous one")
    end
  end

  private

  def ready_passport(facility_id: nil, transformation_name: "DppLedLampToEN18223", transformation_fetched: true)
    type = ProductType.find_or_create_by!(structure_name: "DppLedLamp", repo_base_url: "https://soya.example") do |t|
      t.label = "Lamp"
    end
    type.update!(
      jsonld: '{"@graph":[]}', forms: { "en" => { "schema" => { "properties" => {} }, "ui" => {} } }.to_json,
      fetched_at: Time.current,
      transformation_name: transformation_name,
      transformation_jsonld: (transformation_name && transformation_fetched ? '{"@graph":[]}' : nil),
      transformation_fetched_at: (transformation_name && transformation_fetched ? Time.current : nil))

    Passport.create!(product_type: type, label: "Batch A", facility_id: facility_id,
                     unique_product_identifier: "https://id.example.com/01/09520123456788/21/000123",
                     granularity: "item", data: "{}")
           .tap { |p| p.update_columns(dpp_id: "did:oyd:zQmPassport#{p.id}", minted_at: Time.current,
                                       endpoint_base: "https://dpp-service.example", status: "minted") }
  end

  def transforming(&block) = stubbing(Soya::WebCli, :transform, ->(*) { ELEMENTS }, &block)
end
