# frozen_string_literal: true

# The access grants this operator issued: who may read the controlled part of
# which of their passports, until when, and whether the grant still stands.
#
# The service holds the grants that count; this table is the operator's own
# record of what they signed, so they can see it, revoke it and notice when the
# service says something else. +token+ is the signed grant itself, kept so it
# can be registered again with a service that lost it. A grant the service
# knows but this table did not (after restoring an older backup) is taken over
# without one.
#
# +subject_label+ is a name for the reader that never leaves this machine.
# +revoked_by+ is the operator's DID when they revoked it here, "operator" when
# the operator of the service did.
class CreateAccessGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :access_grants do |t|
      t.string   :jti, null: false
      t.string   :issuer_did, null: false
      t.string   :subject_did, null: false
      t.string   :subject_label
      t.text     :roles
      t.string   :scope, null: false
      t.text     :dpp_ids
      t.string   :purpose
      t.datetime :not_before
      t.datetime :expires_at, null: false
      t.text     :token
      t.string   :service_base_url, null: false
      t.datetime :registered_at
      t.datetime :revoked_at
      t.string   :revoked_by
      t.datetime :synced_at
      t.boolean  :known_to_service, null: false, default: true
      t.timestamps
    end
    add_index :access_grants, %i[service_base_url jti], unique: true
  end
end
