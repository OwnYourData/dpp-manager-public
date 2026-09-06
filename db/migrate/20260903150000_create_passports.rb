class CreatePassports < ActiveRecord::Migration[8.1]
  def change
    create_table :passports do |t|
      t.references :product_type, null: false, foreign_key: true

      # What the operator calls this one in the list. Not an identifier: the
      # product's identifiers arrive when the passport is first submitted, and
      # until then a passport has to be findable by something a person chose.
      t.string :label, null: false

      # The form's answers, flat, exactly as they were typed. This is the truth
      # the application keeps; the EN 18223 element tree is derived from it by
      # the transformation and is never the thing that is edited.
      t.text :data

      # draft — only here. Later milestones add the states that involve the
      # service, and a passport moves between them; it never moves back to draft.
      t.string :status, null: false, default: "draft"

      t.timestamps
    end
  end
end
