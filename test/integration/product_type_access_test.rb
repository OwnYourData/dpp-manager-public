require "test_helper"
require "open3"
require "tempfile"

# Setting the access class of each field of a product type, switching the
# access policy on, and registering it with the DPP Service.
class ProductTypeAccessTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  DID = "did:oyd:zQmWxYzabcdefgh".freeze

  test "the page lists every element with its field, starting from the structure's suggestions" do
    with_open_vault do
      create_and_unlock
      type = lamp

      with_transformation { get product_type_access_path(type) }

      assert_response :success
      assert_select "table.access tbody tr", 24
      assert_select "select[name=?] option[selected][value=?]", "classes[ProductIdentification/SerialNumber]",
                    "legitimateInterest"
      assert_select "select[name=?] option[selected][value=?]", "classes[ProductIdentification/BrandName]", "public"
      assert_select "input[type=checkbox][name=enabled]:not([checked])"
    end
  end

  test "the traced paths are kept and asked for again only when the transformation changes" do
    with_open_vault do
      create_and_unlock
      type = lamp
      runs = 0
      counting = ->(name, answers) { runs += 1; jq_transform(name, answers) }

      stubbing(Soya::WebCli, :transform, counting) do
        get product_type_access_path(type)
        get product_type_access_path(type)
      end
      first = runs
      assert first.positive?

      type.update!(transformation_fetched_at: 1.minute.from_now)
      stubbing(Soya::WebCli, :transform, counting) { get product_type_access_path(type) }

      assert_equal first * 2, runs
    end
  end

  test "switching it on without a service stores version 1 and registers nothing" do
    with_open_vault do
      create_and_unlock
      type = lamp
      called = false

      with_transformation do
        stubbing(DppService::Client, :register_access_policy, ->(*, **) { called = true; registered }) do
          patch product_type_access_path(type), params: { enabled: "1",
                                                          classes: { "EnergyPerformance/OnModePower" => "authority" } }
        end
      end

      type.reload
      assert type.access_policy_enabled?
      assert_equal 1, type.access_policy_version
      assert_equal "authority", type.access_classes_hash["EnergyPerformance/OnModePower"]
      assert_equal "legitimateInterest", type.access_classes_hash["ProductIdentification/SerialNumber"],
        "a row the operator did not touch keeps its suggestion"
      assert_not called
      assert Event.where(kind: "product_type_access_changed").exists?
    end
  end

  test "with a service the policy is registered right away, under the operator's DID" do
    with_open_vault do
      create_and_unlock
      configure_service
      type = lamp
      sent = nil

      with_transformation do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }) do
          stubbing(DppService::Client, :register_access_policy, lambda { |policy, base_url:, token:|
            sent = { policy: policy, base_url: base_url, token: token }
            registered(201)
          }) do
            patch product_type_access_path(type), params: { enabled: "1", classes: {} }
          end
        end
      end

      assert_equal "#{DID}/access-policies/DppLedLamp/1", sent[:policy]["id"]
      assert_equal Dpp::AccessPolicy::SCHEME, sent[:policy]["scheme"]
      assert_equal 24, sent[:policy]["rules"].size
      assert_equal SERVICE, sent[:base_url]
      assert type.reload.access_policy_registered_at?(SERVICE, DID)
      assert Event.where(kind: "access_policy_registered").exists?
      assert_match SERVICE, flash[:notice]
    end
  end

  test "saving the same classes again keeps the version; a change is the next one" do
    with_open_vault do
      create_and_unlock
      type = lamp

      with_transformation do
        patch product_type_access_path(type), params: { enabled: "1", classes: {} }
        patch product_type_access_path(type), params: { enabled: "1", classes: {} }
        assert_equal 1, type.reload.access_policy_version

        patch product_type_access_path(type), params: { enabled: "1",
                                                        classes: { "Durability/RatedLifetime" => "legitimateInterest" } }
        assert_equal 2, type.reload.access_policy_version
      end
    end
  end

  # The id of version 1 is taken at the service by other rules: a restored
  # backup, a second installation with the same identity. The rules here count.
  test "a conflict at the service moves the policy to the next version" do
    with_open_vault do
      create_and_unlock
      configure_service
      type = lamp
      ids = []
      answers = [ registered(409), registered(201) ]

      with_transformation do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }) do
          stubbing(DppService::Client, :register_access_policy, ->(policy, **) { ids << policy["id"]; answers.shift }) do
            patch product_type_access_path(type), params: { enabled: "1", classes: {} }
          end
        end
      end

      assert_equal [ "#{DID}/access-policies/DppLedLamp/1", "#{DID}/access-policies/DppLedLamp/2" ], ids
      assert_equal 2, type.reload.access_policy_version
      assert_equal ids.last, type.access_policy_registered_id
    end
  end

  test "a refusal by the service is shown with its own words, and the classes stay saved" do
    with_open_vault do
      create_and_unlock
      configure_service
      type = lamp
      refusal = DppService::Client::Result.new(ok: false, http_status: 400, problems: [ "rule on a header attribute" ])

      with_transformation do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }) do
          stubbing(DppService::Client, :register_access_policy, ->(*, **) { refusal }) do
            patch product_type_access_path(type), params: { enabled: "1", classes: {} }
          end
        end
      end

      assert type.reload.access_policy_enabled?
      assert_nil type.access_policy_registered_id
      assert_match "rule on a header attribute", flash[:alert]
    end
  end

  test "a class that is not one of the vocabulary, or a path the type does not have, is ignored" do
    with_open_vault do
      create_and_unlock
      type = lamp

      with_transformation do
        patch product_type_access_path(type), params: { enabled: "1", classes: {
          "ProductIdentification/BrandName" => "secret", "Nowhere/Else" => "authority"
        } }
      end

      classes = type.reload.access_classes_hash
      assert_equal "public", classes["ProductIdentification/BrandName"]
      assert_not classes.key?("Nowhere/Else")
    end
  end

  test "it cannot be switched off once passports are classified by it" do
    with_open_vault do
      create_and_unlock
      type = lamp
      with_transformation { patch product_type_access_path(type), params: { enabled: "1", classes: {} } }
      Passport.create!(product_type: type, label: "A", access_policy_id: "#{DID}/access-policies/DppLedLamp/1")

      with_transformation { patch product_type_access_path(type), params: { enabled: "0", classes: {} } }

      assert type.reload.access_policy_enabled?
      assert_equal I18n.t("product_type_access.cannot_switch_off"), flash[:alert]
    end
  end

  test "a type without a transformation says why there is nothing to classify" do
    with_open_vault do
      create_and_unlock
      type = lamp
      type.update_columns(transformation_fetched_at: nil, transformation_jsonld: nil)

      get product_type_access_path(type)

      assert_response :success
      assert_match I18n.t("product_type_access.reasons.transformation_not_fetched"), response.body
    end
  end

  test "the list of product types links to the page and says when the classes are on" do
    with_open_vault do
      create_and_unlock
      type = lamp
      type.update_columns(access_policy_enabled: true, access_policy_version: 3)

      stubbing(Soya::WebCli, :version, -> { { "version" => "test" } }) { get product_types_path }

      assert_select "a[href=?]", product_type_access_path(type)
      assert_match I18n.t("product_types.state.access_on", version: 3), response.body
    end
  end

  private

  def lamp
    ProductType.create!(
      label: "LED lamp", structure_name: "DppLedLamp", repo_base_url: "https://soya.example",
      jsonld: Rails.root.join("soya/DppLedLamp.jsonld").read, fetched_at: Time.current,
      transformation_name: "DppLedLampToEN18223",
      transformation_jsonld: Rails.root.join("soya/DppLedLampToEN18223.jsonld").read,
      transformation_fetched_at: Time.current
    )
  end

  def configure_service
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE)
    Identity.first || Identity.create!(did: DID, origin: "minted", document_key: "k")
  end

  def registered(status = 201)
    DppService::Client::Result.new(ok: status < 300, http_status: status, problems: status < 300 ? [] : [ "conflict" ],
                                   document: {})
  end

  # soya-web-cli, replaced by jq over the authored transformation.
  def with_transformation(&block)
    stubbing(Soya::WebCli, :transform, ->(name, answers) { jq_transform(name, answers) }, &block)
  end

  def jq_transform(_name, answers)
    programme = YAML.safe_load_file(Rails.root.join("soya/DppLedLampToEN18223.yaml"))
                    .dig("content", "overlays", 0, "value")
    Tempfile.create([ "lamp", ".jq" ]) do |file|
      file.write(programme)
      file.flush
      out, err, status = Open3.capture3("jq", "-f", file.path, stdin_data: JSON.generate(answers))
      flunk("jq failed: #{err}") unless status.success?
      JSON.parse(out)
    end
  end
end
