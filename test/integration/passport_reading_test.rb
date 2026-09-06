require "test_helper"

# Reading a passport that was written somewhere else.
#
# The screen has no identity behind it and writes nothing, which is the whole
# point — so what these tests pin is mostly about honesty: that the document is
# shown as it stands even when nothing here can read it, that a 404 is said as
# what it is, and that a draft made from a foreign passport does not carry that
# product's identifier away with it.
class PassportReadingTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  PRODUCT = "https://id.example.com/01/09520123456788/21/000123".freeze
  DID = "did:oyd:zQmForeignPassport".freeze

  DOCUMENT = {
    "digitalProductPassportId" => DID,
    "uniqueProductIdentifier"  => PRODUCT,
    "granularity"              => "item",
    "dppStatus"                => "Active",
    "dppSchemaVersion"         => "EN 18223:2026",
    "economicOperatorId"       => "did:oyd:zQmSomebodyElse",
    "elements" => [
      { "objectType" => "DataElementCollection", "elementId" => "ProductIdentification",
        "elements" => [
          { "objectType" => "SingleValuedDataElement", "elementId" => "ModelIdentifier",
            "value" => "LUM-A60", "valueDataType" => "xsd:string" }
        ] },
      { "objectType" => "DataElementCollection", "elementId" => "EnergyPerformance",
        "elements" => [
          { "objectType" => "SingleValuedDataElement", "elementId" => "LuminousFlux",
            "value" => 806, "valueDataType" => "xsd:integer", "unitOfMeasure" => "lm" }
        ] }
    ]
  }.freeze

  test "a product identifier is looked up at the configured service and shown as it stands" do
    with_open_vault do
      create_and_unlock
      configured

      seen = nil
      reading(by_product_id: ->(base_url:, product_id:) {
        seen = { base_url: base_url, product_id: product_id }
        found(DOCUMENT)
      }) { get lookup_path, params: { identifier: PRODUCT } }

      assert_response :success
      assert_equal SERVICE, seen[:base_url]
      assert_equal PRODUCT, seen[:product_id]

      assert_select "code", text: DID
      assert_select ".elements .eid", text: "ModelIdentifier"
      assert_select ".elements .val", text: /806 lm/
      assert Event.where(kind: "passport_read").exists?
    end
  end

  # The bug a screenshot found and no test here could: Turbo refuses to render a
  # 200 answer to a form submission, so a page that shows its result rather than
  # redirecting must be reached with GET. Posted, the button does nothing at all
  # in a browser while every test in this file still passes.
  test "the form that reads a passport asks with GET" do
    with_open_vault do
      create_and_unlock
      configured

      get lookup_path

      assert_select "form.lookup" do |forms|
        assert_equal "get", forms.first["method"].to_s.downcase,
          "a POST here renders, and Turbo will not display a rendered answer to a POST"
      end
    end
  end

  # The decentralised half: the address comes out of the DID document, so this
  # application does not decide where a foreign passport lives.
  test "a passport identifier is resolved and read where its own document says it lives" do
    with_open_vault do
      create_and_unlock
      configured

      address = nil
      reading(endpoint: ->(_did) { "https://custodian.example/dpp/v1/dppsByProductId/x" },
              read: ->(url) { address = url; found(DOCUMENT) }) do
        get lookup_path, params: { identifier: DID }
      end

      assert_equal "https://custodian.example/dpp/v1/dppsByProductId/x", address
      assert_select ".elements .eid", text: "LuminousFlux"
    end
  end

  test "a DID that names no passport is said in the registry's own words" do
    with_open_vault do
      create_and_unlock
      configured

      reading(endpoint: ->(_did) { raise Did::Oyd::Error, "#{DID} is not a product passport" }) do
        get lookup_path, params: { identifier: DID }
      end

      assert_select ".flash.alert", text: /is not a product passport/
      assert Event.where(kind: "passport_read_failed").exists?
    end
  end

  # A passport that was ended and one that never existed both answer 404, and
  # "the service refused it (HTTP 404)" says neither.
  test "nothing under that identifier gets its own sentence" do
    with_open_vault do
      create_and_unlock
      configured

      missing = DppService::Client::Result.new(ok: false, http_status: 404, problems: [ "Couldn't find Dpp" ])
      reading(by_product_id: ->(**) { missing }) { get lookup_path, params: { identifier: PRODUCT } }

      assert_select ".flash.alert", text: I18n.t("lookup.not_found")
    end
  end

  test "an unreachable service is said rather than raised" do
    with_open_vault do
      create_and_unlock
      configured

      reading(by_product_id: ->(**) { raise DppService::Client::Error, "timeout" }) do
        get lookup_path, params: { identifier: PRODUCT }
      end

      assert_response :success
      assert_select ".flash.alert", text: /#{Regexp.escape(I18n.t('passports.submit.reasons.timeout'))}/
    end
  end

  test "without a service a product identifier has nowhere to be looked up, and a DID still works" do
    with_open_vault do
      create_and_unlock

      reading { get lookup_path, params: { identifier: PRODUCT } }
      assert_select ".flash.alert", text: I18n.t("lookup.no_service")

      reading(endpoint: ->(_did) { "https://custodian.example/x" }, read: ->(_url) { found(DOCUMENT) }) do
        get lookup_path, params: { identifier: DID }
      end
      assert_select ".elements .eid", text: "ModelIdentifier"
    end
  end

  # The document is shown even when nothing in this vault can read it. A screen
  # that showed only the application's own reading would hide whatever the
  # reading has no field for.
  test "a passport no product type here can read is still shown in full" do
    with_open_vault do
      create_and_unlock
      configured

      reading(by_product_id: ->(**) { found(DOCUMENT) }) { get lookup_path, params: { identifier: PRODUCT } }

      assert_select ".elements .eid", text: "ModelIdentifier"
      assert_select "p.hint", text: I18n.t("lookup.no_reader")
    end
  end

  test "a type that carries the reading transformation shows the passport as answers" do
    with_open_vault do
      create_and_unlock
      configured
      readable_type

      reading(by_product_id: ->(**) { found(DOCUMENT) },
              answers: ->(*) { { "modelIdentifier" => "LUM-A60", "usefulLuminousFlux" => 806 } }) do
        get lookup_path, params: { identifier: PRODUCT }
      end

      assert_select "dt", text: "Model", count: 1
      assert_select "dd", text: "LUM-A60"
      assert_select "form[action=?]", lookup_draft_path
    end
  end

  # The point of the whole screen: a component's passport as the starting point
  # for one's own. And the one thing that must not travel with it.
  test "a draft made from a foreign passport takes its answers and not its identifier" do
    with_open_vault do
      create_and_unlock
      configured
      type = readable_type

      reading(by_product_id: ->(**) { found(DOCUMENT) },
              answers: ->(*) { { "modelIdentifier" => "LUM-A60", "productDesignation" => "Lumina A60" } }) do
        post lookup_draft_path, params: { identifier: PRODUCT, product_type_id: type.id }
      end

      passport = Passport.last
      assert_redirected_to edit_passport_path(passport)
      assert_equal type, passport.product_type
      assert_equal "LUM-A60", passport.values["modelIdentifier"]
      assert passport.unique_product_identifier.blank?,
        "the identifier names somebody else's product and must not be copied"
      assert_not passport.minted?
      assert_equal "draft", passport.status
      assert_match "Lumina A60", passport.label
    end
  end

  test "a draft is refused when the passport holds nothing this type can read" do
    with_open_vault do
      create_and_unlock
      configured
      type = readable_type

      assert_no_difference -> { Passport.count } do
        reading(by_product_id: ->(**) { found(DOCUMENT) }, answers: ->(*) { {} }) do
          post lookup_draft_path, params: { identifier: PRODUCT, product_type_id: type.id }
        end
      end

      assert_equal I18n.t("lookup.draft.nothing_readable"), flash[:alert]
    end
  end

  # Reading is the one thing this application does that needs no identity, and
  # that has to stay true — a token issued here would be a claim nobody asked for.
  test "reading asks for nothing to be signed" do
    with_open_vault do
      create_and_unlock
      configured
      assert_nil Identity.current

      tokens = 0
      stubbing(Did::Token, :issue, ->(*, **) { tokens += 1; "token" }) do
        reading(by_product_id: ->(**) { found(DOCUMENT) }) { get lookup_path, params: { identifier: PRODUCT } }
      end

      assert_equal 0, tokens
      assert_response :success
    end
  end

  test "an answer that is not a passport document is refused" do
    with_open_vault do
      create_and_unlock
      configured

      reading(by_product_id: ->(**) { found({ "hello" => "world" }) }) do
        get lookup_path, params: { identifier: PRODUCT }
      end

      assert_select ".flash.alert", text: I18n.t("lookup.not_a_passport")
    end
  end

  private

  def configured
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE)
  end

  def readable_type
    ProductType.create!(
      label: "Lamp", structure_name: "DppLedLamp", repo_base_url: "https://soya.example",
      jsonld: '{"@graph":[]}',
      forms: { "en" => {
        "schema" => { "properties" => { "modelIdentifier" => { "type" => "string" } } },
        "ui" => { "type" => "VerticalLayout", "elements" => [
          { "type" => "Control", "scope" => "#/properties/modelIdentifier", "label" => "Model" }
        ] }
      } }.to_json,
      fetched_at: Time.current,
      transformation_name: "DppLedLampToEN18223",
      transformation_jsonld: '{"@graph":[]}', transformation_fetched_at: Time.current,
      reverse_transformation_name: "DppLedLampFromEN18223",
      reverse_transformation_jsonld: '{"@graph":[]}', reverse_transformation_fetched_at: Time.current
    )
  end

  def found(document)
    DppService::Client::Result.new(ok: true, http_status: 200, problems: [], document: document)
  end

  def reading(by_product_id: ->(**) { found(DOCUMENT) },
              read: ->(_url) { found(DOCUMENT) },
              endpoint: ->(_did) { "https://custodian.example/x" },
              answers: nil, &block)
    stubbing(DppService::Client, :read_by_product_id, by_product_id) do
      stubbing(DppService::Client, :read, read) do
        stubbing(Did::Oyd, :passport_endpoint, endpoint) do
          if answers
            stubbing(Soya::WebCli, :transform, ->(_name, _data) { answers.call }, &block)
          else
            block.call
          end
        end
      end
    end
  end
end
