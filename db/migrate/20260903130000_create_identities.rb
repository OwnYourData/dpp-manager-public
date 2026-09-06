class CreateIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :identities do |t|
      t.string   :did,             null: false
      t.string   :label
      # "minted" — this application created it and saw the keys once.
      # "imported" — they were typed in from somewhere else.
      t.string   :origin,          null: false, default: "minted"

      # The whole file is encrypted, so these sit in the same envelope as
      # everything else. They live in their own table so that an export of the
      # operator's work can leave them out without picking fields apart.
      t.text     :document_key,    null: false
      t.text     :revocation_key
      t.text     :revocation_log

      # Set when the operator has confirmed they have the keys somewhere else.
      # Until then the setup wizard refuses to move on.
      t.datetime :keys_secured_at

      t.timestamps
    end

    add_index :identities, :did, unique: true
  end
end
