# frozen_string_literal: true

# What this machine attested about the payload the custodian delivers
# (prEN 18246; dpp-service/docs/Integrity.md).
#
# Two fields rather than a copy of the service's own state. What matters here is
# what *this* operator signed: the service reports the hash of the payload it
# delivered, and only the document key in this vault can put that hash into the
# passport's DID document. A hash that has changed since means the attestation is
# behind again, which is why the timestamp is cleared with it rather than kept
# beside it.
class AddPayloadCommitmentToPassports < ActiveRecord::Migration[8.1]
  def change
    add_column :passports, :payload_hash, :string
    add_column :passports, :payload_committed_at, :datetime
  end
end
