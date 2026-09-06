class AddDppIdToPassports < ActiveRecord::Migration[8.1]
  def change
    # The passport's own DID. Minted here, on this machine, which is the point:
    # the DPP Service would mint one too, and then the service would be the one
    # holding the keys to the identifier the product carries.
    add_column :passports, :dpp_id, :string
    add_column :passports, :minted_at, :datetime

    # The base URL that went into the DID's serviceEndpoint. Frozen at minting
    # time and kept here because the DID cannot be asked offline — and because
    # the service compares the host of that endpoint with where the passport is
    # being submitted, so a mismatch has to be visible before the submission,
    # not after it.
    add_column :passports, :endpoint_base, :string

    add_index :passports, :dpp_id, unique: true

    # The two secrets of a passport DID, in their own table for the same reason
    # the identity's are: an export of the operator's work can leave the table
    # out without picking fields apart. The whole file is encrypted either way.
    create_table :passport_keys do |t|
      t.references :passport, null: false, foreign_key: true, index: { unique: true }

      t.text :document_key,   null: false
      t.text :revocation_key
      t.text :revocation_log

      # Set when the operator has confirmed the keys are somewhere else. Until
      # then they are still on screen, and that is the only time they will be.
      t.datetime :keys_secured_at

      t.timestamps
    end
  end
end
