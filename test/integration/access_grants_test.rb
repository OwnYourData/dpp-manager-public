require "test_helper"

# Granting, comparing and revoking access rights on the page "Access rights".
#
# The service is stubbed at the client seam; what is tested is what this
# application sends, what it keeps, and what it refuses before anything leaves.
class AccessGrantsTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  SERVICE_DID = "did:oyd:zQmServiceabcdefghijklmnopqrstuvwxyz012345".freeze
  READER = "did:oyd:zQmReaderabcdefghijklmnopqrstuvwxyz0123456".freeze

  test "opening the page asks nobody anything" do
    with_open_vault do
      create_and_unlock
      configure
      grant_record

      offline do
        get access_grants_path
      end

      assert_response :success
      assert_select "table.grants tbody tr", 1
      assert_select "form[action=?]", sync_access_grants_path
      assert_match I18n.t("access_grants.authority.unknown"), response.body
    end
  end

  test "a legitimate interest is signed, registered and kept" do
    with_open_vault do
      create_and_unlock
      configure
      passport = submitted_passport
      sent = nil

      services(register: ->(grant, base_url:, token:) { sent = { grant: grant, base_url: base_url }; registered }) do
        post access_grants_path, params: { subject_did: READER, subject_label: "Werkstatt Huber", purpose: "repair",
                                           scope: "dpps", dpp_ids: [ passport.dpp_id ], days: "90" }
      end

      grant = AccessGrant.sole
      claims = Did::Delegation.peek(sent[:grant])
      assert_equal SERVICE, sent[:base_url]
      assert_equal [ "legitimateInterest" ], claims["roles"]
      assert_equal [ passport.dpp_id ], claims["dpps"]
      assert_equal SERVICE_DID, claims["aud"]
      assert_equal 90 * 86_400, claims["exp"] - claims["iat"]

      assert_equal claims["jti"], grant.jti
      assert_equal "Werkstatt Huber", grant.subject_label
      assert_equal sent[:grant], grant.token, "kept, so it can be registered again"
      assert_equal "valid", grant.state
      assert Event.where(kind: "access_grant_issued").exists?
      assert_nil Event.verify_chain
      assert_match READER, flash[:notice]
    end
  end

  test "all my passports goes out as a scope" do
    with_open_vault do
      create_and_unlock
      configure
      sent = nil

      services(register: ->(grant, **) { sent = grant; registered }) do
        post access_grants_path, params: { subject_did: READER, scope: "issuer" }
      end

      claims = Did::Delegation.peek(sent)
      assert_equal "issuer", claims["scope"]
      assert_equal 365 * 86_400, claims["exp"] - claims["iat"], "a year unless asked otherwise"
      assert AccessGrant.sole.all_passports?
    end
  end

  # The service takes a grant only for passports it holds for this operator;
  # one that was never submitted there, or was ended, is not offered and not sent.
  test "only passports held at this service can be named" do
    with_open_vault do
      create_and_unlock
      configure
      held = submitted_passport
      elsewhere = submitted_passport(label: "B", service: "https://other.example")
      sent = nil

      get access_grants_path
      assert_select "input[name=?][value=?]", "dpp_ids[]", held.dpp_id
      assert_select "input[name=?][value=?]", "dpp_ids[]", elsewhere.dpp_id, 0

      services(register: ->(grant, **) { sent = grant; registered }) do
        post access_grants_path, params: { subject_did: READER, scope: "dpps", dpp_ids: [ held.dpp_id, elsewhere.dpp_id ] }
      end

      assert_equal [ held.dpp_id ], Did::Delegation.peek(sent)["dpps"]
    end
  end

  test "a refusal by the service is shown in its words and nothing is kept" do
    with_open_vault do
      create_and_unlock
      configure
      passport = submitted_passport

      [ 400, 403, 409 ].each do |status|
        refusal = DppService::Client::Result.new(ok: false, http_status: status, problems: [ "refused with #{status}" ])
        services(register: ->(*, **) { refusal }) do
          post access_grants_path, params: { subject_did: READER, scope: "dpps", dpp_ids: [ passport.dpp_id ] }
        end

        assert_match "refused with #{status}", flash[:alert]
      end
      assert_equal 0, AccessGrant.count
      assert_not Event.where(kind: "access_grant_issued").exists?
    end
  end

  test "what cannot be a grant is refused before anything is sent" do
    with_open_vault do
      create_and_unlock
      configure
      passport = submitted_passport
      called = false

      services(register: ->(*, **) { called = true; registered }) do
        post access_grants_path, params: { subject_did: "Werkstatt Huber", scope: "dpps", dpp_ids: [ passport.dpp_id ] }
        assert_equal I18n.t("access_grants.reasons.subject_not_a_did"), flash[:alert]

        post access_grants_path, params: { subject_did: READER, scope: "dpps", dpp_ids: [] }
        assert_equal I18n.t("access_grants.reasons.no_passports"), flash[:alert]

        post access_grants_path, params: { subject_did: READER, scope: "issuer", days: "400" }
        assert_equal I18n.t("access_grants.reasons.days_out_of_range"), flash[:alert]
      end

      assert_not called
    end
  end

  test "a service without a published DID cannot be granted to" do
    with_open_vault do
      create_and_unlock
      configure
      Setting.current.update!(service_did: nil)

      services { post access_grants_path, params: { subject_did: READER, scope: "issuer" } }

      assert_equal I18n.t("access_grants.reasons.no_service_did"), flash[:alert]
    end
  end

  # Mistyped, most likely; but it may be a registry that is down. Said, not refused.
  test "a reader DID that does not resolve is warned about and still granted" do
    with_open_vault do
      create_and_unlock
      configure

      services(resolve: ->(_did) { raise Did::Oyd::Error, "does not resolve" }) do
        post access_grants_path, params: { subject_did: READER, scope: "issuer" }
      end

      assert_equal 1, AccessGrant.count
      assert_match I18n.t("access_grants.reader_unresolved", reader: READER), flash[:notice]
    end
  end

  test "comparing takes over what the service holds and whom it trusts for authorities" do
    with_open_vault do
      create_and_unlock
      configure
      grant = grant_record
      listed = [ { "jti" => grant.jti, "sub" => READER, "roles" => [ "legitimateInterest" ], "scope" => "issuer",
                   "nbf" => 1.day.ago.to_i, "exp" => 1.year.from_now.to_i, "revoked" => true,
                   "revokedAt" => Time.current.to_i, "revokedBy" => "operator" } ]

      services(list: ->(**) { DppService::Client::Result.new(ok: true, http_status: 200, problems: [], list: listed) },
               issuers: ->(_base) { [ "did:oyd:zQmTestAuthority" ] }) do
        post sync_access_grants_path
      end

      assert_equal "revoked_by_operator", grant.reload.state
      assert_equal [ "did:oyd:zQmTestAuthority" ], Setting.current.authority_issuers
      assert_match I18n.t("access_grants.synced", updated: 1, added: 0, unknown: 0), flash[:notice]

      offline { get access_grants_path }
      assert_match I18n.t("access_grants.state.revoked_by_operator"), response.body
      assert_select "code", "did:oyd:zQmTestAuthority"
      assert_select "form[action=?]", revoke_access_grant_path(grant), 0
    end
  end

  test "authorities are not offered as a class to grant" do
    with_open_vault do
      create_and_unlock
      configure

      get access_grants_path

      assert_select "form[action=?] select", access_grants_path, 0
      assert_select "form[action=?] [name*=role]", access_grants_path, 0
      assert_select "form[action=?] input[value=authority]", access_grants_path, 0
    end
  end

  test "revoking ends the grant at the service and says so here" do
    with_open_vault do
      create_and_unlock
      configure
      grant = grant_record
      revoked_jti = nil
      answer = DppService::Client::Result.new(ok: true, http_status: 200, problems: [], document: {
        "jti" => grant.jti, "revoked" => true, "revokedAt" => 1_800_000_000, "revokedBy" => grant.issuer_did
      })

      services(revoke: ->(jti, **) { revoked_jti = jti; answer }) { post revoke_access_grant_path(grant) }

      assert_equal grant.jti, revoked_jti
      grant.reload
      assert_equal "revoked_by_me", grant.state
      assert_equal Time.at(1_800_000_000).utc, grant.revoked_at
      assert Event.where(kind: "access_grant_revoked").exists?
      assert AccessGrant.exists?(grant.id), "the record of what was granted stays"
    end
  end

  test "a grant the service does not know is said so, and marked" do
    with_open_vault do
      create_and_unlock
      configure
      grant = grant_record
      unknown = DppService::Client::Result.new(ok: false, http_status: 404, problems: [ "no access grant of yours" ])

      services(revoke: ->(*, **) { unknown }) { post revoke_access_grant_path(grant) }

      assert_not grant.reload.revoked?
      assert_not grant.known_to_service?
      assert_equal I18n.t("access_grants.unknown_to_service"), flash[:alert]
    end
  end

  test "a grant registered with another service is not revoked against this one" do
    with_open_vault do
      create_and_unlock
      configure
      grant = grant_record(service_base_url: "https://other.example")
      called = false

      services(revoke: ->(*, **) { called = true; registered }) { post revoke_access_grant_path(grant) }

      assert_not called
      assert_match "https://other.example", flash[:alert]
    end
  end

  private

  def configure
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE, service_did: SERVICE_DID)
    require "oydid"
    require "ed25519"
    key = Ed25519::SigningKey.generate
    encoded = Oydid.multi_encode([ 0, 19, 32 ].pack("C*") + key.to_bytes, { encode: "base58btc" }).first
    Identity.first || Identity.create!(did: "did:oyd:zQmTestbase58operator2345678923456789234567", origin: "minted",
                                       document_key: encoded, revocation_key: "r", keys_secured_at: Time.current)
  end

  def submitted_passport(label: "A", service: SERVICE)
    type = ProductType.first || ProductType.create!(label: "Lamp", structure_name: "DppLedLamp",
                                                    repo_base_url: "https://soya.example")
    Passport.create!(product_type: type, label: label, unique_product_identifier: "https://id.example.com/01/09520123456788/21/#{label}",
                     granularity: "item", status: "submitted", dpp_id: "did:oyd:zQmPassport#{label}",
                     submitted_at: Time.current, submitted_to: service)
  end

  def grant_record(**attributes)
    AccessGrant.create!({ jti: "grant-#{SecureRandom.uuid}", issuer_did: Identity.current.did, subject_did: READER,
                          roles: [ "legitimateInterest" ], scope: "issuer", not_before: 1.day.ago,
                          expires_at: 1.year.from_now, token: "g", service_base_url: SERVICE,
                          registered_at: Time.current }.merge(attributes))
  end

  def registered
    DppService::Client::Result.new(ok: true, http_status: 201, problems: [], document: {})
  end

  # Every seam to the outside, replaced together.
  def services(register: ->(*, **) { registered }, list: ->(**) { registered }, revoke: ->(*, **) { registered },
               issuers: ->(_base) { [] }, resolve: ->(_did) { "k" * 32 }, &block)
    stubbing(Did::Token, :issue, ->(*, **) { "token" }) do
      stubbing(Did::Oyd, :public_key, resolve) do
        stubbing(DppService::Directory, :authority_issuers, issuers) do
          stubbing(DppService::Client, :register_access_grant, register) do
            stubbing(DppService::Client, :list_access_grants, list) do
              stubbing(DppService::Client, :revoke_access_grant, revoke, &block)
            end
          end
        end
      end
    end
  end

  # Anything that would leave the machine fails the test.
  def offline(&block)
    boom = ->(*, **) { flunk("the page went to the network") }
    stubbing(DppService::Client, :list_access_grants, boom) do
      stubbing(DppService::Directory, :authority_issuers, boom) do
        stubbing(Did::Oyd, :public_key, boom, &block)
      end
    end
  end
end
