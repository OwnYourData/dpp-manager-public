class AddRetirementToPassports < ActiveRecord::Migration[8.1]
  def change
    # Ending a passport is two acts against two different systems, and either
    # can fail while the other has already happened. Two columns rather than one
    # state, so the application can say which half is done and offer to finish
    # the other — a single "retired" flag would have to lie about one of them.
    #
    # retired_at: the service no longer serves it (it keeps the history).
    # revoked_at: the passport's own DID no longer resolves, anywhere, ever.
    add_column :passports, :retired_at, :datetime
    add_column :passports, :revoked_at, :datetime
  end
end
