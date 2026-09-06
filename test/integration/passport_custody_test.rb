require "test_helper"

# Handing a passport to a custodian.
#
# The mandate is the only thing in this application that grants somebody else
# authority, so what these tests are about is its boundaries: it names one
# passport, one custodian and one service, it is recorded only once the service
# has accepted it, and a passport that is not going to a custodian gets none.
class PassportCustodyTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  SERVICE_DID = "did:oyd:zQmServiceabcdefghij".freeze
  POD = "https://pod.example".freeze
  OTHER_POD = "https://other.example".freeze
  COLLECTION = "7".freeze
  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000123".freeze

  test "a custodial passport is submitted with a mandate for exactly this passport" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      header = nil
      submitting(create: ->(_document, base_url:, token:, storage: nil) {
        header = storage
        accepted
      }) { post submit_passport_path(passport) }

      assert_equal POD, header[:base_url]
      assert_equal COLLECTION, header[:collection_id]

      claims = Did::Delegation.peek(header[:delegation])
      assert_equal Identity.current.did, claims["iss"]
      assert_equal SERVICE_DID, claims["sub"], "only the service named in it can redeem it"
      assert_equal POD, claims["aud"]
      assert_equal COLLECTION, claims["collection"]
      assert_equal IDENTIFIER, claims["product_id"], "one mandate, one passport"
      assert_equal %w[create update delete], claims["act"]
    end
  end

  # The button is the only way to reach the action, so a page that withholds it
  # refuses the passport in silence — the logic above would have accepted it.
  # The comparison on the page has to be the same one the action makes: against
  # the custodian the passport was minted for, not against the service it is
  # handed to.
  test "a custodial passport minted at its custodian is offered the button" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      get edit_passport_path(passport)
      assert_response :success
      assert_select "form[action=?]", submit_passport_path(passport)
      assert_select "p.warning-inline", text: /#{Regexp.escape(POD)}/, count: 0
    end
  end

  # And the other way round, which is what that comparison is for: the custodian
  # was changed in the settings after this passport's identifier had been frozen
  # to name the old one.
  test "a custodial passport whose custodian changed after minting is refused the button" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      Setting.current.update!(custodian_base_url: OTHER_POD)

      get edit_passport_path(passport)
      assert_select "form[action=?]", submit_passport_path(passport), count: 0
      assert_select "p.warning-inline", text: /#{Regexp.escape(OTHER_POD)}/
    end
  end

  test "what was signed is recorded, so the operator can be reminded before it runs out" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      sent = nil
      submitting(create: ->(*, storage: nil, **) { sent = storage; accepted }) do
        post submit_passport_path(passport)
      end

      passport.reload
      assert passport.delegated?
      assert_equal Did::Delegation.peek(sent[:delegation])["jti"], passport.delegation_jti
      assert_equal "create,update,delete", passport.delegation_act
      assert_in_delta 90.days.from_now, passport.delegation_expires_at, 60
      assert Event.where(kind: "passport_delegated").exists?
    end
  end

  # The mandate is authority. Recording one the service never accepted would
  # leave this installation believing a passport is provided for when nobody is
  # holding it.
  test "a refused submission records no mandate" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      refusal = DppService::Client::Result.new(ok: false, http_status: 403, problems: [ "no such collection" ])
      submitting(create: ->(*, **) { refusal }) { post submit_passport_path(passport) }

      passport.reload
      assert_not passport.delegated?
      assert_not passport.submitted?
    end
  end

  test "a passport kept in the service's own database is submitted without a mandate" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(custodian: false)

      header = :unset
      submitting(create: ->(*, storage: nil, **) { header = storage; accepted }) do
        post submit_passport_path(passport)
      end

      assert_nil header, "there is no custodian, so there is nobody to grant anything to"
      assert passport.reload.submitted?
      assert_not passport.delegated?

      get edit_passport_path(passport)
      assert_select "h2", { text: I18n.t("passports.custody.title"), count: 0 }
    end
  end

  # The service publishes the DID a mandate has to name. Without it the mandate
  # would name nobody, and the custodian refuses one whose `sub` is not the
  # service presenting it — so this is caught before anything is signed.
  test "a service that publishes no identifier cannot be delegated to" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      Setting.current.update!(service_did: nil)

      calls = 0
      submitting(create: ->(*, **) { calls += 1; accepted }) { post submit_passport_path(passport) }

      assert_equal 0, calls
      assert_match SERVICE, flash[:alert]
      assert_not passport.reload.submitted?
    end
  end

  # The service compares the passport's DID endpoint with the custodian, not
  # with itself, and cannot repair a mismatch afterwards — it holds no key for a
  # DID it did not mint.
  test "a passport whose identifier points at the service is not sent to a custodian" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(custodian: false)
      Setting.current.update!(custodian_base_url: POD, custodian_collection_id: COLLECTION)
      passport.update_columns(custodian_collection_id: COLLECTION)

      submitting { post submit_passport_path(passport) }

      assert_match "dpp-service.example", flash[:alert].to_s
      assert_match POD, flash[:alert].to_s
      assert_not passport.reload.submitted?
    end
  end

  test "renewing signs a fresh mandate and records it only once the service takes it" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      first = passport.delegation_jti

      sent = nil
      renewing(renew: ->(base_url:, dpp_id:, token:, storage:) { sent = storage; no_content }) do
        post renew_delegation_passport_path(passport)
      end

      passport.reload
      assert_not_equal first, passport.delegation_jti, "a fresh mandate has a handle of its own"
      assert_equal Did::Delegation.peek(sent[:delegation])["jti"], passport.delegation_jti
      assert Event.where(kind: "passport_delegation_renewed").exists?
    end
  end

  test "a refused renewal leaves the mandate that is in place alone" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      before = passport.delegation_jti

      refusal = DppService::Client::Result.new(ok: false, http_status: 400, problems: [ "exp is not later" ])
      renewing(renew: ->(**) { refusal }) { post renew_delegation_passport_path(passport) }

      assert_equal before, passport.reload.delegation_jti
      assert_match "exp is not later", flash[:alert]
      assert Event.where(kind: "passport_delegation_failed").exists?
    end
  end

  test "comparing says whether the service holds what was signed here" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      held = { "jti" => passport.delegation_jti, "exp" => passport.delegation_expires_at.to_i,
               "act" => %w[create update delete], "collection" => COLLECTION, "base_url" => POD }
      renewing(read: ->(**) { found(held) }) { post check_delegation_passport_path(passport) }

      assert_match "holds the mandate you signed", flash[:notice]
      assert Event.where(kind: "passport_delegation_checked").exists?
    end
  end

  # The drift this whole comparison exists for: a restore from an older backup
  # on either side, and nothing to notice it by.
  test "a service holding a different mandate is said plainly" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      held = { "jti" => "somethingelse", "exp" => 2.days.from_now.to_i, "act" => %w[create],
               "collection" => COLLECTION, "base_url" => POD }
      renewing(read: ->(**) { found(held) }) { post check_delegation_passport_path(passport) }

      assert_match "somethingelse", flash[:notice]
    end
  end

  test "a service holding nothing readable is said as that" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      held = { "jti" => nil, "exp" => nil, "act" => nil, "collection" => nil, "base_url" => nil }
      renewing(read: ->(**) { found(held) }) { post check_delegation_passport_path(passport) }

      assert_equal I18n.t("passports.custody.service_holds_nothing"), flash[:notice]
    end
  end

  # A service that has no such route answers a bare 404 — no Result object, no
  # sentence. Reporting that as "the service refused it (HTTP 404): HTTP 404"
  # tells the operator their mandate is in trouble, which it is not: there is
  # simply nobody to ask, and what is recorded here still stands.
  test "a service that cannot be asked about the mandate is not reported as a refusal" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      signed = passport.delegation_jti

      absent = DppService::Client::Result.new(ok: false, http_status: 404, problems: [ "HTTP 404" ])
      renewing(read: ->(**) { absent }) { post check_delegation_passport_path(passport) }

      assert_equal I18n.t("passports.custody.check_unsupported", service: SERVICE), flash[:alert]
      assert_equal signed, passport.reload.delegation_jti, "asking changes nothing"
      assert_not Event.where(kind: "passport_delegation_checked").exists?
    end
  end

  # And the other 404, which does carry a sentence: that one is the service
  # answering the question, and it must reach the operator unchanged.
  test "a service saying why it has no mandate says exactly that" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      refusal = DppService::Client::Result.new(ok: false, http_status: 404,
                                               problems: [ "This passport is not held by a custodian" ])
      renewing(read: ->(**) { refusal }) { post check_delegation_passport_path(passport) }

      assert_match "not held by a custodian", flash[:alert]
    end
  end

  test "a passport in the service's own database has no mandate to renew or compare" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(custodian: false)
      submitting { post submit_passport_path(passport) }

      renewing { post renew_delegation_passport_path(passport) }
      assert_equal I18n.t("passports.custody.not_custodial"), flash[:alert]

      renewing { post check_delegation_passport_path(passport) }
      assert_equal I18n.t("passports.custody.not_custodial"), flash[:alert]
    end
  end

  # An expired mandate is not a catastrophe — it is one signature away from
  # working — but it has to be visible before somebody discovers it while trying
  # to end a passport.
  test "the page says when a mandate has run out and when it is about to" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      passport.update_columns(delegation_expires_at: 3.days.from_now)
      get edit_passport_path(passport)
      assert_select ".warning-inline", text: /#{Regexp.escape(I18n.t('passports.custody.expiring', days: 3))}/

      passport.update_columns(delegation_expires_at: 1.day.ago)
      get edit_passport_path(passport)
      assert_select ".warning-inline", text: I18n.t("passports.custody.expired")
      assert passport.reload.delegation_expired?
    end
  end

  # --- handing the passport to another custodian --------------------------------

  # The exit, and what the whole mandate construction is for: leaving is a
  # signature, not a negotiation.
  test "a handover signs a mandate for the new custodian and then moves the identifier" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      before = passport.delegation_jti

      sent = nil
      order = []
      moving(move: ->(base_url:, dpp_id:, token:, storage:, release_previous:) {
               order << :move
               sent = { storage: storage, release: release_previous }
               moved
             },
             endpoint: ->(*, **) { order << :endpoint; { did: "did:oyd:zQmNew", revocation_log: "[]" } }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: OTHER_POD, custodian_collection_id: "9" }
      end

      assert_equal [ :move, :endpoint ], order,
        "the document moves first; the identifier may only name a host that already has it"

      claims = Did::Delegation.peek(sent[:storage][:delegation])
      assert_equal OTHER_POD, claims["aud"], "the mandate is for the new custodian, not the old one"
      assert_equal "9", claims["collection"]
      assert_equal passport.unique_product_identifier, claims["product_id"]
      assert_equal false, sent[:release], "the overlap is what keeps the passport readable throughout"

      passport.reload
      assert_equal OTHER_POD, passport.endpoint_base
      assert_equal "9", passport.custodian_collection_id
      assert_not passport.move_unfinished?
      assert_not_equal before, passport.delegation_jti
      assert Event.where(kind: "passport_custody_moved").exists?
      assert Event.where(kind: "passport_endpoint_moved").exists?
    end
  end

  test "the operator can end the overlap in the same act" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      released = nil
      moving(move: ->(release_previous:, **) { released = release_previous; moved }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: OTHER_POD, custodian_collection_id: "9", release_previous: "1" }
      end

      assert_equal true, released
    end
  end

  # The identifier is what the world holds. Moving it before the document has
  # arrived would send every reader to a host that answers 404.
  test "a refused handover leaves the passport where it is" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      before = passport.delegation_jti

      refusal = DppService::Client::Result.new(ok: false, http_status: 400, problems: [ "pod not reachable" ])
      endpoints = 0
      moving(move: ->(**) { refusal }, endpoint: ->(*, **) { endpoints += 1; {} }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: OTHER_POD, custodian_collection_id: "9" }
      end

      assert_equal 0, endpoints
      passport.reload
      assert_equal POD, passport.endpoint_base
      assert_equal COLLECTION, passport.custodian_collection_id
      assert_equal before, passport.delegation_jti
      assert Event.where(kind: "passport_custody_move_failed").exists?
    end
  end

  # The half a reader would notice: the document is at the new custodian and the
  # identifier still names the old one.
  test "an identifier that could not be moved leaves the handover finishable" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      moving(endpoint: ->(*, **) { raise Did::Oyd::Error, "the registry did not answer" }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: OTHER_POD, custodian_collection_id: "9" }
      end

      passport.reload
      assert passport.move_unfinished?
      assert_equal OTHER_POD, passport.pending_endpoint_base
      assert_equal POD, passport.endpoint_base, "the identifier still says the old custodian"
      assert_match "the registry did not answer", flash[:alert]
      assert Event.where(kind: "passport_endpoint_move_failed").exists?

      get edit_passport_path(passport)
      assert_select ".warning-inline", text: /#{Regexp.escape(OTHER_POD)}/

      moving { post finish_move_passport_path(passport) }

      passport.reload
      assert_not passport.move_unfinished?
      assert_equal OTHER_POD, passport.endpoint_base
    end
  end

  # Another collection at the same custodian is a move of the document and not
  # of the identifier: the endpoint already names that host.
  test "moving to another collection at the same custodian leaves the registry alone" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      writes = 0
      moving(endpoint: ->(*, **) { writes += 1; {} }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: POD, custodian_collection_id: "9" }
      end

      assert_equal 0, writes, "the endpoint is unchanged, so there is nothing to publish"
      passport.reload
      assert_equal "9", passport.custodian_collection_id
      assert_equal POD, passport.endpoint_base
      assert_not passport.move_unfinished?
    end
  end

  test "a second handover is refused while the first one is unfinished" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      moving(endpoint: ->(*, **) { raise Did::Oyd::Error, "later" }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: OTHER_POD, custodian_collection_id: "9" }
      end

      moves = 0
      moving(move: ->(**) { moves += 1; moved }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: "https://third.example", custodian_collection_id: "3" }
      end

      assert_equal 0, moves
      assert_equal I18n.t("passports.custody.finish_first"), flash[:alert]
    end
  end

  test "the new revocation log replaces the old one, or the passport could never be ended" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      moving(endpoint: ->(*, **) { { did: "did:oyd:zQmNew", revocation_log: '["fresh"]' } }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: OTHER_POD, custodian_collection_id: "9" }
      end

      assert_equal '["fresh"]', passport.reload.passport_key.revocation_log,
        "an update commits to the current document; the previous log would no longer revoke it"
    end
  end

  test "a handover to where the passport already is, or to nowhere, is refused" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      moves = 0
      moving(move: ->(**) { moves += 1; moved }) do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: POD, custodian_collection_id: COLLECTION }
        assert_equal I18n.t("passports.custody.already_there"), flash[:alert]

        post move_custody_passport_path(passport),
             params: { custodian_base_url: "not a url at all", custodian_collection_id: "9" }
        assert flash[:alert].present?

        post move_custody_passport_path(passport),
             params: { custodian_base_url: OTHER_POD, custodian_collection_id: "" }
        assert flash[:alert].present?
      end

      assert_equal 0, moves
    end
  end

  test "a passport in the service's own database has no custodian to move it away from" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(custodian: false)
      submitting { post submit_passport_path(passport) }

      moving do
        post move_custody_passport_path(passport),
             params: { custodian_base_url: OTHER_POD, custodian_collection_id: "9" }
      end

      assert_equal I18n.t("passports.custody.not_custodial"), flash[:alert]
    end
  end

  # The failure this saves the operator from: the service would try, the pod
  # would refuse with an OAuth code, and the message would be about a grant.
  test "an expired mandate stops a correction and an ending before they are attempted" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.update_columns(delegation_expires_at: 1.day.ago,
                              submitted_digest: "somethingelse")

      calls = 0
      stubbing(DppService::Client, :update, ->(*, **) { calls += 1; no_content }) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }) { post correct_passport_path(passport) }
      end
      assert_equal 0, calls
      assert_equal I18n.t("passports.custody.expired_first"), flash[:alert]

      stubbing(DppService::Client, :delete, ->(**) { calls += 1; no_content }) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }) { post retire_passport_path(passport) }
      end
      assert_equal 0, calls, "the pod would refuse it, and the message would be about a grant"
      assert_equal I18n.t("passports.custody.expired_first"), flash[:alert]
    end
  end

  # Nobody opens every passport to check a date, so the ones that need a
  # signature have to come to the operator rather than wait to be found.
  test "the overview names the mandates that need signing" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.update_columns(delegation_expires_at: 5.days.from_now)

      get root_path
      assert_select ".warning a", text: passport.label

      passport.update_columns(delegation_expires_at: 60.days.from_now)
      get root_path
      assert_select ".warning a", { text: passport.label, count: 0 },
        "a panel that is always there is a panel nobody reads"
    end
  end

  private

  def product_type
    @product_type ||= ProductType.create!(
      label: "Lamp", structure_name: "DppLedLamp", repo_base_url: "https://soya.example",
      jsonld: '{"@graph":[]}',
      forms: { "en" => { "schema" => { "properties" => { "watt" => { "type" => "integer" } } }, "ui" => {} } }.to_json,
      fetched_at: Time.current,
      transformation_name: "DppLedLampToEN18223",
      transformation_jsonld: '{"@graph":[]}', transformation_fetched_at: Time.current
    )
  end

  # A real key, because the mandate is signed for real: what these tests would
  # otherwise be checking is a stub's idea of a signature.
  def identity
    Identity.first || begin
      require "oydid"
      require "ed25519"
      key = Ed25519::SigningKey.generate
      encoded = Oydid.multi_encode([ 0, 19, 32 ].pack("C*") + key.to_bytes, { encode: "base58btc" }).first
      Identity.create!(did: "did:oyd:zQmXperatorabcdefghij", origin: "minted", document_key: encoded)
    end
  end

  def minted_passport(custodian: true)
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE, service_did: SERVICE_DID,
                            custodian_base_url: (POD if custodian),
                            custodian_collection_id: (COLLECTION if custodian))
    identity
    passport = Passport.create!(product_type: product_type, label: "Batch A", data: '{"watt":9}',
                                unique_product_identifier: IDENTIFIER, granularity: "item")

    stubbing(Did::Oyd, :mint_passport, ->(*, **) {
      { did: "did:oyd:zQmPassport#{passport.id}", document_key: "doc", revocation_key: "rev", revocation_log: "[]" }
    }) { post mint_passport_path(passport) }

    passport.reload
  end

  def submitted_passport
    passport = minted_passport
    submitting { post submit_passport_path(passport) }
    passport.reload
  end

  def accepted
    DppService::Client::Result.new(ok: true, http_status: 201, problems: [], document: { "dppStatus" => "Active" })
  end

  def no_content
    DppService::Client::Result.new(ok: true, http_status: 204, problems: [], document: nil)
  end

  def found(document)
    DppService::Client::Result.new(ok: true, http_status: 200, problems: [], document: document)
  end

  def submitting(create: ->(*, **) { accepted }, &block)
    stubbing(Soya::WebCli, :transform, ->(*) { [] }) do
      stubbing(DppService::Client, :create, create) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
      end
    end
  end

  def moved
    DppService::Client::Result.new(ok: true, http_status: 200, problems: [],
                                   document: { "dppStatus" => "Active" })
  end

  def moving(move: ->(**) { moved },
             endpoint: ->(*, **) { { did: "did:oyd:zQmNew", revocation_log: "[]" } }, &block)
    stubbing(DppService::Client, :move_custody, move) do
      stubbing(Did::Oyd, :move_endpoint, endpoint) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
      end
    end
  end

  def renewing(renew: ->(**) { no_content }, read: ->(**) { found({}) }, &block)
    stubbing(DppService::Client, :renew_delegation, renew) do
      stubbing(DppService::Client, :read_delegation, read) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
      end
    end
  end
end
