# frozen_string_literal: true

# The signature of the economic operator on a passport the DPP Service holds in
# its own database, as far as this application knows it: the state the service
# last reported (X-DPP-Signature-State: none, pending, signed, stale), the
# warning it gave on acceptance (a signer that is not the passport's
# economicOperatorId), why the last attempt failed, and when the state was
# recorded.
class AddSignatureToPassports < ActiveRecord::Migration[8.1]
  def change
    add_column :passports, :signature_state, :string
    add_column :passports, :signature_warning, :text
    add_column :passports, :signature_problem, :text
    add_column :passports, :signature_recorded_at, :datetime
  end
end
