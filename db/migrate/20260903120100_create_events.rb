class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.datetime :occurred_at, null: false
      t.string   :kind,        null: false
      t.text     :detail,      null: false, default: "{}"
      t.string   :prev_digest, null: false
      t.string   :digest,      null: false
    end

    add_index :events, :occurred_at
    add_index :events, :kind
    add_index :events, :digest, unique: true
  end
end
