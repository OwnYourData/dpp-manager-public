class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string  :locale,                null: false, default: "en"
      t.boolean :help_mode,             null: false, default: true
      t.integer :idle_timeout_minutes,  null: false, default: 15
      t.integer :kdf_profile,           null: false, default: 1
      t.string  :app_version
      t.timestamps
    end
  end
end
