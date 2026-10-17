require "test_helper"

# The operator's record of the access grants they issued, and how it is brought
# in line with what the service holds.
class AccessGrantTest < ActiveSupport::TestCase
  BASE = "https://dpp-service.example".freeze
  ISSUER = "did:oyd:zQmOperator".freeze

  setup do
    reset_vault!
    Vault::Lifecycle.create!(TEST_PASSPHRASE, seed: false)
  end

  teardown { Vault::Store.close! }

  test "the state says who ended a grant, or that it ran out" do
    assert_equal "valid", grant.state
    assert_equal "expired", grant(expires_at: 1.minute.ago).state
    assert_equal "revoked_by_me", grant(revoked_at: Time.current, revoked_by: ISSUER).state
    assert_equal "revoked_by_operator", grant(revoked_at: Time.current, revoked_by: "operator").state
  end

  test "comparing takes over revocations by the service operator" do
    mine = grant(jti: "grant-1")

    counts = AccessGrant.sync_from!([ summary("grant-1", revoked: true, revokedAt: 1_800_000_000, revokedBy: "operator") ],
                                    base_url: BASE, issuer_did: ISSUER)

    mine.reload
    assert_equal({ updated: 1, added: 0, unknown: 0 }, counts)
    assert_equal "revoked_by_operator", mine.state
    assert_equal Time.at(1_800_000_000).utc, mine.revoked_at
    assert mine.synced_at.present?
  end

  # After restoring an older backup: the service knows grants this machine
  # does not. They are taken over, without the signed statement.
  test "a grant only the service knows is added, one it does not know is marked" do
    grant(jti: "grant-gone")

    counts = AccessGrant.sync_from!([ summary("grant-new") ], base_url: BASE, issuer_did: ISSUER)

    assert_equal({ updated: 0, added: 1, unknown: 1 }, counts)
    added = AccessGrant.find_by!(jti: "grant-new")
    assert_nil added.token
    assert_equal "valid", added.state
    assert_not AccessGrant.find_by!(jti: "grant-gone").known_to_service?
  end

  test "grants at another service are left alone" do
    other = grant(jti: "grant-x", service_base_url: "https://other.example")

    AccessGrant.sync_from!([], base_url: BASE, issuer_did: ISSUER)

    assert other.reload.known_to_service?
  end

  test "a revoked or unknown grant cannot be revoked again" do
    assert grant.revocable?
    assert_not grant(revoked_at: Time.current, revoked_by: ISSUER).revocable?
    assert_not grant(known_to_service: false).revocable?
  end

  private

  def grant(**attributes)
    @n = (@n || 0) + 1
    AccessGrant.create!({ jti: "grant-#{@n}-#{SecureRandom.hex(2)}", issuer_did: ISSUER, subject_did: "did:oyd:zQmReader",
                          roles: [ "legitimateInterest" ], scope: "dpps", dpp_ids: [ "did:oyd:zQmP" ],
                          not_before: 1.day.ago, expires_at: 1.year.from_now, service_base_url: BASE,
                          registered_at: Time.current }.merge(attributes))
  end

  def summary(jti, **extra)
    { "jti" => jti, "sub" => "did:oyd:zQmReader", "roles" => [ "legitimateInterest" ], "scope" => "dpps",
      "dpps" => [ "did:oyd:zQmP" ], "nbf" => 1.day.ago.to_i, "exp" => 1.year.from_now.to_i,
      "revoked" => false }.merge(extra.transform_keys(&:to_s))
  end
end
