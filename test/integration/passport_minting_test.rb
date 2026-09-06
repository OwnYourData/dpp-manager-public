require "test_helper"

# Minting a passport's own DID.
#
# The registrar is stubbed throughout: what is under test is the rule set around
# the mint — what has to be true before it, what becomes unchangeable after it,
# and that the keys are written down in the same breath as the identifier. The
# oydid call itself is exercised against the real VDR elsewhere.
class PassportMintingTest < ActionDispatch::IntegrationTest
  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000123".freeze
  DID = "did:oyd:zQmPassportExampleIdentifier".freeze

  test "minting fixes the identifier, keeps both keys, and shows them once" do
    with_open_vault do
      create_and_unlock
      passport = ready_passport

      minting do
        post mint_passport_path(passport)
      end

      assert_redirected_to keys_passport_path(passport)
      passport.reload

      assert_equal DID, passport.dpp_id

      assert_equal "minted", passport.status
      assert passport.minted_at.present?
      assert_equal "https://dpp-service.example", passport.endpoint_base

      key = passport.passport_key
      assert_equal "doc-key", key.document_key
      assert_equal "rev-key", key.revocation_key
      assert_not key.secured?, "the keys have not been confirmed as stored yet"

      follow_redirect!
      assert_response :success
      assert_match "doc-key", response.body, "the document key is shown exactly once, and this is that once"
      assert_match "rev-key", response.body
    end
  end

  # The identifier goes inside the DID's serviceEndpoint. What that endpoint says
  # has to be byte for byte what the DPP Service would have built itself, escaping
  # included — the service compares the host, but a passport read by anyone else
  # is read by following the whole address.
  test "the endpoint is built the way the service builds it" do
    with_open_vault do
      create_and_unlock
      passport = ready_passport
      seen = {}

      stubbing(Did::Oyd, :mint_passport, ->(product_id, endpoint_base:) {
        seen = { product_id: product_id, endpoint_base: endpoint_base }
        minted_did
      }) do
        post mint_passport_path(passport)
      end

      assert_equal IDENTIFIER, seen[:product_id]
      assert_equal "https://dpp-service.example", seen[:endpoint_base]
      assert_equal "https://dpp-service.example/dpp/v1/dppsByProductId/" \
                   "#{CGI.escape(IDENTIFIER)}", passport.reload.service_endpoint
    end
  end

  # A custodian is where the passport actually lives when there is one, and the
  # service refuses a DID whose endpoint host is not the host it is submitted to.
  # So the choice has to be made from the same rule the service uses.
  test "a configured custodian is what the identifier points at" do
    with_open_vault do
      create_and_unlock
      Setting.current.update!(custodian_base_url: "https://pod.example", custodian_collection_id: "c1")
      passport = ready_passport
      seen = nil

      stubbing(Did::Oyd, :mint_passport, ->(_id, endpoint_base:) { seen = endpoint_base; minted_did }) do
        post mint_passport_path(passport)
      end

      assert_equal "https://pod.example", seen
    end
  end

  test "a passport without a finished envelope cannot be minted" do
    with_open_vault do
      create_and_unlock
      passport = Passport.create!(product_type: product_type, label: "Unfinished")

      minting do
        post mint_passport_path(passport)
      end

      assert_redirected_to edit_passport_path(passport)
      assert_nil passport.reload.dpp_id
    end
  end

  test "minting twice is refused rather than replacing the identifier" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      minting do
        post mint_passport_path(passport)
      end

      assert_redirected_to edit_passport_path(passport)
      assert_equal DID, passport.reload.dpp_id
      assert_equal 1, PassportKey.count
    end
  end

  # The whole reason the envelope has to be complete before minting: afterwards
  # the identifier is inside a published document, and a row that disagreed with
  # it would be refused by the service several steps later.
  test "the identifier and the granularity are frozen once the DID exists" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      passport.unique_product_identifier = "https://id.example.com/01/09520123456788"
      assert_not passport.valid?
      assert passport.errors[:unique_product_identifier].any?

      passport.reload
      passport.granularity = "model"
      assert_not passport.valid?
      assert passport.errors[:granularity].any?

      # And the page does not offer what the model will refuse: an editable
      # field whose every save is rejected is worse than no field.
      get edit_passport_path(passport)
      assert_response :success
      identifier_field = response.body[/<input[^>]*id="passport_unique_product_identifier"[^>]*>/]
      granularity_field = response.body[/<select[^>]*id="passport_granularity"[^>]*>/]
      assert_includes identifier_field.to_s, "readonly"
      assert_includes granularity_field.to_s, "disabled"
      assert_match passport.dpp_id, response.body
    end
  end

  test "the answers can still be edited after minting: only the envelope is fixed" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      stubbing(Soya::Validation, :check, ->(*) { nil }) do
        patch passport_path(passport), params: { passport: { label: "Renamed" }, answers: { watt: 9 }.to_json }
      end

      assert_redirected_to edit_passport_path(passport)
      passport.reload
      assert_equal "Renamed", passport.label
      assert_equal({ "watt" => 9 }, passport.values)
      assert_equal IDENTIFIER, passport.unique_product_identifier
    end
  end

  test "a minted passport is not deleted here, because its keys would go with it" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      delete passport_path(passport)

      assert_redirected_to edit_passport_path(passport)
      assert_equal 1, Passport.count
    end
  end

  test "confirming the keys stops them being shown, and it is recorded" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      post secure_keys_passport_path(passport), params: { confirmed: "1" }
      assert_redirected_to edit_passport_path(passport)
      assert passport.reload.keys_secured?

      get keys_passport_path(passport)
      assert_response :success
      assert_no_match "doc-key", response.body, "a confirmed key must not come back on the page"
      assert_match passport.dpp_id, response.body

      assert Event.where(kind: "passport_keys_secured").exists?
      assert_nil Event.verify_chain
    end
  end

  test "the keys are not confirmed by opening the page, only by saying so" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      post secure_keys_passport_path(passport)

      assert_redirected_to keys_passport_path(passport)
      assert_not passport.reload.keys_secured?
    end
  end

  test "the key file is written next to the vault, once, and carries the endpoint" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      post export_keys_passport_path(passport)
      assert_redirected_to keys_passport_path(passport)

      filename = "passport-#{passport.short_dpp_id}-keys.json"
      path = Vault::Store.data_dir.join(filename)
      assert path.exist?
      assert_equal 0o600, path.stat.mode & 0o777

      written = JSON.parse(path.read)
      assert_equal DID, written["did"]
      assert_equal "doc-key", written["documentKey"]
      assert_equal passport.service_endpoint, written["serviceEndpoint"]

      # A second export would silently overwrite a file the operator may have
      # already put somewhere; it refuses instead.
      post export_keys_passport_path(passport)
      assert_equal flash[:alert].present?, true
    end
  end

  # A registrar that is unreachable must leave nothing behind: no half-minted
  # passport, and no key row for a DID that does not exist.
  test "a failed mint leaves the passport exactly as it was" do
    with_open_vault do
      create_and_unlock
      passport = ready_passport

      stubbing(Did::Oyd, :mint_passport, ->(*, **) { raise Did::Oyd::Error, "the registry did not answer" }) do
        post mint_passport_path(passport)
      end

      assert_redirected_to edit_passport_path(passport)
      passport.reload
      assert_nil passport.dpp_id
      assert_equal "draft", passport.status
      assert_equal 0, PassportKey.count
      assert Event.where(kind: "passport_mint_failed").exists?
    end
  end

  private

  def product_type
    @product_type ||= ProductType.create!(
      label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example",
      jsonld: '{"@graph":[]}', forms: { "en" => { "schema" => { "properties" => {} }, "ui" => {} } }.to_json,
      fetched_at: Time.current
    )
  end

  def ready_passport
    Setting.current.update!(service_base_url: "https://dpp-service.example",
                            service_audience: "https://dpp-service.example")
    Passport.create!(product_type: product_type, label: "Batch A",
                     unique_product_identifier: IDENTIFIER, granularity: "item")
  end

  def minted_passport
    passport = ready_passport
    minting { post mint_passport_path(passport) }
    passport.reload
  end

  def minted_did
    { did: DID, document_key: "doc-key", revocation_key: "rev-key", revocation_log: "[]" }
  end

  def minting(&block) = stubbing(Did::Oyd, :mint_passport, ->(*, **) { minted_did }, &block)
end
